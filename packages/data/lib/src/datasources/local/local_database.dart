import 'dart:io';

import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

/// قاعدة البيانات المحلية - Offline-first
/// 
/// تحتوي على:
/// 1. جداول البيانات التشغيلية (نسخة محلية)
/// 2. طابور المزامنة (sync_queue)
/// 3. جدول الجلسة (session)
class LocalDatabase {
  static Database? _database;
  static const String _dbName = 'poultry_farm.db';
  static const int _dbVersion = 15;

  /// مسار ثابت لم يتغير حسب دليل العمل (يُعيّن على منصة سطح المكتب
  /// في main() ليكون موقعاً موحّداً على مستوى المستخدم)
  static String? _overridePath;

  /// تعيين مسار ثابت لقاعدة البيانات (لمنصات لا تُعتمد فيها
  /// getDatabasesPath على CWD، كـ Windows).
  static void setDatabasePath(String path) {
    _overridePath = path;
  }

  /// الحصول على نسخة قاعدة البيانات
  static Future<Database> get database async {
    _database ??= await _initDatabase();
    return _database!;
  }

  /// مسار ملف قاعدة البيانات (للنسخ الاحتياطي)
  static Future<String> databasePath() async {
    if (_overridePath != null) return _overridePath!;
    final dbPath = await getDatabasesPath();
    return join(dbPath, _dbName);
  }

  /// اسم ملف القاعدة
  static String get dbName => _dbName;

  /// تهيئة قاعدة البيانات
  static Future<Database> _initDatabase() async {
    if (_overridePath != null) {
      final overrideDir = Directory(_overridePath!).parent.path;
      await Directory(overrideDir).create(recursive: true);
      return await openDatabase(
        _overridePath!,
        version: _dbVersion,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      );
    }
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, _dbName);

