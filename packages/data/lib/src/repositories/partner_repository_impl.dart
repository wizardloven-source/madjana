import 'package:core/core.dart';
import 'package:data/data.dart';
import 'dart:typed_data';

/// تنفيذ مستودع إدارة الشركاء
class PartnerRepositoryImpl implements PartnerRepository {
  final SupabaseClient _supabase;
  final SessionDao _sessionDao;

  PartnerRepositoryImpl({
    required SupabaseClient supabase,
    required SessionDao sessionDao,
  })  : _supabase = supabase,
        _sessionDao = sessionDao;

  @override
  Future<void> savePartner(PartnerModel partner) async {
    try {
      final data = partner.toJson();
      
      if (partner.id.isEmpty) {
        // إنشاء شريك جديد
        await _supabase.from('partners').insert(data);
      } else {
        // تحديث شريك موجود
        await _supabase
            .from('partners')
            .update(data)
            .eq('id', partner.id);
      }
    } catch (e) {
      print('خطأ في حفظ الشريك: $e');
      rethrow;
    }
  }

  @override
  Future<void> deletePartner(String partnerId) async {
    try {
      // Soft delete - تحديث الحالة فقط
      await _supabase
          .from('partners')
          .update({'status': 'suspended', 'updated_at': DateTime.now().toIso8601String()})
          .eq('id', partnerId);
    } catch (e) {
      print('خطأ في حذف الشريك: $e');
      rethrow;
    }
  }

  @override
  Future<List<PartnerModel>> getAllPartners({
    String? farmId,
    PartnerStatus? status,
  }) async {
    try {
      var query = _supabase.from('partners').select();

      if (status != null) {
        query = query.eq('status', status.name);
      }

      final response = await query;
      
      return (response as List)
          .map((json) => PartnerModel.fromJson(json))
          .toList();
    } catch (e) {
      print('خطأ في جلب الشركاء: $e');
      return [];
    }
  }

  @override
  Future<PartnerModel?> getPartnerById(String partnerId) async {
    try {
      final response = await _supabase
          .from('partners')
          .select()
          .eq('id', partnerId)
          .single();

      return PartnerModel.fromJson(response);
    } catch (e) {
      print('خطأ في جلب الشريك: $e');
      return null;
    }
  }

  @override
  Future<List<PartnerModel>> getPartnersByFarm(String farmId) async {
    try {
      final response = await _supabase.rpc(
        'get_partners_by_farm',
        params: {'farm_id_param': farmId},
      );

      return (response as List)
          .map((json) => PartnerModel.fromJson(json))
          .toList();
    } catch (e) {
      print('خطأ في جلب شركاء المدجنة: $e');
      return [];
    }
  }

  @override
  Future<List<PartnerFarmRelation>> getPartnerFarmRelations(String partnerId) async {
    try {
      final response = await _supabase
          .from('partner_farm_relations')
          .select()
          .eq('partner_id', partnerId);

      return (response as List)
          .map((json) => PartnerFarmRelation.fromJson(json))
          .toList();
    } catch (e) {
      print('خطأ في جلب علاقات الشريك: $e');
      return [];
    }
  }

  @override
  Future<void> addPartnerToFarm(PartnerFarmRelation relation) async {
    try {
      await _supabase.from('partner_farm_relations').insert(relation.toJson());
    } catch (e) {
      print('خطأ في إضافة شريك للمدجنة: $e');
      rethrow;
    }
  }

  @override
  Future<void> updatePartnerFarmRelation(PartnerFarmRelation relation) async {
    try {
      await _supabase
          .from('partner_farm_relations')
          .update(relation.toJson())
          .eq('id', relation.id);
    } catch (e) {
      print('خطأ في تحديث علاقة الشريك: $e');
      rethrow;
    }
  }

  @override
  Future<void> removePartnerFromFarm(String partnerId, String farmId) async {
    try {
      await _supabase
          .from('partner_farm_relations')
          .delete()
          .eq('partner_id', partnerId)
          .eq('farm_id', farmId);
    } catch (e) {
      print('خطأ في إزالة الشريك من المدجنة: $e');
      rethrow;
    }
  }

  @override
  Future<void> addTransaction(PartnerTransaction transaction) async {
    try {
      await _supabase.from('partner_transactions').insert(transaction.toJson());
    } catch (e) {
      print('خطأ في إضافة المعاملة: $e');
      rethrow;
    }
  }

