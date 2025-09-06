import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'; // <-- required for RenderRepaintBoundary
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdf/pdf.dart';

import '../../services/api_service.dart';

/// Savings Report Screen:
/// - shows cumulative saved vs target chart (LineChart)
/// - allows exporting a PDF report (chart + contributions table)
class SavingsReportScreen extends StatefulWidget {
  const SavingsReportScreen({super.key});

  @override
  State<SavingsReportScreen> createState() => _SavingsReportScreenState();
}

class _SavingsReportScreenState extends State<SavingsReportScreen> {
  final ApiService _api = ApiService();
  bool _loading = true;
  bool _exporting = false;

  // Chart capture key
  final GlobalKey _chartKey = GlobalKey();

  // Data structures
  List<Map<String, dynamic>> _goals = [];
  Map<String, dynamic>? _selectedGoal;

  // computed chart arrays
  List<DateTime> _dates = [];
  List<double> _cumulative = [];
  double _targetAmount = 0.0;
  String _goalName = '';

  @override
  void initState() {
    super.initState();
    _loadGoals();
  }

  Future<void> _loadGoals() async {
    setState(() => _loading = true);
    try {
      // Attempt to load goals via API (expects GET /api/expense/goals)
      final res = await _api.get('/api/expense/goals');
      // The backend may return a List or Map — handle both
      List<Map<String, dynamic>> list;
      if (res is List) {
        list = (res as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      } else if (res is Map && res['items'] != null && res['items'] is List) {
        list = (res['items'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      } else {
        // fallback empty
        list = [];
      }

      // If nothing from API, create a demo goal (so chart still renders)
      if (list.isEmpty) {
        list = [
          {
            "id": 1,
            "name": "Demo Goal: New Fridge",
            "target_amount": 100000.0,
            "progress": {"total_saved": 25000.0},
            "contributions": [
              {"date": DateTime.now().subtract(const Duration(days: 90)).toIso8601String(), "amount": 5000.0},
              {"date": DateTime.now().subtract(const Duration(days: 60)).toIso8601String(), "amount": 7000.0},
              {"date": DateTime.now().subtract(const Duration(days: 30)).toIso8601String(), "amount": 5000.0},
              {"date": DateTime.now().subtract(const Duration(days: 5)).toIso8601String(), "amount": 8000.0}
            ]
          }
        ];
      }

      setState(() {
        _goals = list;
        _selectedGoal = _goals.first;
      });

      _prepareChartData();
    } catch (e) {
      debugPrint('Load goals failed: $e');
      // fallback demo
      setState(() {
        _goals = [];
        _selectedGoal = null;
      });
    } finally {
      setState(() => _loading = false);
    }
  }

  void _prepareChartData() {
    final goal = _selectedGoal;
    if (goal == null) {
      _dates = [];
      _cumulative = [];
      _targetAmount = 0.0;
      _goalName = '';
      return;
    }

    _goalName = goal['name']?.toString() ?? 'Goal';
    _targetAmount = (goal['target_amount'] is num) ? (goal['target_amount'] as num).toDouble() : (goal['target_amount'] != null ? double.tryParse(goal['target_amount'].toString()) ?? 0.0 : 0.0);

    // contributions: try multiple common field names used by different backends
    final contribsRaw = (goal['contributions'] ?? goal['recent_contribs'] ?? goal['contribs'] ?? []) as List<dynamic>;

    // parse contributions (date, amount)
    final List<Map<String, dynamic>> contribs = [];
    for (var c in contribsRaw) {
      try {
        final dStr = c['date'] ?? c['contrib_date'] ?? c['created_at'] ?? c['datetime'];
        DateTime dt;
        if (dStr is DateTime) {
          dt = dStr;
        } else {
          dt = DateTime.parse(dStr.toString());
        }
        final amount = (c['amount'] is num) ? (c['amount'] as num).toDouble() : double.tryParse(c['amount'].toString()) ?? 0.0;
        contribs.add({"date": dt, "amount": amount});
      } catch (e) {
        debugPrint('Skipping invalid contrib row: $e — $c');
      }
    }

    // If no contributions included, but progress exists, create a single point
    if (contribs.isEmpty) {
      final totalSaved = (goal['progress'] != null && (goal['progress']['total_saved'] is num)) ? (goal['progress']['total_saved'] as num).toDouble() : (goal['progress']?['total_saved'] != null ? double.tryParse(goal['progress']['total_saved'].toString()) ?? 0.0 : 0.0);
      final createdAt = DateTime.now().subtract(const Duration(days: 60));
      if (totalSaved > 0) contribs.add({"date": createdAt, "amount": totalSaved});
    }

    // sort ascending
    contribs.sort((a, b) => (a['date'] as DateTime).compareTo(b['date'] as DateTime));

    // Build dates (one per contribution and also include start & today for better chart)
    final Set<DateTime> dateSet = {};
    if (contribs.isNotEmpty) {
      final start = contribs.first['date'] as DateTime;
      dateSet.add(start);
      for (var c in contribs) dateSet.add((c['date'] as DateTime).toLocal());
      dateSet.add(DateTime.now());
    } else {
      dateSet.add(DateTime.now().subtract(const Duration(days: 90)));
      dateSet.add(DateTime.now());
    }

    final dates = dateSet.toList()..sort();
    final List<double> cumulative = List.generate(dates.length, (_) => 0.0);

    double running = 0.0;
    int ci = 0;
    for (int i = 0; i < dates.length; ++i) {
      final dt = dates[i];
      // accumulate contributions occurring on or before this date
      while (ci < contribs.length && (contribs[ci]['date'] as DateTime).compareTo(dt) <= 0) {
        running += contribs[ci]['amount'] as double;
        ci++;
      }
      cumulative[i] = running;
    }

    setState(() {
      _dates = dates;
      _cumulative = cumulative;
    });
  }

  // Chart widget
  Widget _buildChart() {
    if (_dates.isEmpty || _cumulative.isEmpty) {
      return SizedBox(
        height: 260,
        child: Center(child: Text('No contributions to chart for "${_goalName}"')),
      );
    }

    final n = _dates.length;
    // FlSpots use x as index
    final spotsSaved = List.generate(n, (i) => FlSpot(i.toDouble(), _cumulative[i]));
    // build target line: linear interpolation from 0 to target amount across indices
    final spotsTarget = List.generate(n, (i) {
      final t = (_targetAmount) * (i / (n - 1 > 0 ? (n - 1) : 1));
      return FlSpot(i.toDouble(), t);
    });

    // compute left axis interval defensively
    double leftInterval = 1.0;
    final maxYCandidate = (_targetAmount > 0) ? (_targetAmount * 1.1) : ((_cumulative.isNotEmpty ? _cumulative.last : 0.0) * 1.2 + 10);
    if (maxYCandidate > 0) {
      leftInterval = (maxYCandidate / 4).clamp(1.0, maxYCandidate);
    }

    return RepaintBoundary(
      key: _chartKey,
      child: SizedBox(
        height: 280,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
          child: LineChart(
            LineChartData(
              minY: 0,
              maxY: maxYCandidate,
              gridData: FlGridData(show: true, drawVerticalLine: false),
              titlesData: FlTitlesData(
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 56,
                    interval: leftInterval,
                    getTitlesWidget: (val, meta) {
                      final fmt = NumberFormat.compactCurrency(symbol: 'LKR ', decimalDigits: 0);
                      return SideTitleWidget(meta: meta, child: Text(fmt.format(val), style: const TextStyle(fontSize: 11)));
                    },
                  ),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 36,
                    interval: (n / 5).ceilToDouble(),
                    getTitlesWidget: (val, meta) {
                      final idx = val.toInt().clamp(0, _dates.length - 1);
                      final dt = _dates[idx];
                      final fmt = DateFormat.MMMd();
                      return SideTitleWidget(meta: meta, child: Text(fmt.format(dt), style: const TextStyle(fontSize: 10)));
                    },
                  ),
                ),
                rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
              ),
              lineBarsData: [
                // Saved line
                LineChartBarData(
                  spots: spotsSaved,
                  isCurved: true,
                  barWidth: 3,
                  dotData: FlDotData(show: true),
                  belowBarData: BarAreaData(show: true, gradient: LinearGradient(colors: [Colors.green.withOpacity(0.2), Colors.green.withOpacity(0.05)], begin: Alignment.topCenter, end: Alignment.bottomCenter)),
                  color: Colors.green.shade700,
                ),
                // Target line (dashed)
                LineChartBarData(
                  spots: spotsTarget,
                  isCurved: false,
                  color: Colors.blueGrey,
                  barWidth: 2,
                  dashArray: [6, 4],
                  dotData: FlDotData(show: false),
                ),
              ],
              borderData: FlBorderData(show: true),
            ),
          ),
        ),
      ),
    );
  }

  Future<Uint8List?> _captureChartAsPngBytes() async {
    try {
      final boundary = _chartKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) return null;
      final ui.Image image = await boundary.toImage(pixelRatio: 3.0);
      final ByteData? byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      return byteData?.buffer.asUint8List();
    } catch (e) {
      debugPrint('Chart capture failed: $e');
      return null;
    }
  }

  Future<void> _exportPdfReport() async {
    setState(() => _exporting = true);
    try {
      final chartBytes = await _captureChartAsPngBytes();

      // Build a PDF
      final pdf = pw.Document();
      final dateFmt = DateFormat.yMMMMd();
      final createdAt = DateTime.now();

      // Header page
      pdf.addPage(pw.Page(
        pageFormat: PdfPageFormat.a4,
        build: (pw.Context ctx) {
          return pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text('Savings Report', style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 6),
            pw.Text('Goal: ${_goalName}', style: pw.TextStyle(fontSize: 14)),
            pw.Text('Generated: ${dateFmt.format(createdAt)}', style: pw.TextStyle(fontSize: 10, color: PdfColors.grey)),
            pw.SizedBox(height: 12),
            if (chartBytes != null) pw.Center(child: pw.Image(pw.MemoryImage(chartBytes), width: 500, height: 240)),
            pw.SizedBox(height: 10),
            pw.Text('Summary:', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
            pw.Bullet(text: 'Target amount: ${_targetAmount.toStringAsFixed(2)}'),
            pw.Bullet(text: 'Current saved: ${_cumulative.isNotEmpty ? _cumulative.last.toStringAsFixed(2) : '0.0'}'),
            pw.Bullet(text: 'Progress: ${_targetAmount > 0 ? ((_cumulative.isNotEmpty ? _cumulative.last / _targetAmount * 100 : 0.0).toStringAsFixed(1)) : 'N/A'}%'),
          ]);
        },
      ));

      // Contributions table page
      List<Map<String, dynamic>> contribRows = [];
      final rawContribs = (_selectedGoal?['contributions'] ?? _selectedGoal?['recent_contribs'] ?? []) as List<dynamic>;
      for (var c in rawContribs) {
        try {
          final dStr = c['date'] ?? c['contrib_date'] ?? c['created_at'];
          final dt = dStr is DateTime ? dStr : DateTime.parse(dStr.toString());
          final amt = (c['amount'] is num) ? (c['amount'] as num).toDouble() : double.tryParse(c['amount'].toString()) ?? 0.0;
          contribRows.add({"date": dt, "amount": amt, "notes": c['notes'] ?? ''});
        } catch (e) {
          // ignore parse errors
        }
      }

      // If no individual rows, attempt reconstruct from cumulative differences
      if (contribRows.isEmpty && _dates.isNotEmpty && _cumulative.isNotEmpty) {
        double prev = 0.0;
        for (int i = 0; i < _dates.length; i++) {
          final date = _dates[i];
          final curr = _cumulative[i];
          final delta = curr - prev;
          if (delta > 0.0) {
            contribRows.add({"date": date, "amount": delta, "notes": ""});
          }
          prev = curr;
        }
      }

      pdf.addPage(pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        build: (pw.Context ctx) {
          return [
            pw.Text('Contributions', style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 8),
            if (contribRows.isEmpty)
              pw.Text('No contribution rows available.')
            else
              pw.Table.fromTextArray(
                headers: ['Date', 'Amount', 'Notes'],
                data: contribRows.map((r) => [DateFormat.yMMMd().format(r['date'] as DateTime), r['amount'].toStringAsFixed(2), (r['notes'] ?? '')]).toList(),
                headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                cellAlignment: pw.Alignment.centerLeft,
                columnWidths: {0: pw.FlexColumnWidth(2), 1: pw.FlexColumnWidth(1), 2: pw.FlexColumnWidth(3)},
              ),
            pw.SizedBox(height: 10),
            pw.Text('Notes and recommendations:', style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
            pw.Paragraph(text: 'This report shows cumulative saved vs the target for the selected goal. Use this for tracking progress and sharing with advisors.'),
          ];
        },
      ));

      // Save PDF to file
      final appDoc = await getApplicationDocumentsDirectory();
      final filename = 'savings_report_${DateTime.now().millisecondsSinceEpoch}.pdf';
      final outFile = File('${appDoc.path}/$filename');
      await outFile.writeAsBytes(await pdf.save());

      // Open the PDF
      await OpenFilex.open(outFile.path);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Report generated and opened')));
      }
    } catch (e) {
      debugPrint('Export failed: $e');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Export failed: $e')));
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final curSaved = _cumulative.isNotEmpty ? _cumulative.last : 0.0;
    final percent = (_targetAmount > 0) ? (curSaved / _targetAmount * 100.0).clamp(0.0, 1000.0) : 0.0;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Savings Report'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _loadGoals),
          IconButton(
            icon: _exporting ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.picture_as_pdf),
            onPressed: (_exporting || _loading) ? null : _exportPdfReport,
            tooltip: 'Export PDF',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Goal selector
          Row(children: [
            const Text('Goal:', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(width: 12),
            DropdownButton<Map<String, dynamic>>(
              value: _selectedGoal,
              items: _goals.map((g) => DropdownMenuItem(value: g, child: Text(g['name'] ?? 'Goal ${g['id']}'))).toList(),
              onChanged: (v) {
                setState(() {
                  _selectedGoal = v;
                  _prepareChartData();
                });
              },
            ),
            const Spacer(),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text('Saved: ${curSaved.toStringAsFixed(2)}'),
              Text('Target: ${_targetAmount.toStringAsFixed(2)}'),
              Text('${percent.toStringAsFixed(1)}%'),
            ])
          ]),
          const SizedBox(height: 10),
          // Chart area
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(padding: const EdgeInsets.all(8.0), child: Column(children: [
              Row(children: [const SizedBox(width: 8), Text(_goalName, style: const TextStyle(fontWeight: FontWeight.w700)), const Spacer(), Text('Progress: ${percent.toStringAsFixed(1)}%')]),
              _buildChart(),
            ])),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: Card(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Contributions', style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  Expanded(
                    child: _buildContributionsList(),
                  )
                ]),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _buildContributionsList() {
    final rawContribs = (_selectedGoal?['contributions'] ?? _selectedGoal?['recent_contribs'] ?? []) as List<dynamic>;
    final List<Map<String, dynamic>> rows = [];
    for (var c in rawContribs) {
      try {
        final dStr = c['date'] ?? c['contrib_date'] ?? c['created_at'];
        final dt = dStr is DateTime ? dStr : DateTime.parse(dStr.toString());
        final amt = (c['amount'] is num) ? (c['amount'] as num).toDouble() : double.tryParse(c['amount'].toString()) ?? 0.0;
        rows.add({'date': dt, 'amount': amt, 'notes': c['notes'] ?? ''});
      } catch (e) {
        // ignore parse errors
      }
    }
    // fallback reconstruct from chart
    if (rows.isEmpty && _dates.isNotEmpty) {
      double prev = 0.0;
      for (int i = 0; i < _dates.length; i++) {
        final dt = _dates[i];
        final curr = _cumulative[i];
        final delta = curr - prev;
        if (delta > 0.0001) rows.add({'date': dt, 'amount': delta, 'notes': ''});
        prev = curr;
      }
    }

    if (rows.isEmpty) {
      return const Center(child: Text('No contributions found.'));
    }
    rows.sort((a, b) => (b['date'] as DateTime).compareTo(a['date'] as DateTime));

    return ListView.separated(
      itemCount: rows.length,
      separatorBuilder: (_, __) => const Divider(height: 8),
      itemBuilder: (_, i) {
        final r = rows[i];
        return ListTile(
          dense: true,
          leading: CircleAvatar(child: Text(DateFormat.MMMd().format(r['date'] as DateTime).split(' ')[0])),
          title: Text('Rs. ${r['amount'].toStringAsFixed(2)}'),
          subtitle: Text(DateFormat.yMMMd().format(r['date'] as DateTime)),
          trailing: Text(r['notes'] ?? ''),
        );
      },
    );
  }
}