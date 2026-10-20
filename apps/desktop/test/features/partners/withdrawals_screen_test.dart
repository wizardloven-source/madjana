import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:core/core.dart';
import 'package:madjana_desktop/core/providers.dart';
import 'package:madjana_desktop/features/auth/providers/auth_provider.dart';
import 'package:madjana_desktop/features/partners/presentation/withdrawals_screen.dart';

/// اختبارات W7.4-UI: إظهار القائمة، والأزرار حسب حالة السحب.
///
/// * pending → «موافقة» (RPC) + «رفض»
/// * approved → «دفع»
/// * paid/rejected → عرض فقط (لا أزرار إجراء)
///
/// كل حالة تُختبر بمعزل عن غيرها ببيانات وهمية واحدة، حتى لا تتسرب أزرار
/// صفٍّ آخر إلى فحوص «لا يوجد».
void main() {
  testWidgets('القائمة تظهر: الشريك والمبلغ والحالة وزر الطلب الجديد',
      (tester) async {
    await tester.pumpWidget(
        _app(_withdrawal(status: PartnerWithdrawalStatus.pending)));
    await tester.pumpAndSettle();

    expect(find.byType(DataTable), findsOneWidget);
    expect(find.text('أحمد'), findsOneWidget);
    expect(find.text('150'), findsOneWidget);
    expect(find.text('قيد المراجعة'), findsOneWidget);
    expect(find.text('طلب سحب جديد'), findsOneWidget);
    expect(find.byType(WithdrawalsScreen), findsOneWidget);
  });

  testWidgets('يُرجع شاشة السحوبات جذر Scaffold (DropdownButton تحتاج Material ancestor)',
      (tester) async {
    await tester.pumpWidget(
        _app(_withdrawal(status: PartnerWithdrawalStatus.pending)));
    await tester.pumpAndSettle();

    expect(find.byType(Scaffold), findsOneWidget);
    expect(find.text('طلب سحب جديد'), findsOneWidget);
  });

  testWidgets('pending: أزرار «موافقة» و«رفض» ولا زر دفع', (tester) async {
    await tester.pumpWidget(
        _app(_withdrawal(status: PartnerWithdrawalStatus.pending)));
    await tester.pumpAndSettle();

    expect(find.text('موافقة'), findsOneWidget);
    expect(find.text('رفض'), findsOneWidget);
    expect(find.text('دفع'), findsNothing);
  });

  testWidgets('approved: زر «دفع» فقط', (tester) async {
    await tester.pumpWidget(
        _app(_withdrawal(status: PartnerWithdrawalStatus.approved)));
    await tester.pumpAndSettle();

    expect(find.text('دفع'), findsOneWidget);
    expect(find.text('موافقة'), findsNothing);
    expect(find.text('رفض'), findsNothing);
  });

  testWidgets('paid: عرض فقط — لا أزرار إجراء', (tester) async {
    await tester.pumpWidget(
        _app(_withdrawal(status: PartnerWithdrawalStatus.paid)));
    await tester.pumpAndSettle();

    expect(find.text('موافقة'), findsNothing);
    expect(find.text('رفض'), findsNothing);
    expect(find.text('دفع'), findsNothing);
    expect(find.text('مدفوع'), findsWidgets);
    expect(find.byTooltip('تفاصيل'), findsOneWidget);
  });
}

Widget _app(PartnerWithdrawal withdrawal) {
  final user = UserModel(
    uid: 'u1',
    name: 'مستخدم',
    phone: '000',
    role: UserRole.manager,
    farmId: 'farm-1',
    createdAt: DateTime(2026, 1, 1),
  );

  return ProviderScope(
    overrides: [
      authProvider.overrideWith((ref) => _FakeAuthNotifier(user)),
      partnerWithdrawalRepositoryProvider
          .overrideWithValue(_FakeWithdrawalRepository([withdrawal])),
      partnerRepositoryProvider
          .overrideWithValue(_FakePartnerRepository()),
    ],
    child: const MaterialApp(
      home: Scaffold(body: WithdrawalsScreen()),
    ),
  );
}

PartnerWithdrawal _withdrawal({required PartnerWithdrawalStatus status}) =>
    PartnerWithdrawal(
      id: 'w-1',
      partnerId: 'p-1',
      farmId: 'farm-1',
      amount: 150,
      status: status,
      requestedAt: DateTime(2026, 10, 1),
      requestedBy: 'u1',
      reason: 'اشتياق',
    );

class _FakeWithdrawalRepository implements PartnerWithdrawalRepository {
  _FakeWithdrawalRepository(this.rows);

  final List<PartnerWithdrawal> rows;

  @override
  Future<List<PartnerWithdrawal>> getWithdrawals({
    String? partnerId,
    String? farmId,
    PartnerWithdrawalStatus? status,
  }) async =>
      rows;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _FakePartnerRepository implements PartnerRepository {
  @override
  Future<List<PartnerModel>> getPartners() async =>
      const [PartnerModel(id: 'p-1', name: 'أحمد')];

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
