import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AuthService {
  static const _KEY_TOKEN = 'auth_token';
  static const _KEY_USER = 'auth_user'; // json

  static String? _token;
  static Map<String, dynamic>? _user;

  /// Notifier that UIs can listen to to get instant updates when user changes.
  static final ValueNotifier<Map<String, dynamic>?> userNotifier = ValueNotifier(null);

  /// Load token & user from SharedPreferences into memory and notify listeners.
  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _token = prefs.getString(_KEY_TOKEN);
    final userJson = prefs.getString(_KEY_USER);
    _user = userJson != null ? Map<String, dynamic>.from(jsonDecode(userJson)) : null;
    userNotifier.value = _user;
  }

  static String? get token => _token;
  static Map<String, dynamic>? get user => _user;

  /// Save token and user to storage and notify listeners.
  static Future<void> saveToken(String token, Map<String, dynamic> userInfo) async {
    final prefs = await SharedPreferences.getInstance();
    _token = token;
    _user = userInfo;
    userNotifier.value = _user;
    await prefs.setString(_KEY_TOKEN, token);
    await prefs.setString(_KEY_USER, jsonEncode(userInfo));
  }

  /// Update stored user object (and persist to prefs) and notify listeners.
  static Future<void> updateUser(Map<String, dynamic> userInfo) async {
    final prefs = await SharedPreferences.getInstance();
    _user = userInfo;
    userNotifier.value = _user;
    await prefs.setString(_KEY_USER, jsonEncode(userInfo));
  }

  /// Clear token & user and notify listeners.
  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    _token = null;
    _user = null;
    userNotifier.value = null;
    await prefs.remove(_KEY_TOKEN);
    await prefs.remove(_KEY_USER);
  }

  /// Helper to get auth header map
  static Map<String, String> authHeader() {
    if (_token != null) return {'Authorization': 'Bearer $_token'};
    return {};
  }
}