import 'dart:io';
import 'package:supabase_flutter/supabase_flutter.dart';

/// خدمة رفع الملفات إلى Supabase Storage
class SupabaseStorageService {
  final SupabaseClient _client;

  SupabaseStorageService(this._client);

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
      await _client.storage.from(bucket).upload(
            path,
            file,
            fileOptions: const FileOptions(
              cacheControl: '3600',
              upsert: false,
              contentType: 'image/jpeg',
            ),
          );

      // جلب الرابط العام
      final url = await _client.storage.from(bucket).getPublicUrl(path);
      return url;
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
      await _client.storage.from(bucket).remove([path]);
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