import 'package:flutter/material.dart';
import '../../services/api_service.dart';
import '../../services/auth_service.dart';
import '../../providers/entry_provider.dart';
import '../home_screen.dart';
import 'package:provider/provider.dart';
import '../settings_page.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});
  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtl = TextEditingController();
  final _emailCtl = TextEditingController();
  final _passCtl = TextEditingController();
  final _confirmCtl = TextEditingController();
  bool _loading = false;
  bool _obscure = true;
  final ApiService _api = ApiService();

  @override
  void dispose() {
    _nameCtl.dispose();
    _emailCtl.dispose();
    _passCtl.dispose();
    _confirmCtl.dispose();
    super.dispose();
  }

  String? _validateName(String? v) {
    if (v == null || v.trim().isEmpty) return 'Name is required';
    if (v.trim().length < 2) return 'Enter a valid name';
    return null;
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

  Future<void> _register() async {
    if (!_formKey.currentState!.validate()) return;
    if (_passCtl.text != _confirmCtl.text) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Passwords do not match')));
      return;
    }

    setState(() => _loading = true);
    try {
      final res = await _api.register(_emailCtl.text.trim(), _passCtl.text, _nameCtl.text.trim());
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
      final msg = e?.toString() ?? 'Register failed';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Register failed: $msg')));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Create account'),
        actions: [
          IconButton(icon: const Icon(Icons.settings), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsPage()))),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text('Create account', style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Text('Sign up to start tracking your finances securely', style: theme.textTheme.bodyMedium?.copyWith(color: Colors.black54)),
                const SizedBox(height: 18),
                Form(
                  key: _formKey,
                  child: Column(children: [
                    TextFormField(controller: _nameCtl, decoration: const InputDecoration(labelText: 'Full name', prefixIcon: Icon(Icons.person)), validator: _validateName),
                    const SizedBox(height: 12),
                    TextFormField(controller: _emailCtl, decoration: const InputDecoration(labelText: 'Email', prefixIcon: Icon(Icons.email)), validator: _validateEmail, keyboardType: TextInputType.emailAddress),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _passCtl,
                      obscureText: _obscure,
                      decoration: InputDecoration(
                        labelText: 'Password',
                        prefixIcon: const Icon(Icons.lock),
                        suffixIcon: IconButton(icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off), onPressed: () => setState(() => _obscure = !_obscure)),
                      ),
                      validator: _validatePassword,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(controller: _confirmCtl, obscureText: _obscure, decoration: const InputDecoration(labelText: 'Confirm Password'), validator: (v) => v == null || v.isEmpty ? 'Confirm password' : null),
                    const SizedBox(height: 18),
                    _loading ? const SizedBox(height: 48, child: Center(child: CircularProgressIndicator())) : FilledButton(onPressed: _register, child: const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Text('Create account'))),
                  ]),
                ),
                const SizedBox(height: 12),
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  const Text('Already have an account?'),
                  TextButton(onPressed: () => Navigator.pop(context), child: const Text('Sign in')),
                ]),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}