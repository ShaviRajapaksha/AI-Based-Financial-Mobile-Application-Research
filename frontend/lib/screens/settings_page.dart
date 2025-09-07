import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/config_service.dart';
import 'package:provider/provider.dart';
import '../providers/entry_provider.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final TextEditingController _ipController = TextEditingController();
  final TextEditingController _portController = TextEditingController();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loadSavedConfig();
  }

  Future<void> _loadSavedConfig() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _ipController.text = prefs.getString("backend_ip") ?? ConfigService.ip;
      _portController.text = prefs.getString("backend_port") ?? ConfigService.port;
    });
  }

  Future<void> _saveConfig() async {
    setState(() => _saving = true);
    final ip = _ipController.text.trim();
    final port = _portController.text.trim();

    if (ip.isEmpty || port.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("IP and Port are required")));
      setState(() => _saving = false);
      return;
    }

    try {
      await ConfigService.saveConfig(ip: ip, port: port);
      // Force reload from prefs (keeps state consistent if other code reads)
      await ConfigService.loadConfig();

      // Try to refresh entries via provider (attempt connection)
      try {
        await context.read<EntryProvider>().refresh();
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Saved and refreshed successfully")));
      } catch (_) {
        // Could not refresh entries — still saved config
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Saved, but could not reach backend")));
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Save failed: $e")));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _ipController.dispose();
    _portController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("API Settings"),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _ipController,
              decoration: const InputDecoration(labelText: "Backend IP (or hostname)"),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _portController,
              decoration: const InputDecoration(labelText: "Backend Port"),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 20),
            _saving
                ? const CircularProgressIndicator()
                : ElevatedButton.icon(
              onPressed: _saveConfig,
              icon: const Icon(Icons.save),
              label: const Text("Save & Test"),
            ),
            const SizedBox(height: 12),
            Text("Current base URL: ${ConfigService.baseUrl}"),
          ],
        ),
      ),
    );
  }
}