import 'package:flutter/material.dart';
import '../../services/api_service.dart';
import '../../services/auth_service.dart';
import '../../providers/entry_provider.dart';
import '../home_screen.dart';
import 'register_screen.dart';
import 'package:provider/provider.dart';
import '../settings_page.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailCtl = TextEditingController();
  final _passCtl = TextEditingController();
  bool _loading = false;
  bool _obscure = true;
  final ApiService _api = ApiService();

  @override
  void dispose() {
    _emailCtl.dispose();
    _passCtl.dispose();
    super.dispose();
  }

  String? _validateEmail(String? v) {
    if (v == null || v.trim().isEmpty) return 'Email is required';
    final email = v.trim();
    final regex = RegExp(r'^[^@]+@[^@]+\.[^@]+');
    if (!regex.hasMatch(email)) return 'Enter a valid email';
    return null;
  }

  String? _validatePassword(String? v) {
    if (v == null || v.isEmpty) return 'Password is required';
    if (v.length < 6) return 'Password must be at least 6 characters';
    return null;
  }

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);
    try {
      final res = await _api.login(_emailCtl.text.trim(), _passCtl.text);
      final token = res['token'] as String;
      final user = Map<String, dynamic>.from(res['user'] as Map);
      await AuthService.saveToken(token, user);
      await AuthService.load();

      try {
        context.read<EntryProvider>().clearForLogout();
      } catch (_) {}

      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const HomeScreen()),
            (route) => false,
      );
    } catch (e) {
      final msg = e?.toString() ?? 'Login failed';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Login failed: $msg')));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Login'),
        actions: [
          IconButton(icon: const Icon(Icons.settings), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsPage()))),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 8),
                  Hero(tag: 'app-logo', child: CircleAvatar(radius: 44, backgroundColor: theme.colorScheme.primary, child: const Icon(Icons.pie_chart, size: 44, color: Colors.white))),
                  const SizedBox(height: 18),
                  Text('Welcome back', style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Text('Sign in to access your finance dashboard', style: theme.textTheme.bodyMedium?.copyWith(color: Colors.black54)),
                  const SizedBox(height: 20),
                  Form(
                    key: _formKey,
                    child: Column(children: [
                      TextFormField(
                        controller: _emailCtl,
                        keyboardType: TextInputType.emailAddress,
                        decoration: const InputDecoration(labelText: 'Email', prefixIcon: Icon(Icons.email)),
                        validator: _validateEmail,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _passCtl,
                        obscureText: _obscure,
                        decoration: InputDecoration(
                          labelText: 'Password',
                          prefixIcon: const Icon(Icons.lock),
                          suffixIcon: IconButton(
                            icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                            onPressed: () => setState(() => _obscure = !_obscure),
                          ),
                        ),
                        validator: _validatePassword,
                      ),
                      const SizedBox(height: 18),
                      _loading
                          ? const SizedBox(height: 48, child: Center(child: CircularProgressIndicator()))
                          : FilledButton(
                        onPressed: _login,
                        child: const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Text('Sign In')),
                      ),
                      const SizedBox(height: 12),
                      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                        const Text('Don\'t have an account?'),
                        TextButton(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const RegisterScreen())), child: const Text('Create account')),
                      ]),
                    ]),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}