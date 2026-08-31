/// نتيجة رفع مجموعة سجلات إلى السحابة
class BatchUploadResult {
  final List<String> successIds;
  final List<String> failedIds;

  BatchUploadResult({
    required this.successIds,
    required this.failedIds,
  });

  int get successCount => successIds.length;
  int get failedCount => failedIds.length;
  bool get hasFailures => failedIds.isNotEmpty;
}