  @override
  Future<List<PartnerTransaction>> getPartnerTransactions(
    String partnerId, {
    DateTime? fromDate,
    DateTime? toDate,
  }) async {
    try {
      var query = _supabase
          .from('partner_transactions')
          .select()
          .eq('partner_id', partnerId)
          .order('date', ascending: false);

      if (fromDate != null) {
        query = query.gte('date', fromDate.toIso8601String());
      }
      if (toDate != null) {
        query = query.lte('date', toDate.toIso8601String());
      }

      final response = await query;

      return (response as List)
          .map((json) => PartnerTransaction.fromJson(json))
          .toList();
    } catch (e) {
      print('خطأ في جلب المعاملات: $e');
      return [];
    }
  }

  @override
  Future<double> getPartnerBalance(String partnerId) async {
    try {
      final transactions = await getPartnerTransactions(partnerId);
      
      double balance = 0.0;
      for (var tx in transactions) {
        balance += (tx.credit ?? 0) - (tx.debit ?? 0);
      }
      
      return balance;
    } catch (e) {
      print('خطأ في حساب الرصيد: $e');
      return 0.0;
    }
  }

  @override
  Future<void> distributeProfit({
    required String partnerId,
    required String farmId,
    required double amount,
    required String description,
    DateTime? date,
  }) async {
    try {
      final transaction = PartnerTransaction(
        id: '',
        partnerId: partnerId,
        farmId: farmId,
        description: description,
        date: date ?? DateTime.now(),
        credit: amount,
        debit: null,
        balance: 0, // سيتم حسابه لاحقاً
        transactionType: 'profit',
        createdAt: DateTime.now(),
      );

      await addTransaction(transaction);
      
      // تحديث إجمالي الأرباح المستلمة
      final partner = await getPartnerById(partnerId);
      if (partner != null) {
        await savePartner(partner.copyWith(
          totalReceivedProfits: partner.totalReceivedProfits + amount,
        ));
      }
    } catch (e) {
      print('خطأ في توزيع الربح: $e');
      rethrow;
    }
  }

  @override
  Future<void> recordWithdrawal({
    required String partnerId,
    required double amount,
    String? description,
    String? paymentMethod,
    String? receiptImageUrl,
    DateTime? date,
  }) async {
    try {
      final transaction = PartnerTransaction(
        id: '',
        partnerId: partnerId,
        description: description ?? 'سحب نقدي',
        date: date ?? DateTime.now(),
        credit: null,
        debit: amount,
        balance: 0,
        paymentMethod: paymentMethod,
        receiptImageUrl: receiptImageUrl,
        transactionType: 'withdrawal',
        createdAt: DateTime.now(),
      );

      await addTransaction(transaction);
    } catch (e) {
      print('خطأ في تسجيل السحب: $e');
      rethrow;
    }
  }

  @override
  Future<void> settleAccount(String partnerId) async {
    try {
      final balance = await getPartnerBalance(partnerId);
      
      if (balance > 0) {
        // تسوية الرصيد الموجب
        await recordWithdrawal(
          partnerId: partnerId,
          amount: balance,
          description: 'تسوية حساب - صرف كامل الرصيد',
          paymentMethod: 'settlement',
        );
      }
    } catch (e) {
      print('خطأ في تسوية الحساب: $e');
      rethrow;
    }
  }

  @override
  Future<void> distributeFarmProfits({
    required String farmId,
    required double totalProfit,
    required String description,
    DateTime? date,
  }) async {
    try {
      final partners = await getPartnersByFarm(farmId);
      
      for (var partner in partners) {
        final relations = await getPartnerFarmRelations(partner.id);
        final farmRelation = relations.firstWhere(
          (r) => r.farmId == farmId,
          orElse: () => throw Exception('شريك غير موجود في هذه المدجنة'),
        );
        
        final partnerShare = totalProfit * (farmRelation.percentage / 100);
        
        await distributeProfit(
          partnerId: partner.id,
          farmId: farmId,
          amount: partnerShare,
          description: '$description - نسبة ${farmRelation.percentage}%',
          date: date,
        );
      }
    } catch (e) {
      print('خطأ في توزيع أرباح المدجنة: $e');
      rethrow;
    }
  }

