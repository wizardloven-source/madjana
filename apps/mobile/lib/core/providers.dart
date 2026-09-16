import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:core/core.dart';
import 'package:data/data.dart';
import 'supabase_client.dart';
import '../features/auth/providers/auth_provider.dart';
import '../features/sync/data/connectivity_service.dart';

/// ═══════════════════════════════════════════════
/// حاوية التبعيات (Dependency Injection)
/// ═══════════════════════════════════════════════

/// عميل Supabase — يعيد null عند عدم التهيئة (Offline)
/// ═══ CR-4 FIX ═══
final supabaseClientProvider = Provider<SupabaseClient?>(
  (ref) => SupabaseConfig.client,
);

/// واجهة Supabase المجرّدة (منفصلة عن SupabaseClient لتسهيل الاختبار)
/// ═══ CR-4 FIX: تعيد adapter فارغة عند غياب الاتصال بدلاً من الرمي ═══
final supabaseApiProvider = Provider<SupabaseApi>(
  (ref) {
    final client = ref.watch(supabaseClientProvider);
    if (client == null) return SupabaseClientApiAdapter.offline();
    return SupabaseClientApiAdapter(client);
  },
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
final settingsDaoProvider = Provider<SettingsDao>((ref) => SettingsDao());
final syncQueueDaoProvider = Provider<SyncQueueDao>((ref) => SyncQueueDao());
final notesDaoProvider = Provider<NotesDao>((ref) => NotesDao());
final paymentDaoProvider = Provider<PaymentDao>((ref) => PaymentDao());
final userDaoProvider = Provider<UserDao>((ref) => UserDao());
final openingBalanceDaoProvider = Provider<OpeningBalanceDao>((ref) => OpeningBalanceDao());


// ─────────────── المصادر البعيدة ───────────────
/// ═══ CR-4 FIX: مصادر Supabase تتعامل مع عدم الاتصال ═══
final supabaseAuthDatasourceProvider = Provider<SupabaseAuthDatasource?>(
  (ref) {
    final client = ref.watch(supabaseClientProvider);
    if (client == null) return null;
    return SupabaseAuthDatasource(client);
  },
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
final supabasePaymentDatasourceProvider = Provider<SupabasePaymentDatasource>(
  (ref) => SupabasePaymentDatasource(ref.watch(supabaseApiProvider)),
);

final supabaseOpeningBalanceDatasourceProvider = Provider<SupabaseOpeningBalanceDatasource>(
  (ref) => SupabaseOpeningBalanceDatasource(ref.watch(supabaseApiProvider)),
);

final supabaseNotificationDatasourceProvider = Provider<SupabaseNotificationDatasource>(
  (ref) => SupabaseNotificationDatasource(ref.watch(supabaseApiProvider)),
);

final supabaseUserAdminDatasourceProvider = Provider<SupabaseUserAdminDatasource>(
  (ref) => SupabaseUserAdminDatasource(ref.watch(supabaseApiProvider)),
);

final supabaseFarmDatasourceProvider = Provider<SupabaseFarmDatasource>(
  (ref) => SupabaseFarmDatasource(ref.watch(supabaseApiProvider)),
);

final inventoryDaoProvider = Provider<InventoryDao>((ref) => InventoryDao());
final supabaseInventoryDatasourceProvider =
    Provider<SupabaseInventoryDatasource>(
  (ref) => SupabaseInventoryDatasource(ref.watch(supabaseApiProvider)),
);

// ─────────────── المستودعات ───────────────
/// ═══ CR-4 FIX: AuthRepository يتعامل مع عدم الاتصال ═══
final authRepositoryProvider = Provider<AuthRepository>(
  (ref) {
    final remoteDatasource = ref.watch(supabaseAuthDatasourceProvider);
    return AuthRepositoryImpl(
      remoteDatasource: remoteDatasource,
      sessionDao: ref.watch(sessionDaoProvider),
      settingsDao: ref.watch(settingsDaoProvider),
    );
  },
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

final flockRepositoryProvider = Provider<FlockRepository>(
  (ref) => FlockRepositoryImpl(
    localDao: ref.watch(flockDaoProvider),
    remoteDatasource: ref.watch(supabaseFlockDatasourceProvider),
  ),
);

final paymentRepositoryProvider = Provider<PaymentRepository>(
  (ref) => PaymentRepositoryImpl(
    paymentDao: ref.watch(paymentDaoProvider),
    dispatchDao: ref.watch(dispatchDaoProvider),
    remoteDatasource: ref.watch(supabasePaymentDatasourceProvider),
  ),
);

final userAdminRepositoryProvider = Provider<UserAdminRepository>(
  (ref) => UserAdminRepositoryImpl(
    remoteDatasource: ref.watch(supabaseUserAdminDatasourceProvider),
    userDao: ref.watch(userDaoProvider),
  ),
);

final farmRepositoryProvider = Provider<FarmRepository>(
  (ref) => FarmRepositoryImpl(
    remoteDatasource: ref.watch(supabaseFarmDatasourceProvider),
    settingsDao: ref.watch(settingsDaoProvider),
  ),
);

final inventoryRepositoryProvider = Provider<InventoryRepository>(
  (ref) => InventoryRepositoryImpl(
    localDao: ref.watch(inventoryDaoProvider),
    remoteDatasource: ref.watch(supabaseInventoryDatasourceProvider),
  ),
);

final openingBalanceRepositoryProvider = Provider<OpeningBalanceRepository>(
  (ref) => OpeningBalanceRepositoryImpl(
    localDao: ref.watch(openingBalanceDaoProvider),
    flockDao: ref.watch(flockDaoProvider),
    remoteDatasource: ref.watch(supabaseOpeningBalanceDatasourceProvider),
  ),
);

/// مداجن المستخدم الحالي بأسمائها (مبدّل المدجنة)
/// autoDispose: يُعاد تقييمه مع كل تغيّر في المستخدم/الجلسة حتى لا يبقى
/// محجوباً بقائمة فارغة إذا فُيّم قبل اكتمال تسجيل الدخول.
final currentUserFarmsProvider =
    FutureProvider.autoDispose<List<FarmModel>>((ref) async {
  final uid = ref.watch(authProvider.select((s) => s.currentUser?.uid));
  if (uid == null || uid.isEmpty) return const <FarmModel>[];
  return ref.read(userAdminRepositoryProvider).getCurrentUserFarms();
});

// ─────────────── المزامنة ───────────────
final connectivityServiceProvider = Provider<ConnectivityService>(
  (ref) => ConnectivityServiceImpl(),
);

final syncRepositoryProvider = Provider<SyncRepository>(
  (ref) => SyncRepositoryImpl(
    eggDao: ref.watch(eggProductionDaoProvider),
    mortalityDao: ref.watch(mortalityDaoProvider),
    feedDao: ref.watch(feedDaoProvider),
    dispatchDao: ref.watch(dispatchDaoProvider),
    medicationDao: ref.watch(medicationDaoProvider),
    customerDao: ref.watch(customerDaoProvider),
    paymentDao: ref.watch(paymentDaoProvider),
    expenseDao: null,
    syncQueueDao: ref.watch(syncQueueDaoProvider),
    remoteEgg: ref.watch(supabaseEggDatasourceProvider),
    remoteMortality: ref.watch(supabaseMortalityDatasourceProvider),
    remoteFeed: ref.watch(supabaseFeedDatasourceProvider),
    remoteDispatch: ref.watch(supabaseDispatchDatasourceProvider),
    remoteMedication: ref.watch(supabaseMedicationDatasourceProvider),
    remotePayment: ref.watch(supabasePaymentDatasourceProvider),
  ),
);

final remindersDaoProvider = Provider<RemindersDao>((ref) => RemindersDao());

final notificationRepositoryProvider = Provider<NotificationRepository>(
  (ref) => NotificationRepositoryImpl(
    remoteDatasource: ref.watch(supabaseNotificationDatasourceProvider),
  ),
);
