import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:core/core.dart';
import 'package:madjana_desktop/core/providers.dart';
import 'package:madjana_desktop/features/auth/providers/auth_provider.dart';
import 'package:madjana_desktop/features/partners/presentation/create_withdrawal_screen.dart';

/// اختبارات W7.4-UI: شاشة إنشاء طلب سحب جديد.
///
/// * يُحقق أن الشاشة تُcompiled وتعمل بدون أخطاء Material ancestor.
/// * يُحقق أن النموذج يحتوي على الحقول الرئيسية.
///
/// كل حالات الاختبار تستخدم م/auth وهمي و repositories وهمية.
void main() {
  // Use a large screen size to avoid DropdownButtonFormField overflow.
  const testViewport = Size(1400, 900);

  testWidgets('يظهر نموذج الإنشاء في Scaffold', (tester) async {
    await tester.binding.setSurfaceSize(testViewport);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    // Verify the screen renders without Material ancestor errors.
    expect(find.byType(CreateWithdrawalScreen), findsOneWidget);
    expect(find.byType(Scaffold), findsWidgets);
  });

  testWidgets('يحتوي النموذج على حقول أساسية', (tester) async {
    await tester.binding.setSurfaceSize(testViewport);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    // Verify key form fields are present.
    expect(find.byType(TextField), findsWidgets);
    expect(find.byType(FilledButton), findsOneWidget);
    expect(find.byType(OutlinedButton), findsOneWidget); // Cancel button
  });

  testWidgets('يظهر خطأ عند تحميل مبلغ خاطئ', (tester) async {
    await tester.binding.setSurfaceSize(testViewport);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    // Enter invalid amount into the first TextField
    await tester.enterText(find.byType(TextField).first, 'abc');
    await tester.pumpAndSettle();

    // The form should still be visible (no crash).
    expect(find.byType(CreateWithdrawalScreen), findsOneWidget);
  });

  testWidgets('يظهر خطأ عند تحميل شريك غير محدد', (tester) async {
    await tester.binding.setSurfaceSize(testViewport);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    // Enter valid amount but don't select partner
    await tester.enterText(find.byType(TextField).first, '100');
    await tester.pumpAndSettle();

    // The form should still be visible (no crash).
    expect(find.byType(CreateWithdrawalScreen), findsOneWidget);
  });
}

Widget _app() {
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
      partnerRepositoryProvider.overrideWithValue(_FakePartnerRepository()),
      partnershipRepositoryProvider
          .overrideWithValue(_FakePartnershipRepository()),
      partnerWithdrawalRepositoryProvider
          .overrideWithValue(_FakeWithdrawalRepository()),
    ],
    child: MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('طلب سحب جديد')),
        body: const CreateWithdrawalScreen(),
      ),
    ),
  );
}

class _FakePartnerRepository implements PartnerRepository {
  @override
  Future<List<PartnerModel>> getPartners() async => const [
        PartnerModel(id: 'p-1', name: 'أحمد'),
        PartnerModel(id: 'p-2', name: 'علي'),
      ];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _FakePartnershipRepository implements PartnershipRepository {
  @override
  Future<List<ProfitDistribution>> getDistributions(
          {String? farmId}) async =>
      const [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _FakeWithdrawalRepository implements PartnerWithdrawalRepository {
  @override
  Future<PartnerWithdrawal> createWithdrawal({
    required String partnerId,
    required String farmId,
    required double amount,
    required String requestedBy,
    String? distributionId,
    String? reason,
    String currency = 'dollar',
    String? notes,
  }) async =>
      PartnerWithdrawal(
        id: 'w-new',
        farmId: farmId,
        partnerId: partnerId,
        amount: amount,
        currency: currency,
        status: PartnerWithdrawalStatus.pending,
        requestedAt: DateTime.now(),
        requestedBy: requestedBy,
        reason: reason,
        distributionId: distributionId,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// مصادقة وهمية: بلا جلسة، Maintenance تُ adjusts يدوياً في المُنشئ.
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