import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import '../../core/providers.dart';
import '../../features/auth/providers/auth_provider.dart';

/// مبدّل المدجنة النشطة — يظهر تلقائياً فقط عندما يكون المستخدم مرتبطاً
/// بأكثر من مدجنة. عند الاختيار يُحدَّث نشاط المستخدم وتُعاد التحميلات.
class FarmSelector extends ConsumerWidget {
  final VoidCallback? onChanged;

  const FarmSelector({super.key, this.onChanged});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final user = ref.watch(authProvider).currentUser;
    final farmsAsync = ref.watch(currentUserFarmsProvider);
    final farms = farmsAsync.valueOrNull ?? const <FarmModel>[];
    if (user == null || farms.isEmpty) return const SizedBox.shrink();

    final currentId = user.farmId ?? '';
    final matched = farms.where((f) => f.id == currentId).toList();
    final current = matched.isEmpty ? farms.first : matched.first;

    return Material(
      color: Colors.white.withValues(alpha: 0.92),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.apartment_rounded,
                size: 18, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            if (farms.length <= 1)
              Flexible(
                child: Text(
                  current.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              )
            else
              DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  isDense: true,
                  value: current.id,
                  dropdownColor: theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(12),
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.onSurface,
                  ),
                  items: [
                    for (final f in farms)
                      DropdownMenuItem(
                        value: f.id,
                        child: Text(
                          f.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (id) {
                    if (id != null && id != current.id) {
                      ref.read(authProvider.notifier).setActiveFarm(id);
                      onChanged?.call();
                    }
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}