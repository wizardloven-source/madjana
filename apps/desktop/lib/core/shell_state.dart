import 'package:flutter_riverpod/flutter_riverpod.dart';

/// تبويب الشريط الجانبي النشط في قشرة المدير
final shellTabProvider = StateProvider<int>((_) => 0);

/// عدد طلبات الموافقة المعلقة (للشارة)
final pendingApprovalsProvider = StateProvider<int>((_) => 0);

/// نبضة تُرفع بعد سحب بيانات جديدة من السحابة — الشاشات تستمع لها لتُعيد التحميل
final dataRefreshTickProvider = StateProvider<int>((_) => 0);

/// فهرس التبويب النشط في هيكل المدير
/// (يسمح لأي شاشة بالانتقال لشاشة أخرى برمجياً)
final shellTabProvider = StateProvider<int>((_) => 0);

/// عدد طلبات الموافقة المعلقة (تحدَّث دورياً من شاشة الطلبات)
final pendingApprovalsProvider = StateProvider<int>((_) => 0);
