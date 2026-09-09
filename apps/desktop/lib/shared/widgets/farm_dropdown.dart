import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/core.dart';
import '../../core/providers.dart';
import '../../features/auth/providers/auth_provider.dart';

/// مداجن المستخدم الحالي بأسمائها (مبدّل المدجنة في الشاشات)
final currentUserFarmsProvider = FutureProvider<List<FarmModel>>((ref) {
  return ref.read(userAdminRepositoryProvider).getCurrentUserFarms();
});

/// قائمة منسدلة لاختيار المدجنة الفعّالة — تظهر فقط عندما يكون المستخدم
/// مرتبطاً بأكثر من مدجنة. عند الاختيار تُحدَّث المدجنة النشطة.
class FarmDropdown extends ConsumerWidget {
  const FarmDropdown({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final user = ref.watch(authProvider.select((s) => s.currentUser));
    final farmsAsync = ref.watch(currentUserFarmsProvider);
    final farms = farmsAsync.valueOrNull ?? const <FarmModel>[];
    if (user == null || farms.isEmpty) return const SizedBox.shrink();

    final currentId = user.farmId ?? '';
    final matched = farms.where((f) => f.id == currentId).toList();
    final current = matched.isEmpty ? farms.first : matched.first;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.apartment_rounded,
              size: 16, color: theme.colorScheme.primary),
          const SizedBox(width: 6),
          if (farms.length <= 1)
            Text(
              current.name,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.onSurface,
              ),
            )
          else
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 200),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  isDense: true,
                  value: current.id,
                  dropdownColor: theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(12),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onSurface,
                  ),
                  items: [
                    for (final f in farms)
                      DropdownMenuItem(
                        value: f.id,
                        child: Text(f.name,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (id) {
                    if (id != null && id != current.id) {
                      ref.read(authProvider.notifier).setActiveFarm(id);
                    }
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }
}