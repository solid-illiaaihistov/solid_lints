import 'dart:io';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:path/path.dart' as p;

void main() {
  final testDir = Directory('test');
  if (!testDir.existsSync()) {
    print('Test directory not found');
    return;
  }

  // Create the new generated_test package
  final playgroundDir = Directory('generated_test');
  if (!playgroundDir.existsSync()) {
    playgroundDir.createSync(recursive: true);
  }

  // Create mock_flutter package
  final mockFlutterDir = Directory(p.join(playgroundDir.path, 'mock_flutter'));
  mockFlutterDir.createSync(recursive: true);

  File(p.join(mockFlutterDir.path, 'pubspec.yaml')).writeAsStringSync('''
name: flutter
version: 1.0.0
environment:
  sdk: ">=3.9.0 <4.0.0"
''');

  final mockFlutterLibDir = Directory(p.join(mockFlutterDir.path, 'lib'));
  mockFlutterLibDir.createSync(recursive: true);

  File(p.join(mockFlutterLibDir.path, 'foundation.dart')).writeAsStringSync('''
const bool kReleaseMode = false;
const bool kDebugMode = true;
void debugPrint(String? message, {int? wrapWidth}) {}
''');

  File(p.join(mockFlutterLibDir.path, 'material.dart')).writeAsStringSync('''
export 'package:flutter/foundation.dart';
export 'package:flutter/src/widgets/framework.dart';
''');

  File(p.join(mockFlutterLibDir.path, 'cupertino.dart')).writeAsStringSync('''
export 'package:flutter/foundation.dart';
''');

  final mockFlutterSrcDir = Directory(p.join(mockFlutterLibDir.path, 'src', 'widgets'));
  mockFlutterSrcDir.createSync(recursive: true);

  File(p.join(mockFlutterSrcDir.path, 'framework.dart')).writeAsStringSync('''
abstract class Widget {}

abstract class StatefulWidget extends Widget {}

class BuildContext {}

abstract class State<T extends StatefulWidget> {
  void initState() {}
  void didUpdateWidget(T oldWidget) {}
  void dispose() {}
  void setState(void Function() fn) {
    fn();
  }
}

class Text extends Widget {
  final Object? data;
  Text(this.data);
}

class ElevatedButton extends Widget {
  final Function()? onPressed;
  final Function()? onLongPress;
  final Widget? child;

  ElevatedButton({this.onPressed, this.onLongPress, this.child});
}
''');

  // Generate pubspec.yaml for the playground package
  final pubspecFile = File(p.join(playgroundDir.path, 'pubspec.yaml'));
  pubspecFile.writeAsStringSync('''
name: generated_test
description: A playground package for visual verification of solid_lints rules
publish_to: none

environment:
  sdk: ">=3.9.0 <4.0.0"

dependencies:
  flutter:
    path: ./mock_flutter

dev_dependencies:
  solid_lints:
    path: ../
''');

  // Find all test files ending with _test.dart recursively under test/
  final testFiles = testDir
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => file.path.endsWith('_test.dart'))
      .toList();

  final allRules = <String>{};
  for (final file in testFiles) {
    final pathParts = p.split(file.path);
    if (!pathParts.contains('lints')) continue;
    final ruleName = pathParts[pathParts.length - 2];
    final ruleCode = ruleName == 'avoid_unnecessary_set_state'
        ? 'avoid_unnecessary_setstate'
        : ruleName;
    allRules.add(ruleCode);
  }
  final sortedRules = allRules.toList()..sort();

  // Generate analysis_options.yaml for the playground package
  final optionsFile = File(p.join(playgroundDir.path, 'analysis_options.yaml'));
  final diagnosticsBuffer = StringBuffer(
    'plugins:\n  solid_lints:\n    path: ../\n    diagnostics:\n',
  );
  for (final rule in sortedRules) {
    diagnosticsBuffer.writeln('      $rule: true');
  }
  optionsFile.writeAsStringSync(diagnosticsBuffer.toString());

  final outputDir = Directory(p.join(playgroundDir.path, 'lib'));
  if (outputDir.existsSync()) {
    outputDir.deleteSync(recursive: true);
  }
  outputDir.createSync(recursive: true);

  final generatedFiles = <String>[];
  for (final file in testFiles) {
    final pathParts = p.split(file.path);
    // Only process rule tests under test/lints/ or test/src/lints/
    if (!pathParts.contains('lints')) continue;

    // The rule name is the folder name containing the test file
    final ruleName = pathParts[pathParts.length - 2];
    final ruleOutputDir = Directory(p.join(outputDir.path, ruleName));
    ruleOutputDir.createSync(recursive: true);

    try {
      final result = parseString(content: file.readAsStringSync());
      final unit = result.unit;
      unit.accept(
        TestVisitor(ruleName, ruleOutputDir, generatedFiles, sortedRules),
      );
    } catch (e) {
      print('Error parsing ${file.path}: $e');
    }
  }

  // Add the folder to .gitignore if not already added
  final gitignoreFile = File('.gitignore');
  if (gitignoreFile.existsSync()) {
    final lines = gitignoreFile.readAsLinesSync();
    if (!lines.any((line) => line.trim() == '/generated_test/')) {
      gitignoreFile.writeAsStringSync(
        '\n# Local visual test playground\n/generated_test/\n',
        mode: FileMode.append,
      );
      print('Added /generated_test/ to .gitignore');
    }
  }

  // Clean up old generated_tests from lint_test
  final oldOutputDir = Directory('lint_test/generated_tests');
  if (oldOutputDir.existsSync()) {
    oldOutputDir.deleteSync(recursive: true);
    print('Cleaned up old lint_test/generated_tests directory');
  }

  print('Done! Generated ${generatedFiles.length} files in generated_test/lib');
}

