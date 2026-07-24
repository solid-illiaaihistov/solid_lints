import 'dart:io';

void main() async {
  if (!Platform.isMacOS) {
    print('✅ Setup skipped: Not on macOS.');
    return;
  }

  final home = Platform.environment['HOME'];
  if (home == null) return;

  final pluginDir = Directory('$home/.dartServer/.plugin_manager');
  if (!await pluginDir.exists()) {
    print(
      '⚠️ Plugin manager cache directory not found. '
      'Please open VS Code / IDE first.',
    );
    return;
  }

  final aotFiles = await pluginDir
      .list(recursive: true)
      .where((entity) => entity is File && entity.path.endsWith('plugin.aot'))
      .toList();

  if (aotFiles.isEmpty) {
    print(
      '⚠️ No plugin.aot files found. Make sure IDE has analyzed the project.',
    );
    return;
  }

  print('🔒 Signing ${aotFiles.length} AOT plugin snapshot(s) for macOS...');

  for (final file in aotFiles) {
    final result = await Process.run('codesign', [
      '--force',
      '--deep',
      '--sign',
      '-',
      file.path,
    ]);

    if (result.exitCode == 0) {
      print('✅ Signed: ${file.path}');
    } else {
      print('❌ Failed to sign ${file.path}: ${result.stderr}');
    }
  }

  print(
    '\n🎉 Done! Please restart Analysis Server in VS Code '
    '(Cmd+Shift+P -> Dart: Restart Analysis Server).',
  );
}
