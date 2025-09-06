import 'package:flutter/material.dart';
import '../../services/api_service.dart';
import 'dart:math';

class DebtPlanDetail extends StatefulWidget {
  final int planId;
  const DebtPlanDetail({required this.planId, super.key});
  @override
  State<DebtPlanDetail> createState() => _DebtPlanDetailState();
}

class _DebtPlanDetailState extends State<DebtPlanDetail> {
  final ApiService _api = ApiService();
  bool _loading = true;
  Map<String, dynamic>? _plan;
  Map<String, dynamic>? _scheduleData;
  double _extra = 0.0;
  double _overrideMonthly = 0.0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final res = await _api.get('/api/debt/plans/${widget.planId}');
      if (!mounted) return;
      setState(() {
        _plan = Map<String, dynamic>.from(res['plan'] ?? {});
        _scheduleData = Map<String, dynamic>.from(res['schedule'] ?? {});
      });
    } catch (e) {
      debugPrint('load plan failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Load failed: $e')));
    } finally {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _simulate() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final body = {
        "extra_payment": _extra,
        "override_monthly_payment": _overrideMonthly > 0 ? _overrideMonthly : null
      }..removeWhere((k, v) => v == null || (v is num && v <= 0));
      final res = await _api.post('/api/debt/plans/${widget.planId}/simulate', body: body);
      if (!mounted) return;
      setState(() {
        _scheduleData = Map<String, dynamic>.from(res['simulation'] ?? {});
      });
    } catch (e) {
      debugPrint('simulate failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Simulation failed: $e')));
    } finally {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Widget _buildSummary() {
    if (_plan == null || _scheduleData == null) return const SizedBox.shrink();

    final principalRaw = _plan!['principal'];
    final double principal = (principalRaw is num) ? principalRaw.toDouble() : double.tryParse(principalRaw?.toString() ?? '0') ?? 0.0;
    final months = (_scheduleData!['months'] is num) ? (_scheduleData!['months'] as num).toInt() : int.tryParse('${_scheduleData!['months']}') ?? 0;
    final payoffDate = _scheduleData!['payoff_date'] ?? '—';
    final totalInterest = (_scheduleData!['total_interest'] is num) ? (_scheduleData!['total_interest'] as num).toDouble() : double.tryParse('${_scheduleData!['total_interest']}') ?? 0.0;
    final totalPaid = (_scheduleData!['total_paid'] is num) ? (_scheduleData!['total_paid'] as num).toDouble() : double.tryParse('${_scheduleData!['total_paid']}') ?? 0.0;

    double lastBalance = principal;
    final sched = _scheduleData!['schedule'];
    if (sched is List && sched.isNotEmpty) {
      final last = sched.last;
      final balRaw = last is Map ? last['balance'] : null;
      lastBalance = (balRaw is num) ? balRaw.toDouble() : double.tryParse('${balRaw ?? principal}') ?? principal;
    }

    final double progress = principal > 0 ? min(1.0, (principal - lastBalance) / principal).clamp(0.0, 1.0) : 0.0;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_plan!['name'] ?? '', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          // FIX: Used a Wrap widget for responsive text layout
          Wrap(
            spacing: 8.0, // Horizontal space between items
            runSpacing: 4.0, // Vertical space between lines
            children: [
              Text('Payoff in ~ $months months'),
              const Text('•'),
              Text('Date: $payoffDate'),
            ],
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: progress),
          const SizedBox(height: 8),
          // FIX: Used a Wrap widget here as well for consistency
          Wrap(
            spacing: 8.0,
            runSpacing: 4.0,
            children: [
              Text('Total interest ≈ ${totalInterest.toStringAsFixed(2)}'),
              const Text('•'),
              Text('Total paid ≈ ${totalPaid.toStringAsFixed(2)}'),
            ],
          ),
        ]),
      ),
    );
  }

  Widget _buildSimulationControls() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(children: [
          Row(children: [
            const Text('Extra payment/mo:'), // Shortened for smaller screens
            const SizedBox(width: 10),
            Expanded(
              child: Slider(
                value: _extra,
                min: 0,
                max: 2000,
                divisions: 40,
                label: _extra.toStringAsFixed(0),
                onChanged: (v) => setState(() => _extra = v),
              ),
            ),
            Text(_extra.toStringAsFixed(0)),
          ]),
          Row(children: [
            const Text('Monthly payment:'), // Shortened for smaller screens
            const SizedBox(width: 10),
            // FIX: Replaced fixed-width SizedBox with Expanded
            Expanded(
              child: TextField(
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(hintText: 'e.g. 500'),
                onChanged: (v) => setState(() => _overrideMonthly = double.tryParse(v) ?? 0),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton(onPressed: _simulate, child: const Text('Simulate')),
          ]),
        ]),
      ),
    );
  }

  Widget _buildScheduleList() {
    if (_scheduleData == null) return const SizedBox.shrink();
    final rows = _scheduleData!['schedule'];
    if (rows == null || rows is! List || rows.isEmpty) return const Padding(padding: EdgeInsets.all(12), child: Text('Schedule not available'));

    return Card(
      clipBehavior: Clip.antiAlias, // Ensures content respects card's rounded corners
      child: Column(children: [
        const ListTile(title: Text('Amortization Schedule (First 12 Months)')),
        const Divider(height: 1),
        ...rows.take(12).map((r) {
          final date = r is Map ? r['date']?.toString() : '—';
          final payment = r is Map ? r['payment']?.toString() : '—';
          final interest = r is Map ? r['interest']?.toString() : '—';
          final principalPaid = r is Map ? r['principal']?.toString() : '—';
          final balance = r is Map ? r['balance']?.toString() : '—';
          return ListTile(
            dense: true,
            // FIX: Set isThreeLine to true to allow more vertical space for the subtitle
            isThreeLine: true,
            title: Text('$date: Payment $payment'),
            // FIX: Replaced single long Text with a Column for clarity and to prevent overflow
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Interest: $interest • Principal: $principalPaid'),
                Text('New Balance: $balance'),
              ],
            ),
          );
        }),
        if (rows.length > 12)
          Padding(
            padding: const EdgeInsets.all(12.0),
            child: Text('... and ${rows.length - 12} more months ...'),
          ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_plan != null ? (_plan!['name'] ?? 'Debt Plan') : 'Debt Plan'),
        actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _load)],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(children: [
            _buildSummary(),
            const SizedBox(height: 12),
            _buildSimulationControls(),
            const SizedBox(height: 12),
            _buildScheduleList(),
          ]),
        ),
      ),
    );
  }
}