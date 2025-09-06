import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../services/api_service.dart';
import '../../services/auth_service.dart';

class InvestmentSuggestionScreen extends StatefulWidget {
  const InvestmentSuggestionScreen({super.key});
  @override
  State<InvestmentSuggestionScreen> createState() => _InvestmentSuggestionScreenState();
}

class _InvestmentSuggestionScreenState extends State<InvestmentSuggestionScreen> {
  final ApiService _api = ApiService();
  final _goalCtl = TextEditingController();
  final _targetCtl = TextEditingController();
  final _horizonCtl = TextEditingController(text: '60');
  String _risk = 'MEDIUM';
  bool _loading = false;
  Map<String, dynamic>? _preview;
  List<Map<String, dynamic>> _saved = [];

  @override
  void initState() {
    super.initState();
    _loadSaved();
  }

  Future<void> _loadSaved() async {
    setState(() => _loading = true);
    try {
      final user = AuthService.user!;
      final uid = user['id'] as int;
      final res = await _api.listInvestmentPlans(uid);
      if (mounted) setState(() => _saved = res);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Load failed: $e')));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // same logic as backend: map risk -> allocation & expected annual return (used only for local preview)
  Map<String, dynamic> _riskDefaults(String r) {
    final rr = (r).toUpperCase();
    if (rr == 'LOW') return {'allocation': {'stocks': 30, 'bonds': 55, 'commodities': 0, 'cash': 15}, 'return': 0.04};
    if (rr == 'HIGH') return {'allocation': {'stocks': 80, 'bonds': 15, 'commodities': 5, 'cash': 0}, 'return': 0.08};
    // MEDIUM
    return {'allocation': {'stocks': 60, 'bonds': 30, 'commodities': 5, 'cash': 5}, 'return': 0.06};
  }

  double _monthlySip(double target, double annualReturn, int months) {
    if (months <= 0) return target;
    final monthlyRate = annualReturn / 12.0;
    if (monthlyRate.abs() < 1e-12) return target / months;
    final denom = (pow(1 + monthlyRate, months) - 1.0);
    if (denom == 0.0) return target / months;
    return target * monthlyRate / denom;
  }

  Future<void> _previewCalc() async {
    final goal = _goalCtl.text.trim();
    final target = double.tryParse(_targetCtl.text.replaceAll(',', '')) ?? 0.0;
    final horizon = int.tryParse(_horizonCtl.text) ?? 0;
    if (goal.isEmpty || target <= 0 || horizon <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please enter goal, target (>0) and horizon (>0)')));
      return;
    }
    setState(() => _loading = true);
    try {
      final def = _riskDefaults(_risk);
      final exp = def['return'] as double;
      final alloc = Map<String,int>.from(def['allocation'] as Map);
      final monthly = _monthlySip(target, exp, horizon);
      if (mounted) setState(() => _preview = {
        'goal': goal,
        'target': target,
        'horizon': horizon,
        'risk': _risk,
        'expected_return': exp,
        'allocation': alloc,
        'monthly_sip': double.parse(monthly.toStringAsFixed(2)),
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _savePlan() async {
    if (_preview == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Preview before saving')));
      return;
    }
    setState(() => _loading = true);
    try {
      final res = await _api.createInvestmentPlanSimple(
        goal: _preview!['goal'],
        targetAmount: _preview!['target'],
        horizonMonths: _preview!['horizon'],
        riskProfile: _preview!['risk'],
      );
      await _loadSaved();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Plan saved')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Save failed: $e')));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _deletePlan(int id) async {
    try {
      final user = AuthService.user!;
      final uid = user['id'] as int;
      await _api.deleteInvestmentPlan(uid, id);
      await _loadSaved();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Deleted')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Delete failed: $e')));
    }
  }

  @override
  void dispose() {
    _goalCtl.dispose();
    _targetCtl.dispose();
    _horizonCtl.dispose();
    super.dispose();
  }

  Widget _previewCard() {
    if (_preview == null) return const SizedBox.shrink();
    final p = _preview!;
    final nf = NumberFormat.currency(symbol: '', decimalDigits: 2);
    final alloc = p['allocation'] as Map<dynamic, dynamic>;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Preview suggestion', style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text('Goal: ${p['goal']}'),
          Text('Target: ${nf.format(p['target'])}'),
          Text('Horizon: ${p['horizon']} months'),
          Text('Risk: ${p['risk']}'),
          Text('Expected annual return: ${(p['expected_return'] * 100).toStringAsFixed(2)}%'),
          const SizedBox(height: 8),
          const Text('Allocation:'),
          const SizedBox(height: 6),
          Wrap(spacing: 8, children: alloc.entries.map<Widget>((e) {
            final k = e.key.toString();
            final v = e.value is num ? (e.value as num).toInt() : int.tryParse(e.value.toString()) ?? 0;
            return Chip(label: Text('$k: $v%'));
          }).toList()),
          const SizedBox(height: 8),
          Text('Monthly SIP required: ${nf.format(p['monthly_sip'])}', style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: FilledButton(onPressed: _savePlan, child: const Text('Save Plan'))),
            const SizedBox(width: 8),
            OutlinedButton(onPressed: () => setState(() => _preview = null), child: const Text('Clear')),
          ]),
        ]),
      ),
    );
  }

  // ---------- Friendly plan details dialog ----------
  void _showPlanDetails(Map<String, dynamic> p) {
    // defensive extractors
    String _str(dynamic v) => v == null ? '-' : v.toString();
    double? _toDouble(dynamic v) {
      if (v == null) return null;
      if (v is num) return v.toDouble();
      return double.tryParse(v.toString());
    }

    final nf = NumberFormat.currency(symbol: 'Rs. ', decimalDigits: 2);
    final goalName = _str(p['goal_name'] ?? p['goal'] ?? p['goalName']);
    final target = _toDouble(p['target_amount'] ?? p['target'] ?? p['targetAmount']) ?? 0.0;
    final horizon = (p['horizon_months'] ?? p['horizon'] ?? p['horizonMonths'])?.toString() ?? '-';
    final risk = _str(p['risk_profile'] ?? p['risk'] ?? p['riskProfile']);
    final expected = _toDouble(p['expected_annual_return'] ?? p['expected_return'] ?? p['expectedReturn']) ?? 0.0;
    final sip = _toDouble(p['monthly_sip'] ?? p['monthlySip'] ?? p['monthly']) ?? 0.0;
    final createdAtRaw = p['created_at'] ?? p['createdAt'] ?? p['created'];
    DateTime? createdAt;
    try {
      if (createdAtRaw is DateTime) createdAt = createdAtRaw;
      else if (createdAtRaw != null) createdAt = DateTime.parse(createdAtRaw.toString());
    } catch (_) {
      createdAt = null;
    }
    final updatedAtRaw = p['updated_at'] ?? p['updatedAt'] ?? p['updated'];
    DateTime? updatedAt;
    try {
      if (updatedAtRaw is DateTime) updatedAt = updatedAtRaw;
      else if (updatedAtRaw != null) updatedAt = DateTime.parse(updatedAtRaw.toString());
    } catch (_) {
      updatedAt = null;
    }

    // allocation might be a JSON string or a Map. Also allow legacy 'equity' key.
    Map<String, dynamic> allocation = {};
    try {
      final rawAlloc = p['allocation'] ?? p['alloc'] ?? p['allocation_json'];
      if (rawAlloc == null) allocation = {};
      else if (rawAlloc is String) {
        allocation = (rawAlloc.isEmpty ? {} : Map<String, dynamic>.from(jsonDecode(rawAlloc)));
      } else if (rawAlloc is Map) {
        allocation = Map<String, dynamic>.from(rawAlloc);
      }
    } catch (_) {
      allocation = {};
    }

    // normalize keys: support 'equity' -> 'stocks'
    if (allocation.isNotEmpty) {
      if (!allocation.containsKey('stocks') && allocation.containsKey('equity')) {
        allocation['stocks'] = allocation['equity'];
      }
    }

    // Build nice sorted list of allocation chips (descending)
    final allocEntries = allocation.entries.map((e) {
      final key = e.key.toString();
      final val = e.value is num ? (e.value as num).toDouble() : double.tryParse(e.value.toString()) ?? 0.0;
      return MapEntry(key, val);
    }).toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Row(children: [
            Expanded(child: Text(goalName, style: const TextStyle(fontWeight: FontWeight.w700))),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: risk == 'HIGH' ? Colors.red.shade50 : (risk == 'LOW' ? Colors.green.shade50 : Colors.orange.shade50),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(risk, style: const TextStyle(fontSize: 12, color: Colors.black87)),
            )
          ]),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Expanded(child: _detailTile('Target', nf.format(target))),
                  const SizedBox(width: 8),
                  Expanded(child: _detailTile('Monthly SIP', nf.format(sip))),
                ]),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(child: _detailTile('Horizon', '$horizon months')),
                  const SizedBox(width: 8),
                  Expanded(child: _detailTile('Expect. return', '${(expected * 100).toStringAsFixed(2)}% p.a.')),
                ]),
                const SizedBox(height: 12),
                const Text('Allocation', style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                if (allocEntries.isEmpty)
                  const Text('No allocation data', style: TextStyle(color: Colors.black54))
                else
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: allocEntries.map<Widget>((e) {
                      final key = e.key;
                      final val = e.value;
                      return Chip(label: Text('$key: ${val.toStringAsFixed(0)}%'));
                    }).toList(),
                  ),
                const SizedBox(height: 12),
                Row(children: [
                  if (createdAt != null) Text('Created: ${DateFormat.yMMMd().add_jm().format(createdAt)}', style: const TextStyle(fontSize: 12, color: Colors.black54)),
                  const Spacer(),
                  if (updatedAt != null) Text('Updated: ${DateFormat.yMMMd().add_jm().format(updatedAt)}', style: const TextStyle(fontSize: 12, color: Colors.black54)),
                ]),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Close')),
            TextButton(
              onPressed: () async {
                Navigator.of(ctx).pop();
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (c2) => AlertDialog(
                    title: const Text('Confirm Delete'),
                    content: Text('Delete plan "$goalName"? This cannot be undone.'),
                    actions: [
                      TextButton(onPressed: () => Navigator.of(c2).pop(false), child: const Text('Cancel')),
                      FilledButton(onPressed: () => Navigator.of(c2).pop(true), child: const Text('Delete')),
                    ],
                  ),
                );
                if (confirm == true) {
                  try {
                    await _deletePlan(p['id'] as int);
                  } catch (e) {
                    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Delete failed: $e')));
                  }
                }
              },
              child: const Text('Delete', style: TextStyle(color: Colors.red)),
            ),
          ],
        );
      },
    );
  }

  // small helper widget used above
  Widget _detailTile(String label, String value) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(fontSize: 12, color: Colors.black54)),
      const SizedBox(height: 4),
      Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Investment Suggestion'),
        actions: [
          IconButton(onPressed: _loadSaved, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(12.0),
          child: Column(children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(children: [
                  TextFormField(controller: _goalCtl, decoration: const InputDecoration(labelText: 'Goal name (e.g., Retirement)')),
                  const SizedBox(height: 8),
                  TextFormField(controller: _targetCtl, decoration: const InputDecoration(labelText: 'Target amount'), keyboardType: TextInputType.number),
                  const SizedBox(height: 8),
                  TextFormField(controller: _horizonCtl, decoration: const InputDecoration(labelText: 'Horizon (months)'), keyboardType: TextInputType.number),
                  const SizedBox(height: 8),
                  Row(children: [
                    const Text('Risk profile: '),
                    const SizedBox(width: 8),
                    DropdownButton<String>(
                      value: _risk,
                      items: const [
                        DropdownMenuItem(value: 'LOW', child: Text('LOW')),
                        DropdownMenuItem(value: 'MEDIUM', child: Text('MEDIUM')),
                        DropdownMenuItem(value: 'HIGH', child: Text('HIGH')),
                      ],
                      onChanged: (v) => setState(() => _risk = v ?? 'MEDIUM'),
                    ),
                  ]),
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(child: FilledButton(onPressed: _previewCalc, child: const Text('Preview'))),
                  ]),
                ]),
              ),
            ),
            const SizedBox(height: 12),
            if (_preview != null) _previewCard(),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Saved Plans', style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  _saved.isEmpty
                      ? const Center(child: Text('No saved plans'))
                      : ListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: _saved.length,
                    itemBuilder: (ctx, i) {
                      final p = _saved[i];
                      final sipVal = (p['monthly_sip'] ?? p['monthlySip'] ?? p['monthly']) ?? 0.0;
                      final sipDisplay = NumberFormat.currency(symbol: '', decimalDigits: 2).format(sipVal);
                      final horizonVal = p['horizon_months'] ?? p['horizon'] ?? '';
                      final title = (p['goal_name'] ?? p['goal'] ?? '').toString();
                      final subtitle = 'SIP: $sipDisplay • Horizon: ${horizonVal}m';
                      return ListTile(
                        title: Text(title),
                        subtitle: Text(subtitle),
                        trailing: IconButton(icon: const Icon(Icons.delete), onPressed: () => _confirmAndDelete(p)),
                        onTap: () {
                          _showPlanDetails(p);
                        },
                      );
                    },
                  ),
                ]),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  void _confirmAndDelete(Map<String, dynamic> p) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Confirm delete'),
        content: Text('Delete plan "${p['goal_name'] ?? p['goal'] ?? ''}"?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(c).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(c).pop(true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirm == true) {
      try {
        await _deletePlan(p['id'] as int);
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Delete failed: $e')));
      }
    }
  }
}