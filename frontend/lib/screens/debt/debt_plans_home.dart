import 'package:flutter/material.dart';
import '../../services/api_service.dart';
import 'debt_plan_create.dart';
import 'debt_plan_detail.dart';

class DebtPlansHome extends StatefulWidget {
  const DebtPlansHome({super.key});
  @override
  State<DebtPlansHome> createState() => _DebtPlansHomeState();
}

class _DebtPlansHomeState extends State<DebtPlansHome> {
  final ApiService _api = ApiService();
  bool _loading = true;
  List<Map<String, dynamic>> _plans = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final res = await _api.get('/api/debt/plans');
      setState(() => _plans = List<Map<String, dynamic>>.from(res['items'] ?? []));
    } catch (e) {
      debugPrint('load plans failed: $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _delete(int id) async {
    try {
      await _api.delete('/api/debt/plans/$id');
      _load();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Delete failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Payment Plans'),
        actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _load)],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          await Navigator.push(context, MaterialPageRoute(builder: (_) => const DebtPlanCreate()));
          _load();
        },
        child: const Icon(Icons.add),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _plans.isEmpty
          ? const Center(child: Text('No plans yet — tap + to create'))
          : ListView.builder(
        itemCount: _plans.length,
        itemBuilder: (_, i) {
          final p = _plans[i];
          return Card(
            child: ListTile(
              title: Text(p['name'] ?? 'Plan'),
              subtitle: Text('Outstanding: ${p['principal']} • Rate: ${p['annual_interest_pct']}%'),
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => DebtPlanDetail(planId: p['id']))),
              trailing: IconButton(icon: const Icon(Icons.delete), onPressed: () => _delete(p['id'])),
            ),
          );
        },
      ),
    );
  }
}