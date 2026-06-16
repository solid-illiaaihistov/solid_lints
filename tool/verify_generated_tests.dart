import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

void main() async {
  final rootDir = Directory.current.path;
  final generatedTestDir = p.join(rootDir, 'generated_test');
  final libDir = Directory(p.join(generatedTestDir, 'lib'));

  if (!libDir.existsSync()) {
    print(
      'Error: generated_test/lib directory not found. Please run tool/generate_test_files.dart first.',
    );
    exit(1);
  }

  print('Running dart analyze --format=json in generated_test...');
  final result = await Process.run('dart', [
    'analyze',
    '--format=json',
  ], workingDirectory: generatedTestDir);

  if (result.exitCode != 0 && result.exitCode != 3) {
    // Note: dart analyze might return exit code 3 if there are warnings/errors found
    if (result.stdout.toString().isEmpty) {
      print('Error running dart analyze:');
      print(result.stderr);
      exit(1);
    }
  }

  final String output = result.stdout as String;
  final Map<String, dynamic> jsonOutput =
      jsonDecode(output) as Map<String, dynamic>;
  final List<dynamic> diagnostics = jsonOutput['diagnostics'] as List<dynamic>;

  // Group diagnostics by file path
  final Map<String, List<Map<String, dynamic>>> diagnosticsByFile = {};
  for (final diag in diagnostics) {
    final map = diag as Map<String, dynamic>;
    final location = map['location'] as Map<String, dynamic>;
    final file = location['file'] as String;
    diagnosticsByFile.putIfAbsent(file, () => []).add(map);
  }

  // Find all generated test files
  final List<File> testFiles = libDir
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => file.path.endsWith('.dart'))
      .toList();

  int totalTests = 0;
  int passedTests = 0;
  final Map<String, int> failedRules = {};

  print('\nVerifying test expectations:');

  // Group files by rule for pretty printing
  final Map<String, List<File>> filesByRule = {};
  for (final file in testFiles) {
    final relativePath = p.relative(file.path, from: libDir.path);
    final pathParts = p.split(relativePath);
    if (pathParts.length < 2) continue;
    final ruleName = pathParts[0];
    filesByRule.putIfAbsent(ruleName, () => []).add(file);
  }

  for (final ruleName in filesByRule.keys.toList()..sort()) {
    if (ruleName == 'avoid_debug_print_in_release') {
      continue;
    }
    final files = filesByRule[ruleName]!;

    for (final file in files) {
      final absolutePath = file.absolute.path;
      final fileDiagnostics = diagnosticsByFile[absolutePath] ?? [];

      // Filter diagnostics to only match this specific rule
      var targetRuleCode = ruleName;
      if (targetRuleCode == 'avoid_unnecessary_set_state') {
        targetRuleCode = 'avoid_unnecessary_setstate';
      }
      final ruleDiagnostics = fileDiagnostics
          .where((d) => d['code'] == targetRuleCode)
          .toList();

      final lines = file.readAsLinesSync();
      final firstLine = lines.isNotEmpty ? lines.first.trim() : '';
      bool? expectError;
      if (firstLine.startsWith('// expect_lint: true')) {
        expectError = true;
      } else if (firstLine.startsWith('// expect_lint: false')) {
        expectError = false;
      }

      if (expectError == null) {
        failedRules[ruleName] = (failedRules[ruleName] ?? 0) + 1;
        totalTests++;
        continue;
      }

      final bool hasError = ruleDiagnostics.isNotEmpty;

      totalTests++;
      if (expectError == hasError) {
        passedTests++;
      } else {
        failedRules[ruleName] = (failedRules[ruleName] ?? 0) + 1;
      }
    }
  }

  if (failedRules.isNotEmpty) {
    print('\nFailures details:');
    for (final entry in failedRules.entries) {
      print('  ${entry.key} (${entry.value})');
    }
  }

  print('\n----------------------------------------');
  final failedTests = totalTests - passedTests;
  print('Result: $passedTests/$totalTests passed. ($failedTests failed)');

  if (failedRules.isNotEmpty) {
    exit(1);
  } else {
    print('\nAll generated tests passed successfully! 🎉');
    exit(0);
  }
}
