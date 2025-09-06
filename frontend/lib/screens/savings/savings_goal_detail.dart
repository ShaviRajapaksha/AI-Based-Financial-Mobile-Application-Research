import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../services/api_service.dart';
import 'package:url_launcher/url_launcher.dart';

class SavingsGoalDetail extends StatefulWidget {
  final int goalId;
  const SavingsGoalDetail({required this.goalId, super.key});
  @override
  State<SavingsGoalDetail> createState() => _SavingsGoalDetailState();
}

class _SavingsGoalDetailState extends State<SavingsGoalDetail> {
  final ApiService _api = ApiService();
  bool _loading = false;
  Map<String, dynamic>? _data; // contains goal, progress, contributions, adaptive

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final d = await _api.getSavingsGoal(widget.goalId);
      setState(() => _data = d);
    } catch (e) {
      debugPrint('load goal detail failed: $e');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Load failed: $e')));
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _addContributionDialog() async {
    final amtCtl = TextEditingController();
    DateTime chosen = DateTime.now();
    final notesCtl = TextEditingController();
    await showDialog(context: context, builder: (ctx) {
      return AlertDialog(
        title: const Text('Add Contribution'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: amtCtl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Amount')),
          TextField(controller: notesCtl, decoration: const InputDecoration(labelText: 'Notes (optional)')),
          Row(children: [
            const Text('Date: '),
            Text(DateFormat.yMMMd().format(chosen)),
            TextButton(onPressed: () async {
              final d = await showDatePicker(context: context, initialDate: chosen, firstDate: DateTime(2000), lastDate: DateTime.now().add(const Duration(days:3650)));
              if (d != null) setState(() => chosen = d);
            }, child: const Text('Choose'))
          ])
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () async {
            final amt = double.tryParse(amtCtl.text.trim()) ?? 0.0;
            if (amt <= 0) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter positive amount')));
              return;
            }
            Navigator.pop(ctx);
            setState(() => _loading = true);
            try {
              await _api.contributeToGoal(widget.goalId, amt, dateIso: chosen.toIso8601String().split('T')[0], notes: notesCtl.text.trim());
              await _load();
            } catch (e) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: $e')));
            } finally {
              setState(() => _loading = false);
            }
          }, child: const Text('Add'))
        ],
      );
    });
  }

  Future<void> _generateReport() async {
    setState(() => _loading = true);
    try {
      final res = await _api.createSavingsReport(goalId: widget.goalId, name: 'Savings report for goal ${widget.goalId}');
      final id = res['id'] as int?;
      if (id != null) {
        final url = _api.savingsReportDownloadUrl(id);
        if (await canLaunchUrl(Uri.parse(url))) {
          await launchUrl(Uri.parse(url));
        } else {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not open report URL')));
        }
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Report failed: $e')));
    } finally {
      setState(() => _loading = false);
    }
  }

  Widget _buildHeader() {
    final goal = _data?['goal'] as Map<String, dynamic>?;
    final prog = _data?['progress'] as Map<String, dynamic>?;
    if (goal == null || prog == null) return const SizedBox.shrink();
    final percent = (prog['percent'] as num?)?.toDouble() ?? 0.0;
    final saved = prog['total_saved'] ?? 0;
    final target = prog['target_amount'] ?? 0;
    final monthsLeft = prog['months_left'];
    final monthlyReq = prog['monthly_required'];
    return Card(
      child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(goal['name'] ?? '', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text('Saved: ${saved.toString()} / ${target.toString()}'),
        const SizedBox(height: 8),
        LinearProgressIndicator(value: (percent/100.0).clamp(0.0,1.0)),
        const SizedBox(height: 8),
        Row(children: [
          if (monthsLeft != null) Text('Months left: $monthsLeft'),
          const SizedBox(width: 12),
          if (monthlyReq != null) Text('Need ~${monthlyReq.toString()} / month'),
        ]),
      ])),
    );
  }

  Widget _buildAdaptive() {
    final adapt = _data?['adaptive'] as Map<String, dynamic>?;
    if (adapt == null) return const SizedBox.shrink();
    final msg = adapt['message'] ?? '';
    final suggested = adapt['suggested_monthly'];
    return Card(
      child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Adaptive micro-target', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Text(msg),
        if (suggested != null) ...[
          const SizedBox(height: 8),
          Text('Suggested monthly: ${suggested.toString()}'),
        ]
      ])),
    );
  }

  Widget _buildContribList() {
    final contribs = _data?['contributions'] as List<dynamic>? ?? [];
    if (contribs.isEmpty) return const Center(child: Text('No contributions yet'));
    return Column(children: contribs.map((c) {
      final m = Map<String, dynamic>.from(c as Map);
      return ListTile(
        title: Text('${m['amount'].toString()}'),
        subtitle: Text('${m['contrib_date']} • ${m['notes'] ?? ''}'),
      );
    }).toList());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_data?['goal']?['name'] ?? 'Goal'),
        actions: [IconButton(icon: const Icon(Icons.picture_as_pdf), onPressed: _generateReport), IconButton(icon: const Icon(Icons.refresh), onPressed: _load)],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addContributionDialog,
        icon: const Icon(Icons.add),
        label: const Text('Contribute'),
      ),
      body: _loading ? const Center(child: CircularProgressIndicator()) : SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _buildHeader(),
          const SizedBox(height: 12),
          _buildAdaptive(),
          const SizedBox(height: 12),
          Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Contributions', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            _buildContribList(),
            const SizedBox(height: 6),
          ]))),
        ]),
      ),
    );
  }
}
