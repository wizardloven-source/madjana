import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:core/core.dart';
import 'package:madjana_desktop/core/providers.dart';
import 'package:madjana_desktop/features/auth/providers/auth_provider.dart';
import 'package:madjana_desktop/features/partners/presentation/profit_distribution_screen.dart';
import 'package:madjana_desktop/shared/widgets/farm_dropdown.dart';

/// اختبارات W7.3-UI: إظهار/إخفاء أزرار «إنشاء التوزيع» و«اعتماد» حسب وجود
/// توزيع للفترة وحالته ودور المستخدم.
void main() {
  testWidgets('يظهر زر «إنشاء التوزيع» عندما لا يوجد توزيع للفترة',
      (tester) async {
    await tester.pumpWidget(_app(role: UserRole.manager, distribution: null));
    await tester.pumpAndSettle();

    expect(find.text('إنشاء التوزيع'), findsOneWidget);
    expect(find.text('اعتماد'), findsNothing);
  });

  testWidgets('يظهر زر «اعتماد» لمدير النظام على رأس مسودة فقط',
      (tester) async {
    await tester.pumpWidget(
        _app(role: UserRole.system_admin, distribution: _draft()));
    await tester.pumpAndSettle();

    expect(find.text('اعتماد'), findsOneWidget);
    expect(find.text('إنشاء التوزيع'), findsNothing);
    expect(find.textContaining('مسودة'), findsOneWidget);
  });

  testWidgets('لا يظهر زر «اعتماد» للمدير حتى مع رأس مسودة', (tester) async {
    await tester.pumpWidget(
        _app(role: UserRole.manager, distribution: _draft()));
    await tester.pumpAndSettle();

    expect(find.text('اعتماد'), findsNothing);
    expect(find.text('إنشاء التوزيع'), findsNothing);
  });

  testWidgets('لا يظهر زر «اعتماد» بعد الاعتماد (approved)',
      (tester) async {
    await tester.pumpWidget(_app(
      role: UserRole.system_admin,
      distribution: _draft(status: ProfitDistributionStatus.approved),
    ));
    await tester.pumpAndSettle();

    expect(find.text('اعتماد'), findsNothing);
    expect(find.textContaining('معتمد'), findsOneWidget);
  });
}

Widget _app({
  required UserRole role,
  required ProfitDistribution? distribution,
}) {
  final repo = _FakePartnershipRepository()..distribution = distribution;
  final user = UserModel(
    uid: 'u1',
    name: 'مستخدم',
    phone: '000',
    role: role,
    farmId: 'farm-1',
    createdAt: DateTime(2026, 1, 1),
  );

  return ProviderScope(
    overrides: [
      authProvider.overrideWith((ref) => _FakeAuthNotifier(user)),
      partnershipRepositoryProvider.overrideWithValue(repo),
      flockRepositoryProvider.overrideWithValue(_FakeFlockRepository()),
      partnerRepositoryProvider.overrideWithValue(_FakePartnerRepository()),
      currentUserFarmsProvider
          .overrideWith((ref) => const [FarmModel(id: 'farm-1', name: 'مدجنة')]),
    ],
    child: const MaterialApp(
      home: Scaffold(body: ProfitDistributionScreen()),
    ),
  );
}

ProfitDistribution _draft({ProfitDistributionStatus? status}) =>
    ProfitDistribution(
      id: 'd-1',
      farmId: 'farm-1',
      periodStart: DateTime(2026, 10, 1),
      periodEnd: DateTime(2026, 10, 31),
      status: status ?? ProfitDistributionStatus.draft,
      totalRevenue: 2000,
      totalExpenses: 500,
      netProfit: 1500,
      reserveAmount: 0,
      distributableProfit: 1500,
    );

class _FakePartnershipRepository implements PartnershipRepository {
  ProfitDistribution? distribution;

  @override
  Future<ProfitDistribution?> getDistribution({
    required String farmId,
    required DateTime periodStart,
    required DateTime periodEnd,
    String? flockId,
  }) async =>
      distribution;

  @override
  Future<String> createDistribution({
    required String farmId,
    required DateTime periodStart,
    required DateTime periodEnd,
    String? flockId,
    double reserveAmount = 0,
    String? label,
    String? notes,
  }) async =>
      'dist-new';

  @override
  Future<void> approveDistribution({required String distributionId}) async {}

  @override
  Future<List<ProfitDistributionPreview>> calculateDistribution({
    required String farmId,
    required DateTime periodStart,
    required DateTime periodEnd,
    String? flockId,
  }) async =>
      const [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// مصادقة وهمية: بلا جلسة، والحالة تُضبط يدوياً في المُنشئ.
class _FakeAuthNotifier extends AuthNotifier {
  _FakeAuthNotifier(UserModel user) : super(_FakeAuthRepository()) {
    state = AuthState(currentUser: user);
  }
}

class _FakeAuthRepository implements AuthRepository {
  @override
  Future<bool> hasActiveSession() async => false;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _FakeFlockRepository implements FlockRepository {
  @override
  Future<List<FlockModel>> getFlocks(String farmId, {bool includeEnded = false}) async =>
      const [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _FakePartnerRepository implements PartnerRepository {
  @override
  Future<List<PartnerModel>> getPartners() async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
