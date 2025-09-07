import 'package:shared_preferences/shared_preferences.dart';

class ConfigService {
  static String _ip = "192.168.1.100";
  static String _port = "5000";

  /// Loads saved config from SharedPreferences. Call at startup.
  static Future<void> loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    _ip = prefs.getString("backend_ip") ?? _ip;
    _port = prefs.getString("backend_port") ?? _port;
  }

  /// Returns the computed base URL
  static String get baseUrl => "http://$_ip:$_port";

  /// Helper getters for UI display/edit
  static String get ip => _ip;
  static String get port => _port;

  /// Save new config programmatically (optional)
  static Future<void> saveConfig({required String ip, required String port}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("backend_ip", ip);
    await prefs.setString("backend_port", port);
    _ip = ip;
    _port = port;
  }
}