    return await openDatabase(
      path,
      version: _dbVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  /// إنشاء الجداول
  static Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE egg_production (
        id TEXT PRIMARY KEY,
        farm_id TEXT NOT NULL,
        flock_id TEXT NOT NULL,
        date TEXT NOT NULL,
        cartons INTEGER NOT NULL DEFAULT 0,
        trays INTEGER NOT NULL DEFAULT 0,
        loose_eggs INTEGER NOT NULL DEFAULT 0,
        total_eggs INTEGER NOT NULL DEFAULT 0,
        broken_eggs INTEGER DEFAULT 0,
        dirty_eggs INTEGER DEFAULT 0,
        tray_weight_kg REAL,
        section_no INTEGER,
        worker_id TEXT NOT NULL,
        sync_status TEXT DEFAULT 'pending',
        version INTEGER DEFAULT 1,
        deleted_at TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE mortality (
        id TEXT PRIMARY KEY,
        farm_id TEXT NOT NULL,
        flock_id TEXT NOT NULL,
        date TEXT NOT NULL,
        count INTEGER NOT NULL,
        reason TEXT NOT NULL,
        reason_other TEXT,
        notes TEXT,
        image_url TEXT,
        worker_id TEXT NOT NULL,
        section_no INTEGER,
        sync_status TEXT DEFAULT 'pending',
        version INTEGER DEFAULT 1,
        deleted_at TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE feed_consumption (
        id TEXT PRIMARY KEY,
        farm_id TEXT NOT NULL,
        flock_id TEXT,
        date TEXT NOT NULL,
        entry_mode TEXT NOT NULL,
        bags_count INTEGER DEFAULT 0,
        quantity_kg REAL NOT NULL,
        worker_id TEXT NOT NULL,
        section_no INTEGER,
        sync_status TEXT DEFAULT 'pending',
        version INTEGER DEFAULT 1,
        deleted_at TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE egg_dispatch (
        id TEXT PRIMARY KEY,
        farm_id TEXT NOT NULL,
        date TEXT NOT NULL,
        customer_id TEXT NOT NULL,
        cartons INTEGER NOT NULL DEFAULT 0,
        trays INTEGER NOT NULL DEFAULT 0,
        total_eggs INTEGER NOT NULL DEFAULT 0,
        tray_weight_kg REAL,
        notes TEXT,
        payment_status TEXT DEFAULT 'unpaid',
        worker_id TEXT NOT NULL,
        sync_status TEXT DEFAULT 'pending',
        version INTEGER DEFAULT 1,
        deleted_at TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE feed_received (
        id TEXT PRIMARY KEY,
        farm_id TEXT NOT NULL,
        date TEXT NOT NULL,
        entry_mode TEXT NOT NULL,
        quantity REAL NOT NULL,
        quantity_kg REAL NOT NULL,
        feed_type TEXT NOT NULL,
        supplier TEXT,
        invoice_number TEXT,
        price_per_kg REAL,
        notes TEXT,
        worker_id TEXT NOT NULL,
        section_no INTEGER,
        sync_status TEXT DEFAULT 'pending',
        version INTEGER DEFAULT 1,
        deleted_at TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE medications (
        id TEXT PRIMARY KEY,
        farm_id TEXT NOT NULL,
        flock_id TEXT,
        date TEXT NOT NULL,
        type TEXT NOT NULL,
        medicine_name TEXT NOT NULL,
        dosage TEXT NOT NULL,
        administration_route TEXT NOT NULL,
        treatment_days INTEGER,
        withdrawal_days INTEGER DEFAULT 0,
        notes TEXT,
        worker_id TEXT NOT NULL,
        sync_status TEXT DEFAULT 'pending',
        version INTEGER DEFAULT 1,
        deleted_at TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE customers (
        id TEXT PRIMARY KEY,
        farm_id TEXT NOT NULL,
        name TEXT NOT NULL,
        phone TEXT NOT NULL,
        notes TEXT,
        total_debt REAL DEFAULT 0,
        sync_status TEXT DEFAULT 'synced',
        version INTEGER DEFAULT 1,
        deleted_at TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE medicines_catalog (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        type TEXT NOT NULL,
        withdrawal_days INTEGER DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE flocks (
        id TEXT PRIMARY KEY,
        farm_id TEXT NOT NULL,
        breed TEXT NOT NULL,
        start_date TEXT NOT NULL,
        initial_count INTEGER NOT NULL,
        current_count INTEGER NOT NULL,
        status TEXT DEFAULT 'active',
        sections_count INTEGER DEFAULT 1,
        version INTEGER DEFAULT 1,
        deleted_at TEXT
      )
    ''');

    // كاش المستخدمين (يُملأ من السحابة عند المزامنة) - لشاشة المستخدمين بدون إنترنت
    await db.execute('''
      CREATE TABLE users (
        id TEXT PRIMARY KEY,
        farm_id TEXT NOT NULL,
        name TEXT NOT NULL,
        phone TEXT NOT NULL,
        role TEXT NOT NULL DEFAULT 'worker',
        created_at TEXT NOT NULL
      )
    ''');

    // جدول المدفوعات/القبض (للمدير فقط)
    await db.execute('''
      CREATE TABLE payments (
        id TEXT PRIMARY KEY,
        farm_id TEXT NOT NULL,
        dispatch_id TEXT,
        customer_id TEXT NOT NULL,
        date TEXT NOT NULL,
        price_per_carton REAL NOT NULL DEFAULT 0,
        total_due REAL NOT NULL DEFAULT 0,
        amount_paid REAL NOT NULL DEFAULT 0,
        payment_method TEXT NOT NULL DEFAULT 'cash',
        due_date TEXT,
        notes TEXT,
        manager_id TEXT NOT NULL,
        created_at TEXT NOT NULL,
        sync_status TEXT DEFAULT 'synced',
        version INTEGER DEFAULT 1,
        deleted_at TEXT,
        updated_at TEXT
      )
    ''');

    // جدول المصروفات (للمدير فقط)
    await db.execute('''
      CREATE TABLE expenses (
        id TEXT PRIMARY KEY,
        farm_id TEXT NOT NULL,
        date TEXT NOT NULL,
        category TEXT NOT NULL,
        description TEXT,
        amount REAL NOT NULL DEFAULT 0,
        sync_status TEXT DEFAULT 'synced',
        version INTEGER DEFAULT 1,
        deleted_at TEXT,
        created_at TEXT,
        updated_at TEXT
      )
    ''');

    // جدول عناصر المخزون (للمدير فقط)
    await db.execute('''
      CREATE TABLE inventory_items (
        id TEXT PRIMARY KEY,
        farm_id TEXT NOT NULL,
        name TEXT NOT NULL,
        unit TEXT NOT NULL DEFAULT 'piece',
        quantity REAL NOT NULL DEFAULT 0,
        low_stock_threshold REAL NOT NULL DEFAULT 5,
        notes TEXT,
        updated_at TEXT
      )
    ''');

    // جدول حركات المخزون (للمدير فقط)
    await db.execute('''
      CREATE TABLE inventory_transactions (
        id TEXT PRIMARY KEY,
        item_id TEXT NOT NULL,
        date TEXT NOT NULL,
        type TEXT NOT NULL,
        quantity REAL NOT NULL,
        note TEXT,
        user_id TEXT
      )
    ''');

    // جدول إعدادات التطبيق (مفتاح/قيمة)
    await db.execute('''
      CREATE TABLE app_settings (
        key TEXT PRIMARY KEY,
        value TEXT
      )
    ''');

    // جدول طابور المزامنة
    await db.execute('''
      CREATE TABLE sync_queue (
        id TEXT PRIMARY KEY,
        table_name TEXT NOT NULL,
        record_id TEXT NOT NULL,
        action TEXT NOT NULL,
        payload TEXT NOT NULL,
        user_id TEXT NOT NULL,
        attempts INTEGER DEFAULT 0,
        last_error TEXT,
        status TEXT DEFAULT 'pending',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');

    // جدول الجلسة
    await db.execute('''
      CREATE TABLE session (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        user_id TEXT,
        farm_id TEXT,
        remember_token TEXT,
        last_login TEXT,
        user_json TEXT
      )
    ''');

    // ملاحظات العامل الشخصية (نصية/صوتية - تبقى على الهاتف فقط)
    await db.execute('''
      CREATE TABLE worker_notes (
        id TEXT PRIMARY KEY,
        content TEXT,
        audio_path TEXT,
        created_at TEXT NOT NULL
      )
    ''');

    // تذكيرات العامل الخاصة (تبقى على الهاتف فقط)
    await db.execute('''
      CREATE TABLE worker_reminders (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        body TEXT,
        created_at TEXT NOT NULL
      )
    ''');

    // جدول طلبات التخريج
    await db.execute('''
      CREATE TABLE dispatch_requests (
        id TEXT PRIMARY KEY,
        farm_id TEXT NOT NULL,
        customer_id TEXT NOT NULL,
        requested_cartons INTEGER NOT NULL DEFAULT 0,
        requested_trays INTEGER NOT NULL DEFAULT 0,
        notes TEXT,
        status TEXT DEFAULT 'pending',
        created_at TEXT NOT NULL,
        updated_at TEXT
      )
    ''');

    // جدول الأرصدة الافتتاحية للقطعان القديمة
    await db.execute('''
      CREATE TABLE opening_balances (
        id TEXT PRIMARY KEY,
        farm_id TEXT NOT NULL,
        flock_id TEXT NOT NULL,
        created_at TEXT NOT NULL,
        eggs_produced INTEGER DEFAULT 0,
        eggs_dispatched INTEGER DEFAULT 0,
        feed_consumed_kg REAL DEFAULT 0,
        initial_birds INTEGER DEFAULT 0,
        mortality_count INTEGER DEFAULT 0,
        total_payments REAL DEFAULT 0,
        total_revenues REAL DEFAULT 0,
        sections TEXT
      )
    ''');

    // فهارس للأداء
    await db.execute(
        'CREATE INDEX idx_egg_production_sync ON egg_production(sync_status)');
    await db.execute(
        'CREATE INDEX idx_egg_production_date ON egg_production(date)');
    await db.execute(
        'CREATE INDEX idx_egg_production_farm_date ON egg_production(farm_id, date)');
    await db.execute(
        'CREATE INDEX idx_mortality_sync ON mortality(sync_status)');
    await db.execute(
        'CREATE INDEX idx_mortality_farm_date ON mortality(farm_id, date)');
    await db.execute(
        'CREATE INDEX idx_mortality_flock ON mortality(flock_id)');
    await db.execute(
        'CREATE INDEX idx_feed_consumption_sync ON feed_consumption(sync_status)');
    await db.execute(
        'CREATE INDEX idx_feed_consumption_farm_date ON feed_consumption(farm_id, date)');
    await db.execute(
        'CREATE INDEX idx_feed_received_sync ON feed_received(sync_status)');
    await db.execute(
        'CREATE INDEX idx_feed_received_farm_date ON feed_received(farm_id, date)');
    await db.execute(
        'CREATE INDEX idx_egg_dispatch_sync ON egg_dispatch(sync_status)');
    await db.execute(
        'CREATE INDEX idx_egg_dispatch_farm_date ON egg_dispatch(farm_id, date)');
    await db.execute(
        'CREATE INDEX idx_egg_dispatch_customer ON egg_dispatch(customer_id)');
    await db.execute(
        'CREATE INDEX idx_medications_sync ON medications(sync_status)');
    await db.execute(
        'CREATE INDEX idx_medications_farm_date ON medications(farm_id, date)');
    await db.execute(
        'CREATE INDEX idx_customers_farm ON customers(farm_id)');
    await db.execute(
        'CREATE INDEX idx_payments_farm_date ON payments(farm_id, date)');
    await db.execute(
        'CREATE INDEX idx_payments_customer ON payments(customer_id)');
    await db.execute(
        'CREATE INDEX idx_expenses_farm_date ON expenses(farm_id, date)');
    await db.execute(
        'CREATE INDEX idx_inventory_items_farm ON inventory_items(farm_id)');
    await db.execute(
        'CREATE INDEX idx_inventory_tx_item ON inventory_transactions(item_id)');
    await db.execute(
        'CREATE INDEX idx_sync_queue_status ON sync_queue(status)');
    await db.execute(
        'CREATE INDEX idx_dispatch_requests_farm ON dispatch_requests(farm_id)');
    await db.execute(
        'CREATE INDEX idx_dispatch_requests_status ON dispatch_requests(status)');
  }

  /// ترقية قاعدة البيانات
  static Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    // v2: إضافة جدول المدفوعات
    if (oldVersion < 2) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS payments (
          id TEXT PRIMARY KEY,
          farm_id TEXT NOT NULL,
          dispatch_id TEXT,
          customer_id TEXT NOT NULL,
          date TEXT NOT NULL,
          price_per_carton REAL NOT NULL DEFAULT 0,
          total_due REAL NOT NULL DEFAULT 0,
          amount_paid REAL NOT NULL DEFAULT 0,
          payment_method TEXT NOT NULL DEFAULT 'cash',
          due_date TEXT,
          notes TEXT,
          manager_id TEXT NOT NULL,
          created_at TEXT NOT NULL
        )
      ''');
    }

    // v3: المصروفات والمخزون والإعدادات
    if (oldVersion < 3) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS expenses (
          id TEXT PRIMARY KEY,
          farm_id TEXT NOT NULL,
          date TEXT NOT NULL,
          category TEXT NOT NULL,
          description TEXT,
          amount REAL NOT NULL DEFAULT 0,
          sync_status TEXT DEFAULT 'synced',
          created_at TEXT
        )
      ''');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS inventory_items (
          id TEXT PRIMARY KEY,
          farm_id TEXT NOT NULL,
          name TEXT NOT NULL,
          unit TEXT NOT NULL DEFAULT 'piece',
          quantity REAL NOT NULL DEFAULT 0,
          low_stock_threshold REAL NOT NULL DEFAULT 5,
          notes TEXT,
          updated_at TEXT
        )
      ''');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS inventory_transactions (
          id TEXT PRIMARY KEY,
          item_id TEXT NOT NULL,
          date TEXT NOT NULL,
          type TEXT NOT NULL,
          quantity REAL NOT NULL,
          note TEXT,
          user_id TEXT
        )
      ''');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS app_settings (
          key TEXT PRIMARY KEY,
          value TEXT
        )
      ''');
    }

    // v4: تخزين بيانات المستخدم للجلسة + ملاحظات العامل المحلية
    if (oldVersion < 4) {
      await db.execute('ALTER TABLE session ADD COLUMN user_json TEXT');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS worker_notes (
          id TEXT PRIMARY KEY,
          content TEXT,
          audio_path TEXT,
          created_at TEXT NOT NULL
        )
      ''');
    }

    // v5: تذكيرات العامل الخاصة + رقم العنبر في إنتاج البيض
    if (oldVersion < 5) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS worker_reminders (
          id TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          body TEXT,
          created_at TEXT NOT NULL
        )
      ''');
      // إضافة عمود العنبر بأمان (قد يكون موجوداً في نسخ أقدم)
      try {
        await db.execute('ALTER TABLE egg_production ADD COLUMN section_no INTEGER');
      } catch (_) {}
    }

    // v6: وزن الصحن في التخريج (وزن 30 بيضة بالكيلوغرام)
        if (oldVersion < 6) {
          await db.execute('ALTER TABLE egg_dispatch ADD COLUMN tray_weight_kg REAL');
        }
        // v7: سعر كيلوغرام العلف المستلم (تسعير المدير)
        if (oldVersion < 7) {
          await db
              .execute('ALTER TABLE feed_received ADD COLUMN price_per_kg REAL');
        }
        // v8: أعمدة مفقودة + فهارس إضافية
        if (oldVersion < 8) {
          // إضافة updated_at للجداول التي تفتقر إليه (لحل التعارض في المزامنة)
          for (final table in ['mortality', 'feed_consumption', 'feed_received', 'egg_dispatch', 'medications']) {
            try {
              await db.execute('ALTER TABLE $table ADD COLUMN updated_at TEXT');
            } catch (_) {}
          }
          // إضافة sync_status للجداول التي تفتقر إليه
          for (final table in ['customers', 'payments']) {
            try {
              await db.execute('ALTER TABLE $table ADD COLUMN sync_status TEXT DEFAULT \'synced\'');
            } catch (_) {}
          }
          // فهارس إضافية
          for (final idx in [
            'CREATE INDEX IF NOT EXISTS idx_egg_production_farm_date ON egg_production(farm_id, date)',
            'CREATE INDEX IF NOT EXISTS idx_mortality_farm_date ON mortality(farm_id, date)',
            'CREATE INDEX IF NOT EXISTS idx_mortality_flock ON mortality(flock_id)',
            'CREATE INDEX IF NOT EXISTS idx_feed_consumption_farm_date ON feed_consumption(farm_id, date)',
            'CREATE INDEX IF NOT EXISTS idx_feed_received_sync ON feed_received(sync_status)',
            'CREATE INDEX IF NOT EXISTS idx_feed_received_farm_date ON feed_received(farm_id, date)',
            'CREATE INDEX IF NOT EXISTS idx_egg_dispatch_sync ON egg_dispatch(sync_status)',
            'CREATE INDEX IF NOT EXISTS idx_egg_dispatch_farm_date ON egg_dispatch(farm_id, date)',
            'CREATE INDEX IF NOT EXISTS idx_egg_dispatch_customer ON egg_dispatch(customer_id)',
            'CREATE INDEX IF NOT EXISTS idx_medications_sync ON medications(sync_status)',
            'CREATE INDEX IF NOT EXISTS idx_medications_farm_date ON medications(farm_id, date)',
            'CREATE INDEX IF NOT EXISTS idx_customers_farm ON customers(farm_id)',
            'CREATE INDEX IF NOT EXISTS idx_payments_farm_date ON payments(farm_id, date)',
            'CREATE INDEX IF NOT EXISTS idx_payments_customer ON payments(customer_id)',
            'CREATE INDEX IF NOT EXISTS idx_expenses_farm_date ON expenses(farm_id, date)',
            'CREATE INDEX IF NOT EXISTS idx_inventory_items_farm ON inventory_items(farm_id)',
            'CREATE INDEX IF NOT EXISTS idx_inventory_tx_item ON inventory_transactions(item_id)',
            'CREATE INDEX IF NOT EXISTS idx_sync_queue_status ON sync_queue(status)',
          ]) {
            try {
              await db.execute(idx);
            } catch (_) {}
          }
        }
        // v9: جدول طلبات التخريج
        if (oldVersion < 9) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS dispatch_requests (
              id TEXT PRIMARY KEY,
              farm_id TEXT NOT NULL,
              customer_id TEXT NOT NULL,
              requested_cartons INTEGER NOT NULL DEFAULT 0,
              requested_trays INTEGER NOT NULL DEFAULT 0,
              notes TEXT,
              status TEXT DEFAULT 'pending',
              created_at TEXT NOT NULL,
              updated_at TEXT
            )
          ''');
          try {
            await db.execute('CREATE INDEX IF NOT EXISTS idx_dispatch_requests_farm ON dispatch_requests(farm_id)');
          } catch (_) {}
          try {
            await db.execute('CREATE INDEX IF NOT EXISTS idx_dispatch_requests_status ON dispatch_requests(status)');
          } catch (_) {}
        }
        // v10: أعمدة مفقودة في _onCreate
        if (oldVersion < 10) {
          try {
            await db.execute('ALTER TABLE expenses ADD COLUMN updated_at TEXT');
          } catch (_) {}
          try {
            await db.execute('ALTER TABLE flocks ADD COLUMN sections_count INTEGER DEFAULT 1');
          } catch (_) {}
        }
        // v11: الأرصدة الافتتاحية للقطعان القديمة
        if (oldVersion < 11) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS opening_balances (
              id TEXT PRIMARY KEY,
              farm_id TEXT NOT NULL,
              flock_id TEXT NOT NULL,
              created_at TEXT NOT NULL,
              eggs_produced INTEGER DEFAULT 0,
              eggs_dispatched INTEGER DEFAULT 0,
              feed_consumed_kg REAL DEFAULT 0,
              initial_birds INTEGER DEFAULT 0,
              mortality_count INTEGER DEFAULT 0,
              total_payments REAL DEFAULT 0,
              total_revenues REAL DEFAULT 0,
              sections TEXT
            )
          ''');
        }
        // v12: كاش المستخدمين + أعمدة المزامنة للزبائن
        if (oldVersion < 12) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS users (
              id TEXT PRIMARY KEY,
              farm_id TEXT NOT NULL,
              name TEXT NOT NULL,
              phone TEXT NOT NULL,
              role TEXT NOT NULL DEFAULT 'worker',
              created_at TEXT NOT NULL
            )
          ''');
          try {
            await db.execute(
                'ALTER TABLE customers ADD COLUMN sync_status TEXT DEFAULT \'synced\'');
          } catch (_) {}
          try {
            await db.execute('ALTER TABLE customers ADD COLUMN updated_at TEXT');
          } catch (_) {}
        }
        // v13: أعمدة المزامنة المفقودة في جدول المدفوعات
        // (كانت مفقودة في _onCreate مما كسر getPendingRecords – أصلحناها)
        if (oldVersion < 13) {
          try {
            await db.execute(
                'ALTER TABLE payments ADD COLUMN sync_status TEXT DEFAULT \'synced\'');
          } catch (_) {}
          try {
            await db.execute('ALTER TABLE payments ADD COLUMN updated_at TEXT');
          } catch (_) {}
        }
        // v14: version + deleted_at للجداول التشغيلية (version-based conflict detection)
        if (oldVersion < 14) {
          final tables = [
            'egg_production', 'mortality', 'feed_consumption',
            'feed_received', 'egg_dispatch', 'medications',
            'customers', 'flocks', 'expenses', 'payments',
          ];
          for (final table in tables) {
            try {
              await db.execute('ALTER TABLE $table ADD COLUMN version INTEGER DEFAULT 1');
            } catch (_) {}
            try {
              await db.execute('ALTER TABLE $table ADD COLUMN deleted_at TEXT');
            } catch (_) {}
          }
          // section_no for mortality/feed_consumption/feed_received
          try {
            await db.execute('ALTER TABLE mortality ADD COLUMN section_no INTEGER');
          } catch (_) {}
          try {
            await db.execute('ALTER TABLE feed_consumption ADD COLUMN section_no INTEGER');
          } catch (_) {}
          try {
            await db.execute('ALTER TABLE feed_received ADD COLUMN section_no INTEGER');
          } catch (_) {}
        }
        // v15: flock_id for feed_consumption + medications
        if (oldVersion < 15) {
          try {
            await db.execute('ALTER TABLE feed_consumption ADD COLUMN flock_id TEXT');
          } catch (_) {}
          try {
            await db.execute('ALTER TABLE medications ADD COLUMN flock_id TEXT');
          } catch (_) {}
        }
  }

  /// مسح قاعدة البيانات (عند تسجيل الخروج)
  static Future<void> clearAll() async {
    final db = await database;
    final tables = [
      'egg_production',
      'mortality',
      'feed_consumption',
      'egg_dispatch',
      'feed_received',
      'medications',
      'customers',
      'medicines_catalog',
      'flocks',
      'users',
      'payments',
      'expenses',
      'inventory_items',
      'inventory_transactions',
      'app_settings',
      'sync_queue',
      'session',
      'worker_notes',
      'worker_reminders',
      'dispatch_requests',
      'opening_balances',
    ];
    for (final table in tables) {
      await db.delete(table);
    }
  }

  /// إغلاق قاعدة البيانات
  static Future<void> close() async {
    await _database?.close();
    _database = null;
  }
}