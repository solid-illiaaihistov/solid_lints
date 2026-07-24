import 'dart:io';

import 'package:yaml/yaml.dart';

/// Native Assets build hook that runs automatically during `flutter run`,
/// `flutter test`, or `dart run`.
///
/// Automatically fixes the macOS AOT code signing issue:
/// https://github.com/dart-lang/sdk/issues/63813
///
/// Re-signs cached `plugin.aot` snapshots belonging to `solid_lints`
/// with an ad-hoc signature ONLY if they are still linker-signed.
void main(List<String> args) async {
  if (!Platform.isMacOS) return;

  try {
    final home = Platform.environment['HOME'];
    if (home == null) return;

    // Path used by Analysis Server to cache compiled plugin AOT binaries.
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
  } catch (_) {
    // Fail silently to never interrupt the developer's workflow.
  }
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
  ///
  /// Uses two heuristics:
  ///   1. Path segment matching — avoids false positives from packages
  ///      with similar names (e.g. `solid_lints_extension`).
  ///   2. `pubspec.yaml` content matching (YAML parsing) — authoritative.
  static Future<bool> isSolidLintsPackage(
    File aotFile,
    Directory rootPluginDir,
  ) async {
    Directory? current = aotFile.parent;

    while (current != null && current.path != rootPluginDir.path) {
      // Heuristic 1: match exact path segment or versioned dir
      // (e.g. `solid_lints-1.0.0`), not just any substring.
      final segments = current.uri.pathSegments;
      if (segments.any(
        (s) => s == _packageName || s.startsWith('$_packageName-'),
      )) {
        return true;
      }

      // Heuristic 2: authoritative check via parsing pubspec.yaml.
      final pubspecFile = File('${current.path}/pubspec.yaml');
      if (await pubspecFile.exists()) {
        try {
          final content = await pubspecFile.readAsString();
          try {
            final yamlDoc = loadYaml(content);
            if (yamlDoc is Map && yamlDoc['name'] == _packageName) return true;
          } catch (_) {
            // Fallback if YAML parsing fails (e.g. syntax error in pubspec).
            if (RegExp(
              r'^name:\s+solid_lints\s*$',
              multiLine: true,
            ).hasMatch(content))
              return true;
          }
        } catch (_) {
          // Ignore read errors
        }
      }

      // Prevent infinite loop at filesystem root
      final parentDir = current.parent;
      if (parentDir.path == current.path) break;
      current = parentDir;
    }

    return false;
  }

  /// Re-signs [filePath] with an ad-hoc signature if it is linker-signed.
  static Future<void> resignIfLinkerSigned(String filePath) async {
    final verifyResult = await Process.run('codesign', ['-dvv', filePath]);

    // Signature info is written to stderr by codesign -dvv.
    final output = '${verifyResult.stdout}\n${verifyResult.stderr}';

    if (!output.contains('linker-signed')) return;

    final signResult = await Process.run('codesign', [
      '--force',
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
