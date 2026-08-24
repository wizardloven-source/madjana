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

// ─────────────── الـ DAOs المحلية ───────────────
final eggProductionDaoProvider = Provider<EggProductionDao>((ref) => EggProductionDao());
final mortalityDaoProvider = Provider<MortalityDao>((ref) => MortalityDao());
final feedDaoProvider = Provider<FeedDao>((ref) => FeedDao());
final dispatchDaoProvider = Provider<DispatchDao>((ref) => DispatchDao());
final medicationDaoProvider = Provider<MedicationDao>((ref) => MedicationDao());
final customerDaoProvider = Provider<CustomerDao>((ref) => CustomerDao());
final flockDaoProvider = Provider<FlockDao>((ref) => FlockDao());
final sessionDaoProvider = Provider<SessionDao>((ref) => SessionDao());
final syncQueueDaoProvider = Provider<SyncQueueDao>((ref) => SyncQueueDao());
final paymentDaoProvider = Provider<PaymentDao>((ref) => PaymentDao());
final expenseDaoProvider = Provider<ExpenseDao>((ref) => ExpenseDao());
final inventoryDaoProvider = Provider<InventoryDao>((ref) => InventoryDao());
final settingsDaoProvider = Provider<SettingsDao>((ref) => SettingsDao());

// ─────────────── المصادر البعيدة ───────────────
final supabaseAuthDatasourceProvider = Provider<SupabaseAuthDatasource>(
  (ref) => SupabaseAuthDatasource(ref.watch(supabaseClientProvider)),
);
final supabaseEggDatasourceProvider = Provider<SupabaseEggDatasource>(
  (ref) => SupabaseEggDatasource(ref.watch(supabaseClientProvider)),
);
final supabaseMortalityDatasourceProvider = Provider<SupabaseMortalityDatasource>(
  (ref) => SupabaseMortalityDatasource(ref.watch(supabaseClientProvider)),
);
final supabaseFeedDatasourceProvider = Provider<SupabaseFeedDatasource>(
  (ref) => SupabaseFeedDatasource(ref.watch(supabaseClientProvider)),
);
final supabaseDispatchDatasourceProvider = Provider<SupabaseDispatchDatasource>(
  (ref) => SupabaseDispatchDatasource(ref.watch(supabaseClientProvider)),
);
final supabaseMedicationDatasourceProvider = Provider<SupabaseMedicationDatasource>(
  (ref) => SupabaseMedicationDatasource(ref.watch(supabaseClientProvider)),
);
final supabaseFlockDatasourceProvider = Provider<SupabaseFlockDatasource>(
  (ref) => SupabaseFlockDatasource(ref.watch(supabaseClientProvider)),
);
final supabaseUserAdminDatasourceProvider = Provider<SupabaseUserAdminDatasource>(
  (ref) => SupabaseUserAdminDatasource(ref.watch(supabaseClientProvider)),
);
final supabaseExpenseDatasourceProvider = Provider<SupabaseExpenseDatasource>(
  (ref) => SupabaseExpenseDatasource(ref.watch(supabaseClientProvider)),
);
final supabaseInventoryDatasourceProvider = Provider<SupabaseInventoryDatasource>(
  (ref) => SupabaseInventoryDatasource(ref.watch(supabaseClientProvider)),
);
final supabaseFarmDatasourceProvider = Provider<SupabaseFarmDatasource>(
  (ref) => SupabaseFarmDatasource(ref.watch(supabaseClientProvider)),
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
  ),
);

final flockRepositoryProvider = Provider<FlockRepository>(
  (ref) => FlockRepositoryImpl(
    localDao: ref.watch(flockDaoProvider),
    remoteDatasource: ref.watch(supabaseFlockDatasourceProvider),
  ),
);

final userAdminRepositoryProvider = Provider<UserAdminRepository>(
  (ref) => UserAdminRepositoryImpl(
    remoteDatasource: ref.watch(supabaseUserAdminDatasourceProvider),
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
    syncQueueDao: ref.watch(syncQueueDaoProvider),
    remoteEgg: ref.watch(supabaseEggDatasourceProvider),
    remoteMortality: ref.watch(supabaseMortalityDatasourceProvider),
    remoteFeed: ref.watch(supabaseFeedDatasourceProvider),
    remoteDispatch: ref.watch(supabaseDispatchDatasourceProvider),
    remoteMedication: ref.watch(supabaseMedicationDatasourceProvider),
  ),
);