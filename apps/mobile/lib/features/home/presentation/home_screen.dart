import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import 'dart:math' as math;
import '../../auth/providers/auth_provider.dart';
import '../../notifications/providers/notifications_provider.dart';
import '../../sync/providers/sync_provider.dart';

/// الشاشة الرئيسية - تصميم حديث ومتطور
/// - ترويسة متدرجة مع إحصائيات سريعة
/// - بطاقات عمليات بتأثيرات ظل وانيميشن
/// - شريط مزامنة ذكي
/// - إشعارات دائمة بتصميم عصري
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;
  late Animation<double> _slideAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeOut),
    );
    _slideAnimation = Tween<double>(begin: 20.0, end: 0.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeOut),
    );
    _animationController.forward();
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authProvider).currentUser;
    final syncState = ref.watch(syncProvider);
    final theme = Theme.of(context);

    if (user == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    // تفعيل السحب من السحابة بمجرد توفر المزرعة
    final farmId = user.farmId;
    if (farmId != null && farmId.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(syncProvider.notifier).setFarmId(farmId);
      });
    }

    final isManager = user.role == UserRole.manager;
    final pendingCount = syncState.pendingCount;

    // عدد الإشعارات الدائمة النشطة (لشارة الجرس)
    final persistentNotices =
        ref.watch(activeNoticesProvider(user.farmId ?? '')).value ??
            const <AppNotificationModel>[];
    final persistentCount =
        persistentNotices.where((n) => n.isPersistent).length;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          // ترويسة متدرجة حديثة
          SliverAppBar(
            expandedHeight: 180,
            floating: false,
            pinned: true,
            elevation: 0,
            scrolledUnderElevation: 2,
            backgroundColor: theme.colorScheme.primaryContainer,
            flexibleSpace: FlexibleSpaceBar(
              background: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      theme.colorScheme.primary,
                      theme.colorScheme.primaryContainer,
                      theme.colorScheme.surface,
                    ],
                  ),
                ),
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 60, 16, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            // ترحيب مع صورة رمزية
                            Row(
                              children: [
                                Container(
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    gradient: LinearGradient(
                                      colors: [
                                        theme.colorScheme.primary,
                                        theme.colorScheme.secondary,
                                      ],
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                        color: theme.colorScheme.primary.withValues(alpha: 0.3),
                                        blurRadius: 8,
                                        offset: const Offset(0, 2),
                                      ),
                                    ],
                                  ),
                                  child: CircleAvatar(
                                    radius: 28,
                                    backgroundColor: Colors.transparent,
                                    child: Icon(
                                      isManager ? Icons.admin_panel_settings : Icons.person,
                                      size: 30,
                                      color: theme.colorScheme.onPrimary,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'أهلاً، ${user.name}',
                                      style: theme.textTheme.titleLarge?.copyWith(
                                        fontWeight: FontWeight.bold,
                                        color: theme.colorScheme.onPrimaryContainer,
                                      ),
                                    ),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: theme.colorScheme.primary.withValues(alpha: 0.2),
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: Text(
                                        user.role.label,
                                        style: theme.textTheme.bodySmall?.copyWith(
                                          color: theme.colorScheme.onPrimaryContainer,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                            // زر الخروج
                            Container(
                              decoration: BoxDecoration(
                                color: theme.colorScheme.errorContainer,
                                shape: BoxShape.circle,
                              ),
                              child: IconButton(
                                tooltip: 'تسجيل الخروج',
                                icon: Icon(Icons.logout, size: 22, color: theme.colorScheme.onErrorContainer),
                                onPressed: () => _confirmLogout(context, ref),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            actions: [
              // جرس الإشعارات مع شارة متحركة
              _NotificationBell(count: persistentCount),
              // زر المزامنة مع مؤشر
              _SyncButton(isSyncing: syncState.isSyncing, pendingCount: pendingCount),
              const SizedBox(width: 8),
            ],
          ),

          // المحتوى الرئيسي
          SliverToBoxAdapter(
            child: FadeTransition(
              opacity: _fadeAnimation,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.1),
                  end: Offset.zero,
                ).animate(_slideAnimation),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // إشعارات المدير الدائمة النشطة
                      if (persistentCount > 0) ...[
                        _PersistentNotices(farmId: user.farmId ?? ''),
                        const SizedBox(height: 16),
                      ],

                      // شريط حالة المزامنة الذكي
                      _SmartSyncBanner(pendingCount: pendingCount, isSyncing: syncState.isSyncing),
                      const SizedBox(height: 24),

                      // قسم العمليات السريع
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'العمليات السريعة',
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primaryContainer,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              '${isManager ? 10 : 8} أدوات',
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),

                      // شبكة العمليات الحديثة
                      ..._buildOperationGrid(context, isManager),
                      
                      const SizedBox(height: 80),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildOperationGrid(BuildContext context, bool isManager) {
    final operations = [
      _OperationData(icon: Icons.egg, label: 'إدخال البيض', color: Colors.green, route: '/egg-production'),
      _OperationData(icon: Icons.pets, label: 'إدخال النفوق', color: Colors.red, route: '/mortality'),
      _OperationData(icon: Icons.grain, label: 'استهلاك العلف', color: Colors.orange, route: '/feed-consumption'),
      _OperationData(icon: Icons.local_shipping, label: 'تخريج البيض', color: Colors.blue, route: '/dispatch'),
      _OperationData(icon: Icons.medical_services, label: 'الأدوية', color: Colors.purple, route: '/medications'),
      _OperationData(icon: Icons.inventory_2, label: 'استلام علف', color: Colors.brown, route: '/feed-received'),
      _OperationData(icon: Icons.sticky_note_2, label: 'ملاحظاتي', color: Colors.blueGrey, route: '/notes'),
      _OperationData(icon: Icons.settings, label: 'الإعدادات', color: Colors.teal, route: '/settings'),
      if (isManager) _OperationData(icon: Icons.payments, label: 'قبض المبالغ', color: Colors.indigo, route: '/payments'),
      if (isManager) _OperationData(icon: Icons.assessment, label: 'التقارير', color: Colors.deepOrange, route: '/reports'),
    ];

    return [
      GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 14,
          crossAxisSpacing: 14,
          childAspectRatio: 1.5,
        ),
        itemCount: operations.length,
        itemBuilder: (context, index) => _ModernOperationCard(
          operation: operations[index],
          delay: index * 50,
        ),
      ),
    ];
  }

  Future<void> _confirmLogout(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.errorContainer,
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.logout, size: 40, color: Theme.of(context).colorScheme.onErrorContainer),
              ),
              const SizedBox(height: 20),
              Text(
                'تسجيل الخروج',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                'هل تريد تسجيل الخروج من التطبيق؟',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Text('إلغاء'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Text('خروج'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (confirmed == true && context.mounted) {
      await ref.read(authProvider.notifier).logout();
      if (context.mounted) {
        Navigator.of(context).pushNamedAndRemoveUntil('/login', (_) => false);
      }
    }
  }
}

// بيانات العملية
class _OperationData {
  final IconData icon;
  final String label;
  final Color color;
  final String route;

  _OperationData({
    required this.icon,
    required this.label,
    required this.color,
    required this.route,
  });
}

// جرس الإشعارات مع شارة متحركة
class _NotificationBell extends StatelessWidget {
  final int count;

  const _NotificationBell({required this.count});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          margin: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.1),
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: IconButton(
            tooltip: 'الإشعارات',
            icon: Icon(Icons.notifications_outlined, color: theme.colorScheme.onSurface),
            onPressed: () => Navigator.pushNamed(context, '/notifications'),
          ),
        ),
        if (count > 0)
          Positioned(
            right: 4,
            top: 4,
            child: TweenAnimationBuilder(
              duration: const Duration(milliseconds: 300),
              tween: Tween<double>(begin: 0.0, end: 1.0),
              builder: (context, value, child) {
                return Transform.scale(
                  scale: value,
                  child: child,
                );
              },
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [theme.colorScheme.error, Colors.red.shade700],
                  ),
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: theme.colorScheme.error.withValues(alpha: 0.4),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
                child: Text(
                  '$count',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// زر المزامنة مع مؤشر - يستخدم ConsumerStatefulWidget للوصول إلى ref
class _SyncButton extends ConsumerWidget {
  final bool isSyncing;
  final int pendingCount;

  const _SyncButton({required this.isSyncing, required this.pendingCount});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          margin: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.1),
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: IconButton(
            icon: isSyncing
                ? SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: theme.colorScheme.primary,
                    ),
                  )
                : Icon(Icons.sync, color: theme.colorScheme.onSurface),
            onPressed: isSyncing ? null : () => ref.read(syncProvider.notifier).syncNow(),
          ),
        ),
        if (pendingCount > 0 && !isSyncing)
          Positioned(
            right: 4,
            top: 4,
            child: TweenAnimationBuilder(
              duration: const Duration(milliseconds: 300),
              tween: Tween<double>(begin: 0.0, end: 1.0),
              builder: (context, value, child) {
                return Transform.scale(
                  scale: value,
                  child: child,
                );
              },
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [theme.colorScheme.error, Colors.red.shade700],
                  ),
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: theme.colorScheme.error.withValues(alpha: 0.4),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
                child: Text(
                  '$pendingCount',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// بطاقة عملية حديثة مع انيميشن
class _ModernOperationCard extends StatefulWidget {
  final _OperationData operation;
  final int delay;

  const _ModernOperationCard({
    required this.operation,
    required this.delay,
  });

  @override
  State<_ModernOperationCard> createState() => _ModernOperationCardState();
}

class _ModernOperationCardState extends State<_ModernOperationCard> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;
  bool _isHovered = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _scaleAnimation = Tween<double>(begin: 0.8, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.elasticOut),
    );
    
    // تأخير الانيميشن حسب الترتيب
    Future.delayed(Duration(milliseconds: widget.delay), () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    return ScaleTransition(
      scale: _scaleAnimation,
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          transform: Matrix4.identity()..scale(_isHovered ? 1.03 : 1.0),
          child: Material(
            elevation: _isHovered ? 8 : 2,
            shadowColor: widget.operation.color.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(18),
            child: InkWell(
              onTap: widget.operation.route.isNotEmpty 
                  ? () => Navigator.pushNamed(context, widget.operation.route)
                  : null,
              borderRadius: BorderRadius.circular(18),
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      widget.operation.color.withValues(alpha: 0.15),
                      widget.operation.color.withValues(alpha: 0.05),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: widget.operation.color.withValues(alpha: _isHovered ? 0.4 : 0.2),
                    width: _isHovered ? 2 : 1,
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: widget.operation.color.withValues(alpha: 0.25),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Icon(
                          widget.operation.icon,
                          size: 26,
                          color: widget.operation.color,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Expanded(
                        child: Text(
                          widget.operation.label,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                          ),
                        ),
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Icon(
                            Icons.arrow_left_rounded,
                            size: 20,
                            color: widget.operation.color,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// شريط حالة المزامنة الذكي - يستخدم ConsumerWidget للوصول إلى ref
class _SmartSyncBanner extends ConsumerWidget {
  final int pendingCount;
  final bool isSyncing;

  const _SmartSyncBanner({required this.pendingCount, required this.isSyncing});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    
    if (isSyncing) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              theme.colorScheme.primaryContainer,
              theme.colorScheme.primaryContainer.withValues(alpha: 0.7),
            ],
          ),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: theme.colorScheme.primary.withValues(alpha: 0.3),
          ),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'جاري المزامنة...',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      );
    }

    if (pendingCount > 0) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: theme.colorScheme.tertiaryContainer.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: theme.colorScheme.tertiary.withValues(alpha: 0.3),
          ),
        ),
        child: Row(
          children: [
            Icon(Icons.cloud_upload_outlined,
                size: 20, color: theme.colorScheme.tertiary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$pendingCount سجل غير مزامن',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    'سيُرفع تلقائياً عند توفر الإنترنت',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            FilledButton.tonal(
              onPressed: () => ref.read(syncProvider.notifier).syncNow(),
              child: const Text('ارفع الآن'),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.green.withValues(alpha: theme.brightness == Brightness.dark ? 0.15 : 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: Colors.green.withValues(alpha: 0.2),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.check_circle_outline, size: 20, color: Colors.green.shade600),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'جميع السجلات متزامنة',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: Colors.green.shade700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// شريط حالة المزامنة
/// شريط الإشعارات الدائمة من المدير (يظهر أعلى الرئيسية)
class _PersistentNotices extends ConsumerWidget {
  final String farmId;

  const _PersistentNotices({required this.farmId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final noticesAsync = ref.watch(activeNoticesProvider(farmId));
    final notices = (noticesAsync.value ?? const <AppNotificationModel>[])
        .where((n) => n.isPersistent)
        .toList();

    if (notices.isEmpty) return const SizedBox.shrink();

    final visible = notices.take(3).toList();

    return Column(
      children: [
        for (final notice in visible)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => Navigator.pushNamed(context, '/notifications'),
              child: Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: noticeColor(context, notice.level)
                      .withValues(alpha: 0.10),
                  border: Border.all(
                    color: noticeColor(context, notice.level)
                        .withValues(alpha: 0.4),
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                          width: 4, color: noticeColor(context, notice.level)),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10),
                          child: Row(
                            children: [
                              Icon(Icons.campaign,
                                  size: 20,
                                  color:
                                      noticeColor(context, notice.level)),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  notice.body == null ||
                                          notice.body!.isEmpty
                                      ? notice.title
                                      : '${notice.title} — ${notice.body}',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 13.5),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}


