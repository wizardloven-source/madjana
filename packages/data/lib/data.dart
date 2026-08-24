// حزمة البيانات - طبقة الوصول للمصادر
//
// المصادر المحلية (SQLite)
export 'src/datasources/local/local_database.dart';
export 'src/datasources/local/daos/egg_production_dao.dart';
export 'src/datasources/local/daos/mortality_dao.dart';
export 'src/datasources/local/daos/feed_dao.dart';
export 'src/datasources/local/daos/dispatch_dao.dart';
export 'src/datasources/local/daos/customer_dao.dart';
export 'src/datasources/local/daos/medication_dao.dart';
export 'src/datasources/local/daos/payment_dao.dart';
export 'src/datasources/local/daos/flock_dao.dart';
export 'src/datasources/local/daos/session_dao.dart';
export 'src/datasources/local/daos/sync_queue_dao.dart';
export 'src/datasources/local/daos/settings_dao.dart';
export 'src/datasources/local/daos/expense_dao.dart';
export 'src/datasources/local/daos/inventory_dao.dart';
export 'src/datasources/local/daos/notes_dao.dart';
export 'src/datasources/local/daos/reminders_dao.dart';

// المصادر السحابية (Supabase)
export 'src/datasources/remote/supabase_auth_datasource.dart';
export 'src/datasources/remote/supabase_egg_datasource.dart';
export 'src/datasources/remote/supabase_mortality_datasource.dart';
export 'src/datasources/remote/supabase_feed_datasource.dart';
export 'src/datasources/remote/supabase_dispatch_datasource.dart';
export 'src/datasources/remote/supabase_medication_datasource.dart';
export 'src/datasources/remote/supabase_storage_service.dart';
export 'src/datasources/remote/supabase_flock_datasource.dart';
export 'src/datasources/remote/supabase_user_admin_datasource.dart';
export 'src/datasources/remote/supabase_expense_datasource.dart';
export 'src/datasources/remote/supabase_inventory_datasource.dart';
export 'src/datasources/remote/supabase_farm_datasource.dart';

// المستودعات
export 'src/repositories/auth_repository_impl.dart';
export 'src/repositories/egg_production_repository_impl.dart';
export 'src/repositories/mortality_repository_impl.dart';
export 'src/repositories/feed_repository_impl.dart';
export 'src/repositories/dispatch_repository_impl.dart';
export 'src/repositories/medication_repository_impl.dart';
export 'src/repositories/payment_repository_impl.dart';
export 'src/repositories/flock_repository_impl.dart';
export 'src/repositories/user_admin_repository_impl.dart';
export 'src/repositories/sync_repository_impl.dart';
export 'src/repositories/expense_repository_impl.dart';
export 'src/repositories/inventory_repository_impl.dart';
export 'src/repositories/farm_repository_impl.dart';
