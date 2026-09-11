import 'package:core/core.dart';
import 'package:test/test.dart';

void main() {
  MortalityModel _sample({
    String? imageUrl,
    MortalityReason reason = MortalityReason.other,
    String? reasonOther = 'سبب تجريبي',
    String? notes,
    int count = 10,
    SyncStatus syncStatus = SyncStatus.pending,
  }) {
    return MortalityModel(
      id: 'm1',
      farmId: 'farm-1',
      flockId: 'flock-1',
      date: DateTime(2026, 9, 10),
      count: count,
      reason: reason,
      reasonOther: reasonOther,
      notes: notes,
      imageUrl: imageUrl,
      workerId: 'worker-1',
      syncStatus: syncStatus,
      sectionNo: 3,
      version: 2,
    );
  }

  // P1-010 regression: copyWith يحافظ على جميع الحقول
  group('MortalityModel.copyWith — P1-010 regression', () {
    test('يحافظ على جميع الحقول عند تغيير imageUrl فقط', () {
      final original = _sample(notes: 'ملاحظة اختبار');
      final updated = original.copyWith(imageUrl: 'https://img.test/new.jpg');

      expect(updated.imageUrl, 'https://img.test/new.jpg');
      expect(updated.id, original.id);
      expect(updated.farmId, original.farmId);
      expect(updated.flockId, original.flockId);
      expect(updated.date, original.date);
      expect(updated.count, original.count);
      expect(updated.reason, original.reason);
      expect(updated.reasonOther, original.reasonOther);
      expect(updated.notes, original.notes);
      expect(updated.workerId, original.workerId);
      expect(updated.syncStatus, original.syncStatus);
      expect(updated.sectionNo, original.sectionNo);
      expect(updated.version, original.version);
    });

    test('يُحدّث الحقول المطلوبة فقط ويبقي الباقي', () {
      final original = _sample(count: 50, reason: MortalityReason.heatStress);
      final updated = original.copyWith(count: 100, notes: 'ملاحظة جديدة');

      expect(updated.count, 100);
      expect(updated.notes, 'ملاحظة جديدة');
      expect(updated.reason, MortalityReason.heatStress);
      expect(updated.reasonOther, original.reasonOther);
      expect(updated.workerId, original.workerId);
    });

    test('يُعيد نفس الكائن عندما لا تُمرَّر أي معاملات', () {
      final original = _sample();
      final same = original.copyWith();

      expect(same.id, original.id);
      expect(same.farmId, original.farmId);
      expect(same.count, original.count);
      expect(same.date, original.date);
      expect(same.reason, original.reason);
      expect(same.workerId, original.workerId);
      expect(same.syncStatus, original.syncStatus);
    });

    test('يُحدّث imageUrl من null إلى قيمة', () {
      final original = _sample(imageUrl: null);
      final updated = original.copyWith(imageUrl: 'https://img.test/photo.jpg');
      expect(updated.imageUrl, 'https://img.test/photo.jpg');
    });

    test('copyWith(null) لا يُغيّر imageUrl الحالي (سلوك copyWith القياسي)', () {
      final original = _sample(imageUrl: 'https://img.test/old.jpg');
      final updated = original.copyWith(imageUrl: null);
      expect(updated.imageUrl, 'https://img.test/old.jpg');
    });
  });

  // P1-011 regression: SaveMortalityUseCase zero-guard
  group('SaveMortalityUseCase — P1-011 regression: zero flock guard', () {
    late _FakeMortalityRepository repo;

    setUp(() {
      repo = _FakeMortalityRepository(flockCount: 0);
    });

    test('لا يُسقط عندما يكون عدد القطيع = 0', () async {
      final useCase = SaveMortalityUseCase(repo);
      final record = MortalityModel(
        farmId: 'farm-1',
        flockId: 'flock-1',
        date: DateTime(2026, 9, 10),
        count: 5,
        reason: MortalityReason.other,
        reasonOther: 'سبب',
        workerId: 'worker-1',
      );

      final result = await useCase.call(record);
      expect(result.success, true);
      expect(result.mortalityPercentage, 0.0);
      expect(result.highMortalityWarning, false);
    });

    test('يحسب النسبة بشكل صحيح عندما يكون عدد القطيع أكبر من صفر', () async {
      repo = _FakeMortalityRepository(flockCount: 1000);
      final useCase = SaveMortalityUseCase(repo);
      final record = MortalityModel(
        farmId: 'farm-1',
        flockId: 'flock-1',
        date: DateTime(2026, 9, 10),
        count: 20,
        reason: MortalityReason.other,
        reasonOther: 'سبب',
        workerId: 'worker-1',
      );

      final result = await useCase.call(record);
      expect(result.success, true);
      expect(result.mortalityPercentage, 2.0);
      expect(result.highMortalityWarning, true); // > 1%
    });

    test('لا يُطلق تحذير عندما تكون النسبة أقل من 1%', () async {
      repo = _FakeMortalityRepository(flockCount: 5000);
      final useCase = SaveMortalityUseCase(repo);
      final record = MortalityModel(
        farmId: 'farm-1',
        flockId: 'flock-1',
        date: DateTime(2026, 9, 10),
        count: 10,
        reason: MortalityReason.other,
        reasonOther: 'سبب',
        workerId: 'worker-1',
      );

      final result = await useCase.call(record);
      expect(result.success, true);
      expect(result.mortalityPercentage, closeTo(0.2, 0.01));
      expect(result.highMortalityWarning, false);
    });
  });
}

/// مستودع محاكي للاختبار
class _FakeMortalityRepository implements MortalityRepository {
  int flockCount;

  _FakeMortalityRepository({this.flockCount = 1000});

  @override
  Future<int> getFlockCurrentCount(String flockId) async => flockCount;

  @override
  Future<void> saveLocal(MortalityModel record) async {}

  @override
  Future<List<MortalityModel>> getAllRecords({
    String? farmId,
    DateTime? fromDate,
    DateTime? toDate,
  }) async =>
      [];

  @override
  Future<List<MortalityModel>> getTodayRecords(String farmId) async => [];

  @override
  Future<void> syncPendingRecords() async {}

  @override
  Future<void> deleteRecord(String id) async {}

  @override
  Future<String?> uploadImage(dynamic imageFile, String recordId,
          {required String farmId}) async =>
      null;
}