class TestVisitor extends RecursiveAstVisitor<void> {
  final String ruleName;
  final Directory outputDir;
  final List<String> generatedFiles;
  final List<String> allRules;
  TestVisitor(
    this.ruleName,
    this.outputDir,
    this.generatedFiles,
    this.allRules,
  );

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    if (node.name.lexeme.startsWith('test_')) {
      final methodName = node.name.lexeme;
      node.body.accept(
        DiagnosticsVisitor(
          ruleName,
          outputDir,
          methodName,
          generatedFiles,
          allRules,
        ),
      );
    }
    super.visitMethodDeclaration(node);
  }
}

class DiagnosticsVisitor extends RecursiveAstVisitor<void> {
  final String ruleName;
  final Directory outputDir;
  final String methodName;
  final List<String> generatedFiles;
  final List<String> allRules;
  DiagnosticsVisitor(
    this.ruleName,
    this.outputDir,
    this.methodName,
    this.generatedFiles,
    this.allRules,
  );

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.methodName.name == 'assertDiagnostics' ||
        node.methodName.name == 'assertNoDiagnostics') {
      final arguments = node.argumentList.arguments;
      if (arguments.isNotEmpty) {
        final firstArg = arguments.first;
        if (firstArg is StringLiteral) {
          final content = firstArg.stringValue;
          if (content != null) {
            var cleanContent = content;
            if (cleanContent.contains(
              "import 'package:flutter/src/widgets/framework.dart';",
            )) {
              cleanContent = cleanContent.replaceAll(
                "import 'package:flutter/src/widgets/framework.dart';",
                "import 'package:flutter/material.dart';",
              );
            }

            final expectLint = node.methodName.name == 'assertDiagnostics';
            final targetRule = ruleName == 'avoid_unnecessary_set_state'
                ? 'avoid_unnecessary_setstate'
                : ruleName;
            final otherRules = allRules
                .where((r) => r != targetRule)
                .map((r) => 'solid_lints/$r')
                .join(', ');

            cleanContent =
                '// expect_lint: $expectLint\n// ignore_for_file: unused_element, unused_local_variable, unused_field, override_on_non_overriding_member, missing_required_argument, missing_required_param, concrete_class_has_abstract_member, non_abstract_class_inherits_abstract_member, invalid_override, must_be_immutable, must_call_super, $otherRules\n' +
                cleanContent;
            final testFile = File(p.join(outputDir.path, '$methodName.dart'));
            testFile.writeAsStringSync(cleanContent);
            generatedFiles.add(testFile.path);
          }
        }
      }
    }
    super.visitMethodInvocation(node);
  }
}
