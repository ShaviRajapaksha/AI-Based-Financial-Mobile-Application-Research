// lib/screens/savings/savings_goals_screen.dart
import 'package:flutter/material.dart';
import '../../services/api_service.dart';
import 'savings_goal_detail.dart';
import 'package:intl/intl.dart';

class SavingsGoalsScreen extends StatefulWidget {
  const SavingsGoalsScreen({super.key});
  @override
  State<SavingsGoalsScreen> createState() => _SavingsGoalsScreenState();
}

class _SavingsGoalsScreenState extends State<SavingsGoalsScreen> {
  final ApiService _api = ApiService();
  bool _loading = false;
  List<Map<String, dynamic>> _goals = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final list = await _api.listSavingsGoals();
      // ensure each item is a Map<String, dynamic>
      setState(() => _goals = list.map((e) => Map<String, dynamic>.from(e)).toList());
    } catch (e) {
      debugPrint('load goals failed: $e');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Load failed: $e')));
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _showCreateDialog() async {
    final nameCtl = TextEditingController();
    final targetCtl = TextEditingController();
    DateTime? chosenDate;
    await showDialog(context: context, builder: (ctx) {
      return StatefulBuilder(builder: (ctx2, setSt) {
        return AlertDialog(
          title: const Text('Create Savings Goal'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: nameCtl, decoration: const InputDecoration(labelText: 'Goal name')),
            TextField(controller: targetCtl, decoration: const InputDecoration(labelText: 'Target amount'), keyboardType: TextInputType.number),
            const SizedBox(height: 8),
            Row(children: [
              const Text('Deadline:'),
              const SizedBox(width: 8),
              Expanded(child: Text(chosenDate == null ? 'No date' : DateFormat.yMMMd().format(chosenDate!))),
              TextButton(onPressed: () async {
                final d = await showDatePicker(context: context, initialDate: DateTime.now().add(const Duration(days:30)), firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days:3650)));
                if (d != null) setSt(() => chosenDate = d);
              }, child: const Text('Choose'))
            ])
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(onPressed: () async {
              final name = nameCtl.text.trim();
              final targ = double.tryParse(targetCtl.text.trim()) ?? 0.0;
              if (name.isEmpty || targ <= 0) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter name and positive target')));
                return;
              }
              Navigator.pop(ctx);
              setState(() => _loading = true);
              try {
                final isoDate = chosenDate != null ? chosenDate!.toIso8601String().split('T').first : null;
                await _api.createSavingsGoal(name: name, targetAmount: targ, targetDateIso: isoDate);
                await _load();
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Create failed: $e')));
              } finally {
                setState(() => _loading = false);
              }
            }, child: const Text('Create')),
          ],
        );
      });
    });
  }

  Widget _goalTile(Map<String, dynamic> g) {
    final progress = (g['progress'] != null) ? Map<String, dynamic>.from(g['progress'] as Map) : null;
    final percent = (progress != null && progress['percent'] != null) ? (progress['percent'] as num).toDouble() : 0.0;
    final saved = (progress != null && progress['total_saved'] != null) ? progress['total_saved'] : g['saved'] ?? 0;
    final target = (progress != null && progress['target_amount'] != null) ? progress['target_amount'] : g['target_amount'] ?? 0.0;
    final subtitle = 'Saved ${saved.toString()} / ${target.toString()}';

    return InkWell(
      onTap: () async {
        // open detail and refresh when returning
        await Navigator.push(context, MaterialPageRoute(builder: (_) => SavingsGoalDetail(goalId: g['id'] as int)));
        await _load();
      },
      child: Card(
        child: Padding(padding: const EdgeInsets.all(12), child: Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(g['name'] ?? '', style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(subtitle, style: const TextStyle(color: Colors.black54)),
            const SizedBox(height: 8),
            // Progress bar: ensure percent normalized between 0.0 - 100.0
            LinearProgressIndicator(value: (percent / 100.0).clamp(0.0, 1.0)),
          ])),
          const SizedBox(width: 12),
          Column(children: [
            Text('${percent.toStringAsFixed(0)}%', style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            const Icon(Icons.chevron_right),
          ])
        ])),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Savings Goals'),
        actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _load)],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showCreateDialog,
        icon: const Icon(Icons.add),
        label: const Text('New Goal'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _goals.isEmpty
            ? const Center(child: Text('No savings goals yet.'))
            : ListView.builder(
          itemCount: _goals.length,
          itemBuilder: (_, i) => _goalTile(_goals[i]),
        ),
      ),
    );
  }
}