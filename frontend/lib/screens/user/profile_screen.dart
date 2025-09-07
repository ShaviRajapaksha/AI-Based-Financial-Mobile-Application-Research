import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/api_service.dart';
import '../../services/auth_service.dart';
import '../../providers/entry_provider.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtl = TextEditingController();
  final _oldCtl = TextEditingController();
  final _newCtl = TextEditingController();
  final _confirmCtl = TextEditingController();
  bool _loading = false;
  bool _changePassword = false;
  bool _obscure = true;
  final ApiService _api = ApiService();

  @override
  void initState() {
    super.initState();
    final u = AuthService.user;
    _nameCtl.text = (u != null && u['name'] != null) ? u['name'] as String : '';
  }

  @override
  void dispose() {
    _nameCtl.dispose();
    _oldCtl.dispose();
    _newCtl.dispose();
    _confirmCtl.dispose();
    super.dispose();
  }

  String? _validateName(String? v) {
    if (v == null) return null;
    final t = v.trim();
    if (t.isEmpty) return 'Name cannot be empty';
    if (t.length < 2) return 'Enter a valid name';
    return null;
  }

  String? _validateNewPwd(String? v) {
    if (!_changePassword) return null;
    if (v == null || v.isEmpty) return 'New password required';
    if (v.length < 6) return 'Password must be at least 6 characters';
    return null;
  }

  Future<void> _save() async {
    if (_loading) return;
    if (!_formKey.currentState!.validate()) return;

    final newName = _nameCtl.text.trim();
    String? oldPwd;
    String? newPwd;

    if (_changePassword) {
      oldPwd = _oldCtl.text;
      newPwd = _newCtl.text;
      if (newPwd != _confirmCtl.text) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('New passwords do not match')));
        return;
      }
    }

    setState(() => _loading = true);
    try {
      final res = await _api.updateProfile(name: newName.isEmpty ? null : newName, oldPassword: oldPwd, newPassword: newPwd);
      // backend returns updated user
      final updatedUser = res['user'] as Map<String, dynamic>?;
      if (updatedUser != null) {
        await AuthService.updateUser(Map<String, dynamic>.from(updatedUser));
      }
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Profile updated')));
      // clear sensitive fields
      _oldCtl.clear();
      _newCtl.clear();
      _confirmCtl.clear();
      setState(() => _changePassword = false);
      // optional: refresh entries if desired
      try {
        context.read<EntryProvider>().refresh();
      } catch (_) {}
    } catch (e) {
      final msg = e?.toString() ?? 'Update failed';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Update failed: $msg')));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Form(
              key: _formKey,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const SizedBox(height: 6),
                Text('Account', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _nameCtl,
                  decoration: const InputDecoration(labelText: 'Full name', prefixIcon: Icon(Icons.person)),
                  validator: _validateName,
                ),
                const SizedBox(height: 16),
                SwitchListTile(
                  title: const Text('Change password'),
                  subtitle: const Text('Enable to update your account password'),
                  value: _changePassword,
                  onChanged: (v) => setState(() => _changePassword = v),
                ),
                if (_changePassword) ...[
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _oldCtl,
                    obscureText: _obscure,
                    decoration: const InputDecoration(labelText: 'Current password', prefixIcon: Icon(Icons.lock)),
                    validator: (v) => (v == null || v.isEmpty) ? 'Current password required' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _newCtl,
                    obscureText: _obscure,
                    decoration: InputDecoration(
                      labelText: 'New password',
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: IconButton(icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off), onPressed: () => setState(() => _obscure = !_obscure)),
                    ),
                    validator: _validateNewPwd,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _confirmCtl,
                    obscureText: _obscure,
                    decoration: const InputDecoration(labelText: 'Confirm new password', prefixIcon: Icon(Icons.lock_outline)),
                    validator: (v) {
                      if (!_changePassword) return null;
                      if (v == null || v.isEmpty) return 'Confirm new password';
                      if (v != _newCtl.text) return 'Passwords do not match';
                      return null;
                    },
                  ),
                ],
                const SizedBox(height: 18),
                _loading
                    ? const SizedBox(height: 48, child: Center(child: CircularProgressIndicator()))
                    : FilledButton.icon(onPressed: _save, icon: const Icon(Icons.save), label: const Text('Save changes')),
                const SizedBox(height: 12),
                OutlinedButton.icon(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close), label: const Text('Cancel')),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}