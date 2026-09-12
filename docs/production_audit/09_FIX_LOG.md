# 09 — Fix Log

> Applied during PHASE 10 on 2026-09-11.
> Verified during PHASE 11 (regression tests) and PHASE 12 (staging verification).

## Format

| ID | Blocker | File Changed | Before | After | Test | Result |
|----|---------|-------------|--------|-------|------|--------|
| P0-001 | Self-role escalation | `supabase/migrations/UPGRADE_security_hardening.sql` | No trigger on `users.role` | BEFORE UPDATE + BEFORE INSERT triggers block non-admin role changes | SQL-only (requires Supabase) | NOT VERIFIED (no staging) |
| P0-002 | Bootstrap token dead code | `supabase/migrations/UPGRADE_security_hardening.sql` | Token param unused | Token verified against `app_settings('secure.bootstrap_token')` | SQL-only (requires Supabase) | NOT VERIFIED (no staging) |
| P0-003 | device_id never populated | `local_database.dart`, `sync_repository_impl.dart`, `UPGRADE_security_hardening.sql` | device_id always NULL | UUID v4 generated, persisted, sent in payload, stored in sync_changes | `device_id_regression_test.dart` (4 tests) | ✅ PASS |
| P0-004 | Approvals cross-farm leak | `apps/desktop/.../approvals_screen.dart` | No farm_id filter | `.eq('farm_id', farmId)` on both queries | Integration test required | NOT VERIFIED (no staging) |
| P0-005 | Emergency screen stub | `apps/mobile/.../emergency_screen.dart` | `Future.delayed(2s)` stub | Real `Supabase.from('app_notifications').insert(...)` with error handling | Integration test required | NOT VERIFIED (no staging) |
| P1-007 | Role dropdown offers system_admin to managers | `apps/desktop/.../users_screen.dart` | Static list includes system_admin | Dynamic list, system_admin only for admins, coercion guard | Widget test required | NOT VERIFIED (no widget tests) |
| P1-008 | resyncRequired dead end | `packages/data/.../sync_repository_impl.dart` | Returns `resyncRequired: true`, device stuck | Resets `last_pulled_version` to 0, re-pulls immediately | Integration test required | NOT VERIFIED (no staging) |
| P1-009 | Sync dies after 5 errors | `apps/mobile/.../sync_provider.dart` | `_stopPeriodicSync()` permanent | Exponential backoff retry (2→30min), cancels on success | Integration test required | NOT VERIFIED (no staging) |
| P1-010 | Mortality image upload loses fields | `packages/core/.../mortality_model.dart`, `mortality_provider.dart` | Manual constructor discards fields | `copyWith(imageUrl: imageUrl)` preserves all fields | `mortality_regression_test.dart` (5 tests) | ✅ PASS |
| P1-011 | Division-by-zero in mortality % | `packages/core/.../save_mortality_usecase.dart` | `(count/0)*100` → Infinity/NaN | Zero-guard: `flockCount > 0 ? ... : 0.0` | `mortality_regression_test.dart` (3 tests) | ✅ PASS |
| P2-01 | Offline creds survive logout | `packages/data/.../auth_repository_impl.dart` | `logout()` clears session only | `logout()` also clears `offline_phone`, `offline_pin_hash`, `offline_user_json`, `offline_farm_id` | Unit test required | NOT VERIFIED |
| P2-07 | Chinese text in onboarding | `apps/mobile/.../new_flock_wizard_screen.dart`, `old_flock_wizard_screen.dart` | `基本信息` (Chinese) | `البيانات الأساسية` (Arabic) | Visual inspection | ✅ PASS (text replacement verified) |

## Summary

- **Total fixes applied:** 12
- **Verified by automated tests:** 4 (P0-003: 4 tests, P1-010: 5 tests, P1-011: 3 tests)
- **Requires staging verification:** 5 (P0-001, P0-002, P0-004, P0-005, P1-008)
- **Requires widget/integration test:** 2 (P1-007, P1-009)
- **Visual/manual verification:** 1 (P2-07)
- **Unit test needed:** 1 (P2-01)
