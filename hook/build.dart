import 'dart:io';

import 'package:hooks/hooks.dart';
import 'package:yaml/yaml.dart';

/// Native Assets build hook that runs automatically during `flutter run`,
/// `flutter test`, or `dart run`.
///
/// Automatically fixes the macOS AOT code signing issue:
/// https://github.com/dart-lang/sdk/issues/63813
///
/// Re-signs cached `plugin.aot` snapshots belonging to `solid_lints`
/// with an ad-hoc signature ONLY if they are still linker-signed.
void main(List<String> arguments) async {
  // Uses the official hooks protocol — correctly handles input/output.json
  // serialization and remains compatible across Dart SDK versions.
  await build(arguments, (input, output) async {
    if (!Platform.isMacOS) return;

    // Path used by Analysis Server to cache compiled plugin AOT binaries.
    final home = Platform.environment['HOME'];
    if (home == null) return;

    final pluginDir = Directory('$home/.dartServer/.plugin_manager');
    if (!await pluginDir.exists()) return;

    final processingTasks = <Future<void>>[];

    await for (final entity in pluginDir.list(recursive: true)) {
      if (entity case File(:final path) when path.endsWith('plugin.aot')) {
        processingTasks.add(_AotSigner._processAotFile(entity, pluginDir));
      }
    }

    // eagerError: false ensures all files are processed even if one fails.
    await Future.wait(processingTasks, eagerError: false);
  });
}

abstract final class _AotSigner {
  static const _packageName = 'solid_lints';

  /// Checks if [aotFile] belongs to [_packageName] and re-signs it
  /// if necessary. This is the entry point for parallel processing.
  static Future<void> _processAotFile(File aotFile, Directory pluginDir) async {
    if (await isSolidLintsPackage(aotFile, pluginDir)) {
      await resignIfLinkerSigned(aotFile.path);
    }
  }

  /// Walks parent directories up to [rootPluginDir] to detect if the
  /// [aotFile] belongs to the [_packageName] package.
  static Future<bool> isSolidLintsPackage(
    File aotFile,
    Directory rootPluginDir,
  ) async {
    Directory? current = aotFile.parent;

    while (current != null && current.path != rootPluginDir.path) {
      final segments = current.uri.pathSegments;
      if (segments.any(
        (s) => s == _packageName || s.startsWith('$_packageName-'),
      )) {
        return true;
      }

      final pubspecFile = File('${current.path}/pubspec.yaml');
      if (await pubspecFile.exists()) {
        try {
          final content = await pubspecFile.readAsString();
          try {
            final yamlDoc = loadYaml(content);
            if (yamlDoc is Map && yamlDoc['name'] == _packageName) return true;
          } catch (_) {
            if (RegExp(
              r'^name:\s+solid_lints\s*$',
              multiLine: true,
            ).hasMatch(content)) {
              return true;
            }
          }
        } catch (_) {}
      }

      final packageConfigFile = File(
        '${current.path}/.dart_tool/package_config.json',
      );
      if (await packageConfigFile.exists()) {
        try {
          final content = await packageConfigFile.readAsString();
          if (content.contains('"solid_lints"') ||
              content.contains('solid_lints')) {
            return true;
          }
        } catch (_) {}
      }

      final lockFile = File('${current.path}/pubspec.lock');
      if (await lockFile.exists()) {
        try {
          final content = await lockFile.readAsString();
          if (content.contains('solid_lints')) return true;
        } catch (_) {}
      }

      final parentDir = current.parent;
      if (parentDir.path == current.path) break;
      current = parentDir;
    }

    return false;
  }

  /// Re-signs [filePath] with an ad-hoc signature if it is linker-signed.
  static Future<void> resignIfLinkerSigned(String filePath) async {
    final verifyResult = await Process.run('codesign', ['-dvv', filePath]);
    final output = '${verifyResult.stdout}\n${verifyResult.stderr}';

    if (!output.contains('linker-signed')) return;

    final signResult = await Process.run('codesign', [
      '--force',
      '--deep',
      '--sign',
      '-',
      filePath,
    ]);

    if (signResult.exitCode == 0) {
      stderr.writeln(
        '[solid_lints] Re-signed $filePath for macOS AOT compatibility.',
      );
    } else {
      stderr.writeln(
        '[solid_lints] Failed to re-sign $filePath: ${signResult.stderr}',
      );
    }
  }
}
