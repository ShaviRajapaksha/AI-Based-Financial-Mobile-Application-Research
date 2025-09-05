import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'services/config_service.dart';
import 'services/api_service.dart';
import 'providers/entry_provider.dart';
import 'screens/home_screen.dart';
import 'screens/settings_page.dart';
import 'services/auth_service.dart';
import 'screens/user/login_screen.dart';
import 'services/notification_service.dart';

final RouteObserver<ModalRoute<void>> routeObserver = RouteObserver<ModalRoute<void>>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ConfigService.loadConfig();
  await AuthService.load();
  await NotificationService.instance.initialize();
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  MyApp({super.key});

  final ApiService apiService = ApiService();

  @override
  Widget build(BuildContext context) {
    final startWidget = AuthService.token == null ? const LoginScreen() : const HomeScreen();

    final inputTheme = InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: Colors.black12),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: Theme.of(context).colorScheme.primary, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Colors.red),
      ),
    );

    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => EntryProvider(apiService)),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Finance Manager',
        theme: ThemeData(
          useMaterial3: true,
          colorSchemeSeed: Colors.greenAccent,
          inputDecorationTheme: inputTheme,
        ),
        home: startWidget,
        routes: {
          '/settings': (_) => const SettingsPage(),
        },
        navigatorObservers: [routeObserver],
      ),
    );
  }
}