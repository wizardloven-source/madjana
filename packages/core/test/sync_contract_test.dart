import 'package:test/test.dart';
import 'package:core/core.dart';

/// M9 — بوابة عقد المزامنة (docs/SYNC.md).
///
/// تتحقق من أن منطق البوابة يقارن **عقد العميل** (kSyncContractVersion) بإصدار
/// الخادم، لا `_dbVersion` المحلي (مقياس مختلف)، وأنّ السلوك:
///   * match       → مسح (لا حظر)
///   * serverAhead → حظر
///   * clientAhead → تحذير (لا حظر)
///   * unknown     → لا حظر (offline-first)
void main() {
  group('evaluateSyncContract — حالات البوابة', () {
    test('عقد == خادم → match (مسح)', () {
      expect(
        evaluateSyncContract(contractVersion: 1, serverVersion: 1),
        SyncContractState.match,
      );
    });

    test('عقد < خادم → serverAhead (حظر)', () {
      expect(
        evaluateSyncContract(contractVersion: 1, serverVersion: 2),
        SyncContractState.serverAhead,
      );
    });

    test('عقد > خادم → clientAhead (تحذير لا حظر)', () {
      expect(
        evaluateSyncContract(contractVersion: 2, serverVersion: 1),
        SyncContractState.clientAhead,
      );
    });

    test('تعذّر قراءة الخادم (null) → unknown (لا حظر)', () {
      expect(
        evaluateSyncContract(contractVersion: 1, serverVersion: null),
        SyncContractState.unknown,
      );
    });

    test('لا يعتمد على _dbVersion: عقد=1 يطابق خادم=1 رغم ترحيل محلي = 30', () {
      // 30 رقم ترحيل محلي بحت؛ لا يدخل المقارنة. البوابة تبقى match على 1==1.
      expect(
        evaluateSyncContract(contractVersion: kSyncContractVersion, serverVersion: 1),
        SyncContractState.match,
      );
    });
  });

  group('kSyncContractVersion', () {
    test('ينطلق من 1 (متوافق مع صف app_schema_version الأولي)', () {
      expect(kSyncContractVersion, 1);
    });
  });
}
