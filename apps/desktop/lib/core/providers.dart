import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:core/core.dart';
import 'package:data/data.dart';
import 'supabase_client.dart';

/// ═══════════════════════════════════════════════
/// حاوية التبعيات (Dependency Injection)
/// ═══════════════════════════════════════════════

/// عميل Supabase
final supabaseClientProvider = Provider<SupabaseClient>(
  (ref) => SupabaseConfig.client,
);

/// واجهة Supabase المجرّدة (منفصلة عن SupabaseClient لتسهيل الاختبار)
final supabaseApiProvider = Provider<SupabaseApi>(
  (ref) => SupabaseClientApiAdapter(ref.watch(supabaseClientProvider)),
);

// ─────────────── الـ DAOs المحلية ───────────────
final eggProductionDaoProvider = Provider<EggProductionDao>((ref) => EggProductionDao());
final mortalityDaoProvider = Provider<MortalityDao>((ref) => MortalityDao());
final feedDaoProvider = Provider<FeedDao>((ref) => FeedDao());
final dispatchDaoProvider = Provider<DispatchDao>((ref) => DispatchDao());
final dispatchRequestDaoProvider = Provider<DispatchRequestDao>((ref) => DispatchRequestDao());
final medicationDaoProvider = Provider<MedicationDao>((ref) => MedicationDao());
final customerDaoProvider = Provider<CustomerDao>((ref) => CustomerDao());
final flockDaoProvider = Provider<FlockDao>((ref) => FlockDao());
final sessionDaoProvider = Provider<SessionDao>((ref) => SessionDao());
final syncQueueDaoProvider = Provider<SyncQueueDao>((ref) => SyncQueueDao());
final paymentDaoProvider = Provider<PaymentDao>((ref) => PaymentDao());
final expenseDaoProvider = Provider<ExpenseDao>((ref) => ExpenseDao());
final inventoryDaoProvider = Provider<InventoryDao>((ref) => InventoryDao());
final settingsDaoProvider = Provider<SettingsDao>((ref) => SettingsDao());
final openingBalanceDaoProvider = Provider<OpeningBalanceDao>((ref) => OpeningBalanceDao());
final userDaoProvider = Provider<UserDao>((ref) => UserDao());

// ─────────────── المصادر البعيدة ───────────────
final supabaseAuthDatasourceProvider = Provider<SupabaseAuthDatasource>(
  (ref) => SupabaseAuthDatasource(ref.watch(supabaseClientProvider)),
);
final supabaseEggDatasourceProvider = Provider<SupabaseEggDatasource>(
  (ref) => SupabaseEggDatasource(ref.watch(supabaseApiProvider)),
);
final supabaseMortalityDatasourceProvider = Provider<SupabaseMortalityDatasource>(
  (ref) => SupabaseMortalityDatasource(ref.watch(supabaseApiProvider)),
);
final supabaseFeedDatasourceProvider = Provider<SupabaseFeedDatasource>(
  (ref) => SupabaseFeedDatasource(ref.watch(supabaseApiProvider)),
);
final supabaseDispatchDatasourceProvider = Provider<SupabaseDispatchDatasource>(
  (ref) => SupabaseDispatchDatasource(ref.watch(supabaseApiProvider)),
);
final supabaseMedicationDatasourceProvider = Provider<SupabaseMedicationDatasource>(
  (ref) => SupabaseMedicationDatasource(ref.watch(supabaseApiProvider)),
);
final supabaseFlockDatasourceProvider = Provider<SupabaseFlockDatasource>(
  (ref) => SupabaseFlockDatasource(ref.watch(supabaseApiProvider)),
);
final supabaseUserAdminDatasourceProvider = Provider<SupabaseUserAdminDatasource>(
  (ref) => SupabaseUserAdminDatasource(ref.watch(supabaseApiProvider)),
);
final supabaseExpenseDatasourceProvider = Provider<SupabaseExpenseDatasource>(
  (ref) => SupabaseExpenseDatasource(ref.watch(supabaseApiProvider)),
);
final supabaseInventoryDatasourceProvider = Provider<SupabaseInventoryDatasource>(
  (ref) => SupabaseInventoryDatasource(ref.watch(supabaseApiProvider)),
);
final supabaseFarmDatasourceProvider = Provider<SupabaseFarmDatasource>(
  (ref) => SupabaseFarmDatasource(ref.watch(supabaseApiProvider)),
);
final supabasePaymentDatasourceProvider = Provider<SupabasePaymentDatasource>(
  (ref) => SupabasePaymentDatasource(ref.watch(supabaseApiProvider)),
);
final supabaseOpeningBalanceDatasourceProvider = Provider<SupabaseOpeningBalanceDatasource>(
  (ref) => SupabaseOpeningBalanceDatasource(ref.watch(supabaseApiProvider)),
);
final supabaseNotificationDatasourceProvider = Provider<SupabaseNotificationDatasource>(
  (ref) => SupabaseNotificationDatasource(ref.watch(supabaseApiProvider)),
);

// ─────────────── المستودعات ───────────────
final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => AuthRepositoryImpl(
    remoteDatasource: ref.watch(supabaseAuthDatasourceProvider),
    sessionDao: ref.watch(sessionDaoProvider),
  ),
);

