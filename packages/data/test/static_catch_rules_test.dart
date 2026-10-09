// ============================================================================
//  static_catch_rules_test.dart
//  حارس M10: لا silent catch ولا bare-underscore في data/core،
//  ولا bare-underscore في واجهات الموبايل وسطح المكتب.
// ============================================================================
//
//  WHY
//  -------
//  M10 أزال كل `catch (_)` الصامت وفرض قاعدة: أي `catch` في الـ lib يجب أن
//  يكون مسموعاً — `throw`/`rethrow`، أو نوعاً مقيّداً (`on X catch`)، أو
//  يطبع السبب عبر `debugPrint(`/`print(`. لا يمكن للـ analyzer الإلزام بها:
//  `avoid_catches_without_on_clauses` معروف لكنه خامل في هذا الإصدار، واسمه
//  المركّب (`avoid_catch_without_on_clauses`) غير معروف فيتسبب بتحذير
//  `unrecognized_error_code`. لذلك الإلزام الحقيقي هنا — اختبار ثابت يقرأ
//  الملفات بنفس أدوات الفحص اليدوي المستخدم أثناء الهدم:
//
//    1. صفر `catch (_` (bare-underscore) في الـ catch غير المقيّدة في:
//       packages/data/lib، packages/core/lib، apps/*/lib.
//    2. صفر `catch` غير مقيّد جسمه صامت (بدون throw/rethrow/debugPrint/print)
//       في packages/data/lib و packages/core/lib.
//
//  القاعدة الكاملة وحدودها في docs/ERROR_HANDLING.md.
//
//  HOW — يعمل بـ`flutter test` من جذر الحزمة (يرصد جذر المستودع بنفسه).
// ============================================================================
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final _bareUnderscoreRe = RegExp(r'catch\s*\(\s*_\s*\)');
final _untypedCatchRe = RegExp(r'\bcatch\s*\(');
final _typedRe = RegExp(r'\bon\s+[A-Za-z_][\w.<>]*\s+catch');
final _markerRe = RegExp(r'throw\b|rethrow\b|debugPrint\s*\(|print\s*\(');
final _openRe = RegExp(r'\{');
final _closeRe = RegExp(r'\}');

Directory? _root;
final _sep = Platform.pathSeparator;

Directory _repoRoot() {
  if (_root != null) return _root!;
  var d = Directory.current;
  while (true) {
    if (File('${d.path}$_sep${['packages', 'data', 'pubspec.yaml'].join(_sep)}')
        .existsSync()) {
      return _root = d;
    }
    final parent = d.parent;
    if (identical(parent.path, d.path)) {
      throw StateError('repository root not found from ${Directory.current}');
    }
    d = parent;
  }
}

String _p(List<String> parts) =>
    '${_repoRoot().path}$_sep${parts.join(_sep)}';

bool _isCommentLine(String line) {
  final t = line.trimLeft();
  return t.startsWith('//') || t.startsWith('*') || t.startsWith('/*');
}

List<String> _dartFilesUnder(List<String> relDir) {
  final dir = Directory(_p(relDir));
  if (!dir.existsSync()) return const [];
  return dir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .map((f) => f.path)
      .toList()
    ..sort();
}

/// يعيد نص جسم `catch` (من القوس المفتوح حتى قوس الإغلاق شاملاً) أو null
/// إذا لم يكن القوس المفتوح في السطر نفسه (أسلوب غير مستخدم في الكود).
///
/// فواصل الأقواس تُعدّ تراكمياً: سطر `} catch (e) {` يفتح الجسم (تتجاوزنا
/// الصفر)، سطور الجسم المتوازنة تبقي الصفر، وخط الإغلاق يهبط دون الصفر
/// فيتوقف المسح. الجمع الصافي المُجمَّع لا يُصدر حكماً خاطئاً على الحالات
/// أحادية السطر مثل `{ return; }`.
String? _catchBody(List<String> lines, int i, String path) {
  final line = lines[i];
  final brace = line.indexOf('{');
  if (brace < 0) return null;
  var depth = 0;
  final chunks = <String>[];
  for (var k = i; k < lines.length; k++) {
    final text = k == i ? line.substring(brace + 1) : lines[k];
    depth += _openRe.allMatches(text).length - _closeRe.allMatches(text).length;
    chunks.add(text);
    if (depth < 0) break;
  }
  if (depth >= 0) {
    fail('$path:${i + 1}: قوس جسم catch غير مغلق');
  }
  return chunks.join('\n');
}

void main() {
  test('M10: تخطيط الجذر متوقع', () {
    expect(File(_p(['packages', 'data', 'pubspec.yaml'])).existsSync(), true);
    expect(File(_p(['apps', 'mobile', 'pubspec.yaml'])).existsSync(), true);
    expect(File(_p(['apps', 'desktop', 'pubspec.yaml'])).existsSync(), true);
  });

  final libDirs = [
    ['packages', 'data', 'lib'],
    ['packages', 'core', 'lib'],
  ];
  final uiDirs = [
    ['apps', 'mobile', 'lib'],
    ['apps', 'desktop', 'lib'],
  ];

  for (final dir in libDirs) {
    test('M10: لا bare-underscore ولا catch صامت في ${dir.join('/')}', () {
      final offenders = <String>[];
      for (final file in _dartFilesUnder(dir)) {
        final lines = File(file).readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          if (_isCommentLine(line)) continue;
          if (_typedRe.hasMatch(line)) continue;
          if (!_untypedCatchRe.hasMatch(line)) continue;
          if (_bareUnderscoreRe.hasMatch(line)) {
            offenders.add('$file:${i + 1}: bare-underscore: ${line.trim()}');
            continue;
          }
          final body = _catchBody(lines, i, file);
          if (body != null && !_markerRe.hasMatch(body)) {
            offenders.add('$file:${i + 1}: silent catch: ${line.trim()}');
          }
        }
      }
      expect(offenders, isEmpty,
          reason: 'انتهاك قاعدة عدم الصمت (M10):\n'
              '${offenders.join('\n')}\n'
              'القاعدة والحدود في docs/ERROR_HANDLING.md');
    });
  }

  for (final dir in uiDirs) {
    test('M10: لا bare-underscore في ${dir.join('/')}', () {
      final offenders = <String>[];
      for (final file in _dartFilesUnder(dir)) {
        final lines = File(file).readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          if (_isCommentLine(line)) continue;
          if (_typedRe.hasMatch(line)) continue;
          if (_untypedCatchRe.hasMatch(line) &&
              _bareUnderscoreRe.hasMatch(line)) {
            offenders.add('$file:${i + 1}: ${line.trim()}');
          }
        }
      }
      expect(offenders, isEmpty,
          reason: 'واجهات التطبيقات فيها bare-underscore catch:\n'
              '${offenders.join('\n')}');
    });
  }
}