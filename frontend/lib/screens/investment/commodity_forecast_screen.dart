import 'dart:math';
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import '../../services/api_service.dart';

class CommodityForecastScreen extends StatefulWidget {
  const CommodityForecastScreen({super.key});
  @override
  State<CommodityForecastScreen> createState() => _CommodityForecastScreenState();
}

class _CommodityForecastScreenState extends State<CommodityForecastScreen> {
  final ApiService _api = ApiService();
  final _symbolCtl = TextEditingController(text: 'GOLD');
  bool _loading = false;
  String? _error;
  Map<String, dynamic>? _result;
  int _horizon = 30;

  Future<void> _fetch() async {
    final sym = _symbolCtl.text.trim();
    if (sym.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
      _result = null;
    });
    try {
      final res = await _api.commodityForecast(sym);
      if (mounted) setState(() => _result = res);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _symbolCtl.dispose();
    super.dispose();
  }

  Widget _buildSummary() {
    if (_result == null) return const SizedBox.shrink();
    final pred = _result!['prediction'] as Map<String, dynamic>? ?? {};
    final yhat = pred['yhat'] as num?;
    final lower = pred['yhat_lower'] as num?;
    final upper = pred['yhat_upper'] as num?;
    final confidence = (pred['confidence'] as num?)?.toDouble() ?? 0.0;
    final method = pred['method'] ?? '';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Forecast (${method})', style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text('Predicted price (USD) in $_horizon days: ${yhat != null ? yhat.toStringAsFixed(2) : "-"}'),
          if (lower != null && upper != null) Text('Range: ${lower.toStringAsFixed(2)} — ${upper.toStringAsFixed(2)}'),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: LinearProgressIndicator(value: confidence.clamp(0.0, 1.0), minHeight: 8)),
            const SizedBox(width: 8),
            Text('${(confidence * 100).toStringAsFixed(0)}%'),
          ]),
        ]),
      ),
    );
  }

  Widget _buildChart() {
    if (_result == null) return const SizedBox.shrink();
    final recent = (_result!['recent'] as List<dynamic>? ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    if (recent.isEmpty) {
      return const Center(child: Text('No recent data'));
    }

    // convert recent data to FlSpot list
    final spots = <FlSpot>[];
    final labels = <String>[];
    for (var i = 0; i < recent.length; i++) {
      final r = recent[i];
      final y = (r['y'] as num).toDouble();
      spots.add(FlSpot(i.toDouble(), y));
      labels.add((r['ds'] as String).substring(5)); // "MM-DD"
    }

    final pred = _result!['prediction'] as Map<String, dynamic>?;
    bool hasPred = pred != null && pred['yhat'] != null;
    if (hasPred) {
      final yhat = (pred!['yhat'] as num).toDouble();
      spots.add(FlSpot(spots.length.toDouble(), yhat));
      labels.add('Next');
    }

    final ys = spots.map((p) => p.y).toList();
    final maxY = ys.isNotEmpty ? ys.reduce(max) : 1.0;
    final top = (maxY * 1.2).ceilToDouble();

    return SizedBox(
      height: 260,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(8.0),
          child: LineChart(
            LineChartData(
              minY: 0,
              maxY: top,
              gridData: FlGridData(show: true),
              borderData: FlBorderData(show: true),
              lineBarsData: [
                LineChartBarData(
                  spots: spots,
                  isCurved: true,
                  barWidth: 2,
                  dotData: FlDotData(show: true),
                  belowBarData: BarAreaData(show: true),
                ),
              ],
              titlesData: FlTitlesData(
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 48,
                    interval: top / 4,
                    // Use the modern signature (double value, TitleMeta meta)
                    getTitlesWidget: (double value, TitleMeta meta) {
                      final txt = value.toStringAsFixed(0);
                      return Padding(
                        padding: const EdgeInsets.only(right: 6.0),
                        child: Text(txt, style: const TextStyle(fontSize: 10)),
                      );
                    },
                  ),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 40,
                    interval: 1,
                    getTitlesWidget: (double value, TitleMeta meta) {
                      final idx = value.toInt();
                      if (idx < 0 || idx >= labels.length) {
                        return const Padding(padding: EdgeInsets.only(top: 6.0), child: Text(''));
                      }
                      final txt = labels[idx];
                      return Padding(
                        padding: const EdgeInsets.only(top: 6.0),
                        child: Text(txt, style: const TextStyle(fontSize: 10)),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Commodities Forecast'),
        actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _fetch)],
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(children: [
          Row(children: [
            Expanded(child: TextFormField(controller: _symbolCtl, decoration: const InputDecoration(labelText: 'Symbol (GOLD, OIL, WTI, BRENT or ticker)'))),
            const SizedBox(width: 8),
            FilledButton(onPressed: _fetch, child: _loading ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator()) : const Text('Get')),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            const Text('Horizon (days): '),
            Expanded(
              child: Slider(
                value: _horizon.toDouble(),
                min: 7,
                max: 90,
                divisions: 83,
                label: '$_horizon',
                onChanged: (v) => setState(() => _horizon = v.toInt()),
              ),
            ),
            Text('$_horizon days'),
          ]),
          const SizedBox(height: 8),
          if (_loading) const LinearProgressIndicator(),
          if (_error != null) Padding(padding: const EdgeInsets.all(8), child: Text('Error: $_error', style: const TextStyle(color: Colors.red))),
          const SizedBox(height: 8),
          _buildSummary(),
          const SizedBox(height: 8),
          Expanded(child: _buildChart()),
        ]),
      ),
    );
  }
}