import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';

/// خدمة مراقبة الاتصال بالإنترنت
abstract class ConnectivityService {
  /// تدفق حالة الاتصال (true = متصل)
  Stream<bool> get onConnectivityChanged;

  /// هل الجهاز متصل حالياً؟
  Future<bool> isConnected();
}

/// تنفيذ خدمة الاتصال عبر connectivity_plus
class ConnectivityServiceImpl implements ConnectivityService {
  final Connectivity _connectivity = Connectivity();

  @override
  Stream<bool> get onConnectivityChanged => _connectivity.onConnectivityChanged
      .map((results) => results.any((r) => r != ConnectivityResult.none));

  @override
  Future<bool> isConnected() async {
    final results = await _connectivity.checkConnectivity();
    return results.any((r) => r != ConnectivityResult.none);
  }
}