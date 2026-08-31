import 'dart:math';
import 'package:core/core.dart';
import 'package:data/data.dart';

/// محرك المزامنة المحسن
/// يعمل مع الهيكل الجديد لـ sync_changes (operation بدلاً من action)
class SyncEngine {
  final EggProductionRepository _eggRepo;
  final MortalityRepository _mortalityRepo;
  final FeedConsumptionRepository _feedRepo;
  final FeedReceivedRepository _feedReceivedRepo;
  final EggDispatchRepository _dispatchRepo;
  final MedicationRepository _medicationRepo;
  final ExpenseRepository _expenseRepo;
  final CustomerRepository _customerRepo;
  final PaymentRepository _paymentRepo;
  final FlockRepository _flockRepo;
  final SyncRepository _syncRepo;
  final String _farmId;
  final String _userId;

  SyncEngine({
    required EggProductionRepository eggRepo,
    required MortalityRepository mortalityRepo,
    required FeedConsumptionRepository feedRepo,
    required FeedReceivedRepository feedReceivedRepo,
    required EggDispatchRepository dispatchRepo,
    required MedicationRepository medicationRepo,
    required ExpenseRepository expenseRepo,
    required CustomerRepository customerRepo,
    required PaymentRepository paymentRepo,
    required FlockRepository flockRepo,
    required SyncRepository syncRepo,
    required String farmId,
    required String userId,
  })  : _eggRepo = eggRepo,
        _mortalityRepo = mortalityRepo,
        _feedRepo = feedRepo,
        _feedReceivedRepo = feedReceivedRepo,
        _dispatchRepo = dispatchRepo,
        _medicationRepo = medicationRepo,
        _expenseRepo = expenseRepo,
        _customerRepo = customerRepo,
        _paymentRepo = paymentRepo,
        _flockRepo = flockRepo,
        _syncRepo = syncRepo,
        _farmId = farmId,
        _userId = userId;

  /// مزامنة جميع السجلات المعلقة مع آلية إعادة المحاولة
  Future<void> syncAllPending() async {
    try {
      // جلب السجلات المعلقة
      final pendingRecords = await _syncRepo.getPendingChanges();

      if (pendingRecords.isEmpty) {
        return;
      }

      // تجميع السجلات حسب الجدول
      final groupedRecords = <String, List<SyncChangeModel>>{};
      for (var record in pendingRecords) {
        groupedRecords.putIfAbsent(record.tableName, () => []).add(record);
      }

      // مزامنة كل جدول على حدة
      for (var entry in groupedRecords.entries) {
        await _syncTableWithRetry(entry.key, entry.value);
      }
    } catch (e) {
      // تسجيل الخطأ وإعادة الجدولة
      print('فشل في مزامنة السجلات: $e');
      rethrow;
    }
  }

  /// مزامنة جدول معين مع إعادة المحاولة
  Future<void> _syncTableWithRetry(String tableName, List<SyncChangeModel> records, {int maxRetries = 3}) async {
    int attempts = 0;
    bool success = false;

    while (attempts < maxRetries && !success) {
      try {
        await _syncTable(tableName, records);
        success = true;
        
        // تحديث الحالة إلى synced
        final ids = records.map((r) => r.recordId).toList();
        await _syncRepo.markAsSynced(ids);
      } catch (e) {
        attempts++;
        print('محاولة $attempts فشلت للجدول $tableName: $e');
        
        if (attempts >= maxRetries) {
          // فشل نهائي، تحديث الحالة إلى failed
          for (var r in records) {
            await _syncRepo.markAsFailed(r.recordId, e.toString());
          }
          rethrow;
        }
        
        // انتظار متزايد (Exponential Backoff)
        await Future.delayed(Duration(seconds: pow(2, attempts).toInt()));
      }
    }
  }

  /// مزامنة بيانات جدول محدد
  Future<void> _syncTable(String tableName, List<SyncChangeModel> records) async {
    switch (tableName) {
      case 'egg_production':
        await _syncEggProduction(records);
        break;
      case 'mortality':
        await _syncMortality(records);
        break;
      case 'feed_consumption':
        await _syncFeedConsumption(records);
        break;
      case 'feed_received':
        await _syncFeedReceived(records);
        break;
      case 'egg_dispatch':
        await _syncEggDispatch(records);
        break;
      case 'medications':
        await _syncMedications(records);
        break;
      case 'expenses':
        await _syncExpenses(records);
        break;
      case 'customers':
        await _syncCustomers(records);
        break;
      case 'payments':
        await _syncPayments(records);
        break;
      case 'flocks':
        await _syncFlocks(records);
        break;
      default:
        print('جدول غير معروف: $tableName');
    }
  }

