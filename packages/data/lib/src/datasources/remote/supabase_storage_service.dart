import 'dart:io';
import 'supabase_api.dart';

/// خدمة رفع الملفات إلى Supabase Storage
class SupabaseStorageService {
  final SupabaseStorageApi _storage;

  SupabaseStorageService(this._storage);

  /// رفع صورة
  ///
  /// المعاملات:
  /// - bucket: اسم السلة (مثل: farm-images)
  /// - path: المسار داخل السلة
  /// - file: الملف المراد رفعه
  ///
  /// يُرجع: الرابط العام للصورة
  Future<String> uploadImage({
    required String bucket,
    required String path,
    required File file,
  }) async {
    try {
      // رفع الملف
      await _storage.upload(
        bucket,
        path,
        file,
        cacheControl: '3600',
        upsert: false,
        contentType: 'image/jpeg',
      );

      // جلب الرابط العام
      return _storage.getPublicUrl(bucket, path);
    } catch (e) {
      throw StorageException('فشل رفع الصورة: $e');
    }
  }

  /// حذف صورة
  Future<void> deleteImage({
    required String bucket,
    required String path,
  }) async {
    try {
      await _storage.remove(bucket, path);
    } catch (e) {
      throw StorageException('فشل حذف الصورة: $e');
    }
  }
}

class StorageException implements Exception {
  final String message;
  StorageException(this.message);
  @override
  String toString() => message;
}