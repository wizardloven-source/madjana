import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../core/constants/app_routes.dart';

// TODO: استبدل الشاشات المؤقتة بالشاشات الحقيقية عند إنشائها
final GoRouter router = GoRouter(
  initialLocation: AppRoutes.dashboard,
  routes: [
    GoRoute(
      path: AppRoutes.dashboard,
      name: 'dashboard',
      builder: (context, state) => Scaffold(
        appBar: AppBar(title: const Text('لوحة التحكم')),
        body: const Center(child: Text('لوحة التحكم - قريباً')),
      ),
    ),
    GoRoute(
      path: AppRoutes.inventory,
      name: 'inventory',
      builder: (context, state) => Scaffold(
        appBar: AppBar(title: const Text('إدارة المخزون')),
        body: const Center(child: Text('إدارة المخزون - قريباً')),
      ),
    ),
    GoRoute(
      path: AppRoutes.health,
      name: 'health',
      builder: (context, state) => Scaffold(
        appBar: AppBar(title: const Text('السجل الصحي')),
        body: const Center(child: Text('السجل الصحي - قريباً')),
      ),
    ),
    GoRoute(
      path: AppRoutes.reports,
      name: 'reports',
      builder: (context, state) => Scaffold(
        appBar: AppBar(title: const Text('التقارير')),
        body: const Center(child: Text('التقارير - قريباً')),
      ),
    ),
    GoRoute(
      path: AppRoutes.shifts,
      name: 'shifts',
      builder: (context, state) => Scaffold(
        appBar: AppBar(title: const Text('الورديات')),
        body: const Center(child: Text('الورديات - قريباً')),
      ),
    ),
    GoRoute(
      path: AppRoutes.notifications,
      name: 'notifications',
      builder: (context, state) => Scaffold(
        appBar: AppBar(title: const Text('الإشعارات')),
        body: const Center(child: Text('الإشعارات - قريباً')),
      ),
    ),
    GoRoute(
      path: AppRoutes.maintenance,
      name: 'maintenance',
      builder: (context, state) => Scaffold(
        appBar: AppBar(title: const Text('الصيانة والإعدادات')),
        body: const Center(child: Text('الصيانة والإعدادات - قريباً')),
      ),
    ),
    GoRoute(
      path: AppRoutes.syncMonitor,
      name: 'sync-monitor',
      builder: (context, state) => Scaffold(
        appBar: AppBar(title: const Text('حالة المزامنة')),
        body: const Center(child: Text('حالة المزامنة - قريباً')),
      ),
    ),
  ],
);