  Future<void> _syncEggProduction(List<SyncChangeModel> records) async {
    for (var record in records) {
      final payload = EggProductionModel.fromJson(record.payload!);
      
      switch (record.operation) {
        case SyncOperation.insert:
          await _eggRepo.saveRemote(payload);
          break;
        case SyncOperation.update:
          await _eggRepo.updateRemote(payload);
          break;
        case SyncOperation.delete:
          await _eggRepo.deleteRemote(payload.id!);
          break;
      }
    }
  }

  Future<void> _syncMortality(List<SyncChangeModel> records) async {
    for (var record in records) {
      final payload = MortalityModel.fromJson(record.payload!);
      
      switch (record.operation) {
        case SyncOperation.insert:
          await _mortalityRepo.saveRemote(payload);
          break;
        case SyncOperation.update:
          await _mortalityRepo.updateRemote(payload);
          break;
        case SyncOperation.delete:
          await _mortalityRepo.deleteRemote(payload.id!);
          break;
      }
    }
  }

  Future<void> _syncFeedConsumption(List<SyncChangeModel> records) async {
    for (var record in records) {
      final payload = FeedConsumptionModel.fromJson(record.payload!);
      
      switch (record.operation) {
        case SyncOperation.insert:
          await _feedRepo.saveRemote(payload);
          break;
        case SyncOperation.update:
          await _feedRepo.updateRemote(payload);
          break;
        case SyncOperation.delete:
          await _feedRepo.deleteRemote(payload.id!);
          break;
      }
    }
  }

  Future<void> _syncFeedReceived(List<SyncChangeModel> records) async {
    for (var record in records) {
      final payload = FeedReceivedModel.fromJson(record.payload!);
      
      switch (record.operation) {
        case SyncOperation.insert:
          await _feedReceivedRepo.saveRemote(payload);
          break;
        case SyncOperation.update:
          await _feedReceivedRepo.updateRemote(payload);
          break;
        case SyncOperation.delete:
          await _feedReceivedRepo.deleteRemote(payload.id!);
          break;
      }
    }
  }

  Future<void> _syncEggDispatch(List<SyncChangeModel> records) async {
    for (var record in records) {
      final payload = DispatchModel.fromJson(record.payload!);
      
      switch (record.operation) {
        case SyncOperation.insert:
          await _dispatchRepo.saveRemote(payload);
          break;
        case SyncOperation.update:
          await _dispatchRepo.updateRemote(payload);
          break;
        case SyncOperation.delete:
          await _dispatchRepo.deleteRemote(payload.id!);
          break;
      }
    }
  }

  Future<void> _syncMedications(List<SyncChangeModel> records) async {
    for (var record in records) {
      final payload = MedicationModel.fromJson(record.payload!);
      
      switch (record.operation) {
        case SyncOperation.insert:
          await _medicationRepo.saveRemote(payload);
          break;
        case SyncOperation.update:
          await _medicationRepo.updateRemote(payload);
          break;
        case SyncOperation.delete:
          await _medicationRepo.deleteRemote(payload.id!);
          break;
      }
    }
  }

  Future<void> _syncExpenses(List<SyncChangeModel> records) async {
    for (var record in records) {
      final payload = ExpenseModel.fromJson(record.payload!);
      
      switch (record.operation) {
        case SyncOperation.insert:
          await _expenseRepo.saveRemote(payload);
          break;
        case SyncOperation.update:
          await _expenseRepo.updateRemote(payload);
          break;
        case SyncOperation.delete:
          await _expenseRepo.deleteRemote(payload.id!);
          break;
      }
    }
  }

  Future<void> _syncCustomers(List<SyncChangeModel> records) async {
    for (var record in records) {
      final payload = CustomerModel.fromJson(record.payload!);
      
      switch (record.operation) {
        case SyncOperation.insert:
          await _customerRepo.saveRemote(payload);
          break;
        case SyncOperation.update:
          await _customerRepo.updateRemote(payload);
          break;
        case SyncOperation.delete:
          await _customerRepo.deleteRemote(payload.id!);
          break;
      }
    }
  }

  Future<void> _syncPayments(List<SyncChangeModel> records) async {
    for (var record in records) {
      final payload = PaymentModel.fromJson(record.payload!);
      
      switch (record.operation) {
        case SyncOperation.insert:
          await _paymentRepo.saveRemote(payload);
          break;
        case SyncOperation.update:
          await _paymentRepo.updateRemote(payload);
          break;
        case SyncOperation.delete:
          await _paymentRepo.deleteRemote(payload.id!);
          break;
      }
    }
  }

  Future<void> _syncFlocks(List<SyncChangeModel> records) async {
    for (var record in records) {
      final payload = FlockModel.fromJson(record.payload!);
      
      switch (record.operation) {
        case SyncOperation.insert:
          await _flockRepo.saveRemote(payload);
          break;
        case SyncOperation.update:
          await _flockRepo.updateRemote(payload);
          break;
        case SyncOperation.delete:
          await _flockRepo.deleteRemote(payload.id!);
          break;
      }
    }
  }
}
