import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:solid_lints/src/utils/types_utils.dart';

/// Finds the closest BuildContext parameter in the AST parent chain of [node].
FormalParameter? findClosestBuildContext(AstNode node) {
  AstNode? current = node.parent;

  while (current != null) {
    if (current is FunctionExpression) {
      final params = current.parameters?.parameters ?? <FormalParameter>[];
      for (final param in params) {
        final type = switch (param.declaredFragment?.element) {
          VariableElement(:final type) => type,
          _ => null,
        };
        if (isBuildContext(type)) {
          return param;
        }
      }
    }
    current = current.parent;
  }
  return null;
}