final eggProductionRepositoryProvider = Provider<EggProductionRepository>(
  (ref) => EggProductionRepositoryImpl(
    localDao: ref.watch(eggProductionDaoProvider),
    remoteDatasource: ref.watch(supabaseEggDatasourceProvider),
  ),
);

final mortalityRepositoryProvider = Provider<MortalityRepository>(
  (ref) => MortalityRepositoryImpl(
    localDao: ref.watch(mortalityDaoProvider),
    remoteDatasource: ref.watch(supabaseMortalityDatasourceProvider),
  ),
);

final feedRepositoryProvider = Provider<FeedRepository>(
  (ref) => FeedRepositoryImpl(
    localDao: ref.watch(feedDaoProvider),
    remoteDatasource: ref.watch(supabaseFeedDatasourceProvider),
  ),
);

final dispatchRepositoryProvider = Provider<DispatchRepository>(
  (ref) => DispatchRepositoryImpl(
    localDao: ref.watch(dispatchDaoProvider),
    customerDao: ref.watch(customerDaoProvider),
    remoteDatasource: ref.watch(supabaseDispatchDatasourceProvider),
  ),
);

final medicationRepositoryProvider = Provider<MedicationRepository>(
  (ref) => MedicationRepositoryImpl(
    localDao: ref.watch(medicationDaoProvider),
    remoteDatasource: ref.watch(supabaseMedicationDatasourceProvider),
  ),
);

final paymentRepositoryProvider = Provider<PaymentRepository>(
  (ref) => PaymentRepositoryImpl(
    paymentDao: ref.watch(paymentDaoProvider),
    dispatchDao: ref.watch(dispatchDaoProvider),
    remoteDatasource: ref.watch(supabasePaymentDatasourceProvider),
  ),
);

final flockRepositoryProvider = Provider<FlockRepository>(
  (ref) => FlockRepositoryImpl(
    localDao: ref.watch(flockDaoProvider),
    remoteDatasource: ref.watch(supabaseFlockDatasourceProvider),
  ),
);

final openingBalanceRepositoryProvider = Provider<OpeningBalanceRepository>(
  (ref) => OpeningBalanceRepositoryImpl(
    localDao: ref.watch(openingBalanceDaoProvider),
    remoteDatasource: ref.watch(supabaseOpeningBalanceDatasourceProvider),
  ),
);

final userAdminRepositoryProvider = Provider<UserAdminRepository>(
  (ref) => UserAdminRepositoryImpl(
    remoteDatasource: ref.watch(supabaseUserAdminDatasourceProvider),
    userDao: ref.watch(userDaoProvider),
  ),
);

final expenseRepositoryProvider = Provider<ExpenseRepository>(
  (ref) => ExpenseRepositoryImpl(
    localDao: ref.watch(expenseDaoProvider),
    remoteDatasource: ref.watch(supabaseExpenseDatasourceProvider),
  ),
);

final inventoryRepositoryProvider = Provider<InventoryRepository>(
  (ref) => InventoryRepositoryImpl(
    localDao: ref.watch(inventoryDaoProvider),
    remoteDatasource: ref.watch(supabaseInventoryDatasourceProvider),
  ),
);

final farmRepositoryProvider = Provider<FarmRepository>(
  (ref) => FarmRepositoryImpl(
    remoteDatasource: ref.watch(supabaseFarmDatasourceProvider),
    settingsDao: ref.watch(settingsDaoProvider),
  ),
);

/// عملة العرض (تُحمّل من الإعدادات المحلية)
final currencyProvider = FutureProvider<String>((ref) async {
  final repo = ref.watch(farmRepositoryProvider);
  return repo.getCurrency();
});

/// مزامنة السجلات المعلقة (تلقائياً بعد فتح التطبيق)
final syncRepositoryProvider = Provider<SyncRepository>(
  (ref) => SyncRepositoryImpl(
    eggDao: ref.watch(eggProductionDaoProvider),
    mortalityDao: ref.watch(mortalityDaoProvider),
    feedDao: ref.watch(feedDaoProvider),
    dispatchDao: ref.watch(dispatchDaoProvider),
    medicationDao: ref.watch(medicationDaoProvider),
    customerDao: ref.watch(customerDaoProvider),
    paymentDao: ref.watch(paymentDaoProvider),
    expenseDao: ref.watch(expenseDaoProvider),
    syncQueueDao: ref.watch(syncQueueDaoProvider),
    remoteEgg: ref.watch(supabaseEggDatasourceProvider),
    remoteMortality: ref.watch(supabaseMortalityDatasourceProvider),
    remoteFeed: ref.watch(supabaseFeedDatasourceProvider),
    remoteDispatch: ref.watch(supabaseDispatchDatasourceProvider),
    remoteMedication: ref.watch(supabaseMedicationDatasourceProvider),
    remotePayment: ref.watch(supabasePaymentDatasourceProvider),
  ),
);

final notificationRepositoryProvider = Provider<NotificationRepository>(
  (ref) => NotificationRepositoryImpl(
    remoteDatasource: ref.watch(supabaseNotificationDatasourceProvider),
  ),
);