import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:provider/provider.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:printing/printing.dart';
import 'package:pdf/widgets.dart' as pw;

import '../services/api_service.dart';
import '../services/auth_service.dart';

import 'debt/debt_home.dart';
import 'investment/investment_home.dart';
import 'savings/cost_savings_home.dart';



class ForecastScreen extends StatefulWidget {
  const ForecastScreen({super.key});

  @override
  State<ForecastScreen> createState() => _ForecastScreenState();
}

class _ForecastScreenState extends State<ForecastScreen> {
  final ApiService _api = ApiService();
  bool _loading = true;
  String? _error;
  Map<String, dynamic>? _prediction;
  List<Map<String, dynamic>> _series = [];
  bool _busyRetrain = false;

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  Future<void> _loadAll() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final user = AuthService.user;
      if (user == null) throw Exception('Not logged in');
      final uid = user['id'] as int;
      final pred = await _api.getMoneyInHandForecast(uid);
      List<Map<String, dynamic>> series = [];
      try {
        series = await _api.getMonthlySeries(uid);
      } catch (_) {
        // If monthly_series endpoint missing or fails, keep series empty (UI still shows prediction)
        series = [];
      }
      if (!mounted) return;
      setState(() {
        _prediction = pred;
        _series = series;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _triggerRetrain() async {
    setState(() => _busyRetrain = true);
    try {
      final user = AuthService.user!;
      final uid = user['id'] as int;
      await _api.retrainUserModel(uid);
      // schedule a reload after a short delay to allow the background job to run
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Retrain scheduled — reloading in a few seconds.')));
      await Future.delayed(const Duration(seconds: 4));
      await _loadAll();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Retrain failed: $e')));
    } finally {
      if (mounted) setState(() => _busyRetrain = false);
    }
  }

  // Build a fl_chart histogram: historical months (bars) + forecast bar (highlighted)
  Widget _buildChart(BuildContext ctx) {
    if (_series.isEmpty) {
      return Container(
        height: 200,
        alignment: Alignment.center,
        child: const Text('No historical data available to plot.'),
      );
    }

    final df = _series
        .map((r) => MapEntry(DateTime.parse(r['ds'] as String), (r['y'] as num).toDouble()))
        .toList();

    // sort
    df.sort((a, b) => a.key.compareTo(b.key));

    // create X positions: allow ticks to be DateTime or String('Next')
    final ticks = <dynamic>[];
    final values = <double>[];
    for (var e in df) {
      ticks.add(e.key);
      values.add(e.value);
    }

    // compute abs max for y axis scaling
    final double maxAbsVal = values.isEmpty ? 1.0 : values.map((v) => v.abs()).reduce(max);

    double yMax = maxAbsVal * 1.6 + 1.0;

    final barGroups = <BarChartGroupData>[];
    for (var i = 0; i < values.length; i++) {
      final v = values[i];
      barGroups.add(BarChartGroupData(
        x: i,
        barRods: [
          BarChartRodData(
            toY: v,
            width: 12,
            borderRadius: BorderRadius.circular(6),
            color: v >= 0 ? Colors.blueAccent : Colors.orangeAccent,
          )
        ],
      ));
    }

    // Add forecast bar if available; label its tick as 'Next'
    if (_prediction != null && (_prediction!['predicted_net_flow_next_month'] != null)) {
      final predictedNet = (_prediction!['predicted_net_flow_next_month'] as num).toDouble();

      // Ensure yMax can fit the forecast
      final absPred = predictedNet.abs();
      if (absPred > maxAbsVal) {
        yMax = absPred * 1.6 + 1.0;
      }

      barGroups.add(BarChartGroupData(
        x: values.length,
        barRods: [
          BarChartRodData(
            toY: predictedNet,
            width: 14,
            borderRadius: BorderRadius.circular(6),
            color: Colors.green.shade400,
          )
        ],
      ));
      ticks.add('Next'); // <<< label for the forecast bar
    }

    return SizedBox(
      height: 240,
      child: Card(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: BarChart(
            BarChartData(
              maxY: yMax,
              minY: -yMax,
              alignment: BarChartAlignment.spaceAround,
              barGroups: barGroups,
              gridData: FlGridData(show: true),
              titlesData: FlTitlesData(
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 50,
                    getTitlesWidget: (v, meta) {
                      return Text(v.toStringAsFixed(0));
                    },
                  ),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    getTitlesWidget: (val, meta) {
                      final idx = val.toInt();
                      if (idx < 0 || idx >= ticks.length) return const SizedBox.shrink();
                      final tick = ticks[idx];
                      if (tick is String) {
                        // forecast label
                        return Padding(
                          padding: const EdgeInsets.only(top: 6.0),
                          child: Text(tick, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                        );
                      } else if (tick is DateTime) {
                        final label = DateFormat.MMM().format(tick);
                        return Padding(
                          padding: const EdgeInsets.only(top: 6.0),
                          child: Text(label, style: const TextStyle(fontSize: 12)),
                        );
                      } else {
                        return const SizedBox.shrink();
                      }
                    },
                    reservedSize: 28,
                    interval: 1,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // Build the summary card with predicted money in hand
  Widget _buildSummaryCard(BuildContext ctx) {
    if (_prediction == null) {
      return const SizedBox.shrink();
    }
    final pred = _prediction!;
    final predictedMoney = (pred['predicted_money_in_hand_next_month'] as num?)?.toDouble();
    final predictedNetFlow = (pred['predicted_net_flow_next_month'] as num?)?.toDouble();
    final lower = (pred['predicted_money_lower'] as num?)?.toDouble();
    final upper = (pred['predicted_money_upper'] as num?)?.toDouble();
    final confidence = (pred['confidence'] as num?)?.toDouble() ?? 0.0;
    final modelUsed = pred['model_used']?.toString() ?? '';

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            CircleAvatar(backgroundColor: Colors.green.shade600, child: const Icon(Icons.savings, color: Colors.white)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Projected Money in Hand (next month)', style: TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text('Model: $modelUsed', style: const TextStyle(fontSize: 12, color: Colors.black54)),
              ]),
            ),
            FilledButton.icon(
              onPressed: _busyRetrain ? null : _triggerRetrain,
              icon: _busyRetrain ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.refresh),
              label: const Text('Adapt'),
            ),
          ]),
          const SizedBox(height: 12),
          if (predictedMoney != null)
            Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(NumberFormat.currency(symbol: '', decimalDigits: 2).format(predictedMoney), style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
              const SizedBox(width: 8),
              Text('LKR', style: const TextStyle(color: Colors.black54)),
            ]),
          const SizedBox(height: 10),
          Text('Predicted net flow next month: ${predictedNetFlow != null ? predictedNetFlow.toStringAsFixed(2) : '-'}'),
          const SizedBox(height: 6),
          Text('Range: ${lower?.toStringAsFixed(2) ?? '-'} — ${upper?.toStringAsFixed(2) ?? '-'}', style: const TextStyle(color: Colors.black54)),
          const SizedBox(height: 12),
          // Confidence meter
          Row(children: [
            Expanded(
              child: LinearProgressIndicator(value: confidence.clamp(0.0, 0.99), minHeight: 10, backgroundColor: Colors.grey.shade200, color: Colors.teal),
            ),
            const SizedBox(width: 12),
            Text('${(confidence * 100).toStringAsFixed(0)}%', style: const TextStyle(fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 8),
          Text('Confidence', style: const TextStyle(fontSize: 12, color: Colors.black54)),
        ]),
      ),
    );
  }

  // Build a PDF report using pdf (pw)
  Future<Uint8List> _buildPdfBytes() async {
    final pdf = pw.Document();
    final now = DateTime.now();
    final df = DateFormat.yMMMM().format(now);

    // Header summary data
    final pred = _prediction;
    final predictedMoney = pred?['predicted_money_in_hand_next_month'];
    final predictedNet = pred?['predicted_net_flow_next_month'];
    final confidence = (pred?['confidence'] as num?)?.toDouble() ?? 0.0;

    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        build: (pw.Context pwCtx) {
          return pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
            pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
              pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
                pw.Text('Money-in-Hand Forecast', style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold)),
                pw.SizedBox(height: 6),
                pw.Text('For: $df', style: pw.TextStyle(fontSize: 12)),
              ]),
              pw.Text('Generated: ${DateFormat.yMd().add_jm().format(now)}', style: pw.TextStyle(fontSize: 10)),
            ]),
            pw.SizedBox(height: 14),
            pw.Container(
              padding: const pw.EdgeInsets.all(10),
              decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.grey300)),
              child: pw.Column(children: [
                pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
                  pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
                    pw.Text('Predicted money in hand (next month)', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
                    pw.SizedBox(height: 6),
                    pw.Text(predictedMoney != null ? predictedMoney.toStringAsFixed(2) : '-', style: pw.TextStyle(fontSize: 18)),
                  ]),
                  pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
                    pw.Text('Predicted net flow', style: pw.TextStyle(fontSize: 12, color: PdfColors.grey600)),
                    pw.Text(predictedNet != null ? predictedNet.toStringAsFixed(2) : '-', style: pw.TextStyle(fontSize: 16)),
                  ]),
                ]),
                pw.SizedBox(height: 10),
                pw.Row(children: [
                  pw.Text('Confidence: ${(confidence * 100).toStringAsFixed(0)}%', style: pw.TextStyle(color: PdfColors.grey700)),
                ]),
              ]),
            ),
            pw.SizedBox(height: 14),
            pw.Text('Monthly Net Flow (recent months)', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 10),
            // Table of monthly data
            if (_series.isNotEmpty)
              pw.Table.fromTextArray(
                headers: ['Month', 'Net Flow'],
                data: _series.map((r) {
                  final ds = r['ds'] as String;
                  final mm = DateFormat.yMMM().format(DateTime.parse(ds));
                  final y = (r['y'] as num).toDouble();
                  return [mm, y.toStringAsFixed(2)];
                }).toList(),
                headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                cellAlignment: pw.Alignment.centerLeft,
              )
            else
              pw.Text('No historical monthly data available.', style: pw.TextStyle(color: PdfColors.grey600)),
          ]);
        },
      ),
    );

    return pdf.save();
  }

  Future<void> _generateAndPreviewPdf() async {
    try {
      final bytes = await _buildPdfBytes();
      await Printing.layoutPdf(onLayout: (format) => bytes);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('PDF generation failed: $e')));
    }
  }

  /// Builds the suggestions card based on prediction results
  Widget _buildSuggestionsCard(BuildContext context) {
    final predictedMoney = (_prediction?['predicted_money_in_hand_next_month'] as num?)?.toDouble();

    if (predictedMoney == null) {
      return const SizedBox.shrink(); // Don't show card if no prediction
    }

    String title = '';
    String suggestion = '';
    List<Widget> actions = [];

    // Define suggestions based on prediction
    if (predictedMoney >= 500000) {
      title = 'Excellent Outlook!';
      suggestion = 'Your projected cash flow is strong. This could be a great time to consider investment opportunities to grow your capital.';
      actions.add(
        ElevatedButton.icon(
          icon: const Icon(Icons.trending_up),
          label: const Text('Explore Investments'),
          onPressed: () {
            // Navigate to InvestmentHome
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const InvestmentHome()),
            );
          },
        ),
      );
    } else if (predictedMoney < -10000) {
      title = 'Action Recommended!';
      suggestion = 'Your projected cash flow is negative. It is highly recommended to look into debt management strategies and ways to reduce expenses.';
      actions.addAll([
        ElevatedButton.icon(
          icon: const Icon(Icons.credit_card_off),
          label: const Text('Debt Management'),
          style: ElevatedButton.styleFrom(backgroundColor: Colors.orange.shade700, foregroundColor: Colors.white),
          onPressed: () {
            // Navigate to DebtHome
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const DebtHome()),
            );
          },
        ),
        // No SizedBox needed here, 'spacing' property of Wrap handles it.
        ElevatedButton.icon(
          icon: const Icon(Icons.cut),
          label: const Text('Reduce Expenses'),
          onPressed: () {
            // Navigate to CostSavingsHome
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const CostSavingsHome()),
            );
          },
        ),
      ]);
    } else if (predictedMoney < 0) {
      title = 'Caution Advised!';
      suggestion = 'Your projected cash flow is slightly negative. Consider looking for ways to reduce expenses to improve your financial position.';
      actions.add(
        ElevatedButton.icon(
          icon: const Icon(Icons.cut),
          label: const Text('Reduce Expenses'),
          onPressed: () {
            // Navigate to CostSavingsHome
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const CostSavingsHome()),
            );
          },
        ),
      );
    }

    // If no specific suggestion is triggered, don't build the card.
    if (actions.isEmpty) {
      return const SizedBox.shrink();
    }

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      color: Colors.blue.shade50,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('💡 $title', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(suggestion),
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.end, // Aligns buttons to the right
              spacing: 8.0,                // Horizontal space between buttons
              runSpacing: 8.0,               // Vertical space if buttons wrap
              children: actions,
            )
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Forecast & Report'),
        actions: [
          IconButton(
            icon: const Icon(Icons.picture_as_pdf),
            onPressed: (_loading || _prediction == null) ? null : _generateAndPreviewPdf,
            tooltip: 'Generate PDF report',
          ),
          IconButton(icon: const Icon(Icons.refresh), onPressed: _loadAll),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(child: Text('Error: $_error'))
          : SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(children: [
          _buildSummaryCard(context),
          const SizedBox(height: 12),
          _buildChart(context),
          const SizedBox(height: 12),
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const Text('Details & Actions', style: TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                Text('Model used: ${_prediction?['model_used'] ?? 'n/a'}'),
                const SizedBox(height: 6),
                Text('Confidence: ${((_prediction?['confidence'] ?? 0.0) as num).toDouble().toStringAsFixed(2)}'),
                const SizedBox(height: 12),
                Row(children: [
                  const SizedBox(width: 12),
                ]),
              ]),
            ),
          ),
          const SizedBox(height: 12), // Added spacing
          // --- SUGGESTIONS CARD ---
          _buildSuggestionsCard(context),
          const SizedBox(height: 28),
        ]),
      ),
    );
  }
}