  @override
  Future<List<PartnerContractAlert>> getContractAlerts({int daysThreshold = 30}) async {
    try {
      final now = DateTime.now();
      final thresholdDate = now.add(Duration(days: daysThreshold));
      
      final partners = await getAllPartners();
      final alerts = <PartnerContractAlert>[];
      
      for (var partner in partners) {
        if (partner.contractEndDate != null) {
          final endDate = partner.contractEndDate!;
          final daysRemaining = endDate.difference(now).inDays;
          
          if (daysRemaining >= 0 && daysRemaining <= daysThreshold) {
            final relations = await getPartnerFarmRelations(partner.id);
            
            for (var relation in relations) {
              alerts.add(PartnerContractAlert(
                partnerId: partner.id,
                partnerName: partner.name,
                farmId: relation.farmId,
                farmName: relation.farmName,
                endDate: endDate,
                daysRemaining: daysRemaining,
              ));
            }
          }
        }
      }
      
      return alerts;
    } catch (e) {
      print('خطأ في جلب تنبيهات العقود: $e');
      return [];
    }
  }

  @override
  Future<String> uploadContractDocument({
    required String partnerId,
    required Uint8List fileBytes,
    required String fileName,
  }) async {
    try {
      final filePath = 'contracts/$partnerId/$fileName';
      
      await _supabase.storage
          .from('partner-documents')
          .uploadBinary(filePath, fileBytes);
      
      final publicUrl = _supabase.storage
          .from('partner-documents')
          .getPublicUrl(filePath);
      
      // تحديث رابط المستند في جدول الشركاء
      final partner = await getPartnerById(partnerId);
      if (partner != null) {
        await savePartner(partner.copyWith(contractDocumentUrl: publicUrl));
      }
      
      return publicUrl;
    } catch (e) {
      print('خطأ في رفع المستند: $e');
      rethrow;
    }
  }

  @override
  Future<void> transferShareToHeirs({
    required String deceasedPartnerId,
    required List<HeirAllocation> heirs,
  }) async {
    try {
      // TODO: تنفيذ نقل الحصة للورثة
      // يتطلب إنشاء سجلات شركاء جديدة للورثة
      print('نقل الحصة للورثة قيد التطوير');
    } catch (e) {
      print('خطأ في نقل الحصة للورثة: $e');
      rethrow;
    }
  }

  @override
  Future<PartnerReport> getPartnerReport({
    required String partnerId,
    DateTime? fromDate,
    DateTime? toDate,
  }) async {
    try {
      final partner = await getPartnerById(partnerId);
      if (partner == null) {
        throw Exception('الشريك غير موجود');
      }

      final farmRelations = await getPartnerFarmRelations(partnerId);
      final transactions = await getPartnerTransactions(
        partnerId,
        fromDate: fromDate,
        toDate: toDate,
      );

      double totalCredits = 0;
      double totalDebits = 0;
      final profitsByFarm = <String, double>{};

      for (var tx in transactions) {
        totalCredits += (tx.credit ?? 0);
        totalDebits += (tx.debit ?? 0);
        
        if (tx.transactionType == 'profit' && tx.farmId != null) {
          profitsByFarm[tx.farmId!] = (profitsByFarm[tx.farmId!] ?? 0) + (tx.credit ?? 0);
        }
      }

      return PartnerReport(
        partner: partner,
        farmRelations: farmRelations,
        transactions: transactions,
        totalCredits: totalCredits,
        totalDebits: totalDebits,
        currentBalance: totalCredits - totalDebits,
        totalProfitsReceived: partner.totalReceivedProfits,
        profitsByFarm: profitsByFarm,
        alerts: await getContractAlerts(),
      );
    } catch (e) {
      print('خطأ في جلب التقرير: $e');
      rethrow;
    }
  }

  @override
  Future<Uint8List> exportPartnersToExcel({String? farmId}) async {
    try {
      // TODO: تنفيذ تصدير Excel باستخدام مكتبة excel
      print('تصدير Excel قيد التطوير');
      return Uint8List(0);
    } catch (e) {
      print('خطأ في تصدير Excel: $e');
      rethrow;
    }
  }

  @override
  Future<List<PartnerModel>> importPartnersFromExcel(Uint8List excelBytes) async {
    try {
      // TODO: تنفيذ استيراد Excel
      print('استيراد Excel قيد التطوير');
      return [];
    } catch (e) {
      print('خطأ في استيراد Excel: $e');
      rethrow;
    }
  }

  @override
  Future<void> logAuditEntry({
    required String partnerId,
    required String action,
    required String userId,
    String? details,
  }) async {
    try {
      await _supabase.from('audit_logs').insert({
        'entity_type': 'partner',
        'entity_id': partnerId,
        'action': action,
        'user_id': userId,
        'details': details,
        'created_at': DateTime.now().toIso8601String(),
      });
    } catch (e) {
      print('خطأ في تسجيل التدقيق: $e');
      // لا نعيد رمي الخطأ هنا حتى لا نعطل العملية الرئيسية
    }
  }
}
