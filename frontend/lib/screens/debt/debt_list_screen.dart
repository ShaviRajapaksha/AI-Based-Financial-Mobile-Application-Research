import 'package:flutter/material.dart';
import '../../services/api_service.dart';

class DebtListScreen extends StatefulWidget {
  const DebtListScreen({super.key});
  @override
  State<DebtListScreen> createState() => _DebtListScreenState();
}

class _DebtListScreenState extends State<DebtListScreen> {
  final ApiService _api = ApiService();
  bool _loading = true;
  String? _error;
  Map<String, dynamic>? _summary;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final res = await _api.get('/api/debt/summary');
      setState(() => _summary = res);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _loading = false);
    }
  }

  Widget _accountTile(Map<String, dynamic> a) {
    return Card(
      child: ListTile(
        title: Text(a['vendor'] ?? 'Unknown'),
        subtitle: Text('Outstanding: ${a['outstanding']?.toString() ?? "0"} Borrowed ${a['borrowed']?.toString() ?? "0"}'),
        onTap: () {},
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final accounts = (_summary?['accounts'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [];
    return Scaffold(
      appBar: AppBar(title: const Text('Debt Overview'), actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _load)]),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
            ? Center(child: Text('Error: $_error'))
            : Column(children: [
          Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(children: [
            Text('Total outstanding: ${_summary?['total_outstanding'] ?? 0}'),
            Text('Money in hand (this month est): ${_summary?['money_in_hand'] ?? 0}'),
          ]))),
          const SizedBox(height: 8),
          Expanded(child: ListView.builder(itemCount: accounts.length, itemBuilder: (_, i) => _accountTile(accounts[i]))),
        ]),
      ),
    );
  }
}