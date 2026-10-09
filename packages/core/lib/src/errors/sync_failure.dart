/// خطأ يرميه التطبيق عند فشل مزامنة/عملية بعيدة، محمولاً بكود مستقر
/// (AUTH, UNKNOWN ...) وسبب أصلي — تفاصيل القاعدة في docs/ERROR_HANDLING.md.
class SyncFailure implements Exception {
  final String code;
  final String message;
  final Object? cause;

  SyncFailure(this.code, this.message, [this.cause]);

  @override
  String toString() => 'SyncFailure($code): $message';
}