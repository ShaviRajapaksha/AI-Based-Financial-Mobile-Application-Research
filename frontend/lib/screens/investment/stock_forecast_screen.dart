import 'dart:math';
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import '../../services/api_service.dart';

class StockForecastScreen extends StatefulWidget {
  const StockForecastScreen({super.key});
  @override
  State<StockForecastScreen> createState() => _StockForecastScreenState();
}

class _StockForecastScreenState extends State<StockForecastScreen> {
  final ApiService _api = ApiService();
  final _fileCtl = TextEditingController(text: 'COMB'); // default hint
  bool _loading = false;
  bool _forecasting = false;
  String? _error;

  int _horizon = 183; // default ~6 months
  List<Map<String, dynamic>> _preview = []; // history: {ds, y}
  List<Map<String, dynamic>> _predictions = []; // future: {ds, price}
  String? _method;
  bool _modelCached = false;

  @override
  void dispose() {
    _fileCtl.dispose();
    super.dispose();
  }

  Future<void> _previewDataset(String filename, {int n = 90}) async {
    setState(() {
      _loading = true;
      _error = null;
      _preview = [];
    });
    try {
      final res = await _api.previewStockDataset(filename, n: n);
      final rows = (res['preview'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
      setState(() {
        _preview = rows.map((r) => {'ds': r['ds'] as String, 'y': (r['y'] as num).toDouble()}).toList();
      });
    } catch (e) {
      setState(() {
        _error = 'Preview failed: $e';
        _preview = [];
      });
    } finally {
      setState(() {
        _loading = false;
      });
    }
  }

  Future<void> _runForecast() async {
    final raw = _fileCtl.text.trim();
    if (raw.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please enter CSV base name (e.g. COMB)')));
      return;
    }
    final filename = raw.toUpperCase().endsWith('.CSV') ? raw : '$raw.csv';

    setState(() {
      _forecasting = true;
      _error = null;
      _predictions = [];
      _method = null;
      _modelCached = false;
    });

    try {
      // preview first (best-effort)
      await _previewDataset(filename, n: 120);

      final res = await _api.forecastStock(
        filename: filename,
        futureDays: _horizon,
        // use moderate training defaults; backend may override if cached
        epochs: 40,
        timeStep: 60,
      );

      final preds = (res['predictions'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
      setState(() {
        _predictions = preds
            .map((p) => {
          'ds': p['ds'] as String,
          'y': (p['price'] as num).toDouble(),
        })
            .toList();
        _method = res['method']?.toString();
        _modelCached = res['model_cached'] == true;
      });
      // show short success
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Forecast completed')));
      }
    } catch (e, st) {
      debugPrint('Forecast error: $e\n$st');
      setState(() {
        _error = 'Forecast failed: $e';
        _predictions = [];
      });
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Forecast failed: $e')));
    } finally {
      setState(() {
        _forecasting = false;
      });
    }
  }

  // Build combined chart data (history + predictions)
  Widget _buildChart() {
    final history = _preview; // list of {ds,y}
    final preds = _predictions; // list of {ds,y}

    if (history.isEmpty && preds.isEmpty) return const SizedBox.shrink();

    final allLabels = <String>[];
    final histSpots = <FlSpot>[];
    final predSpots = <FlSpot>[];
    int idx = 0;
    for (final h in history) {
      histSpots.add(FlSpot(idx.toDouble(), (h['y'] as double)));
      allLabels.add(h['ds'] as String);
      idx++;
    }
    final histLen = idx;
    for (final p in preds) {
      predSpots.add(FlSpot(idx.toDouble(), (p['y'] as double)));
      allLabels.add(p['ds'] as String);
      idx++;
    }

    final ys = [
      ...histSpots.map((s) => s.y),
      ...predSpots.map((s) => s.y),
    ];
    final maxY = ys.isNotEmpty ? ys.reduce(max) : 1.0;
    final minY = ys.isNotEmpty ? ys.reduce((a, b) => a < b ? a : b) : 0.0;
    final top = (maxY * 1.2);
    final bottom = (minY * 0.8).clamp(0.0, minY);

    return SizedBox(
      height: 260,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(8.0),
          child: LineChart(
            LineChartData(
              minY: bottom,
              maxY: top,
              gridData: FlGridData(show: true),
              borderData: FlBorderData(show: true),
              lineBarsData: [
                if (histSpots.isNotEmpty)
                  LineChartBarData(
                    spots: histSpots,
                    isCurved: true,
                    barWidth: 2,
                    dotData: FlDotData(show: false),
                    belowBarData: BarAreaData(show: true),
                    color: Theme.of(context).colorScheme.primary,
                  ),
                if (predSpots.isNotEmpty)
                  LineChartBarData(
                    spots: predSpots,
                    isCurved: true,
                    barWidth: 2,
                    dotData: FlDotData(show: true),
                    belowBarData: BarAreaData(show: false),
                    color: Colors.green.shade400,
                    dashArray: [6, 4],
                  ),
              ],
              titlesData: FlTitlesData(
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 48,
                    interval: (top - bottom) / 4,
                    getTitlesWidget: (double value, TitleMeta meta) {
                      return Padding(
                        padding: const EdgeInsets.only(right: 6.0),
                        child: Text(value.toStringAsFixed(0), style: const TextStyle(fontSize: 10)),
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
                      final i = value.toInt();
                      if (i < 0 || i >= allLabels.length) return const SizedBox.shrink();
                      final label = allLabels[i];
                      final jump = (allLabels.length / 6).ceil();
                      if (i % jump != 0 && i < allLabels.length - 1) return const SizedBox.shrink();
                      // show MM-DD portion
                      final txt = label.length >= 10 ? label.substring(5) : label;
                      return Padding(padding: const EdgeInsets.only(top: 6.0), child: Text(txt, style: const TextStyle(fontSize: 10)));
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

  Widget _buildSummary() {
    if (_predictions.isEmpty) return const SizedBox.shrink();
    final lastPred = _predictions.last;
    final lastPrice = (lastPred['y'] as double);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Forecast (${_method ?? "auto"})', style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text('Predicted price (LKR) after $_horizon days: ${lastPrice.toStringAsFixed(2)}'),
          if (_modelCached) Padding(padding: const EdgeInsets.only(top: 6), child: Text('Note: used cached model', style: TextStyle(color: Colors.grey.shade700, fontSize: 12))),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Stock Forecast'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              final raw = _fileCtl.text.trim();
              if (raw.isEmpty) return;
              final filename = raw.toUpperCase().endsWith('.CSV') ? raw : '${raw.toUpperCase()}.csv';
              _previewDataset(filename, n: 120);
            },
          )
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(children: [
          Row(children: [
            Expanded(
              child: TextFormField(
                controller: _fileCtl,
                decoration: const InputDecoration(labelText: 'Stock name (e.g. COMB, HNB)'),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _forecasting ? null : () {
                final raw = _fileCtl.text.trim();
                if (raw.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please enter Stock name')));
                  return;
                }
                final filename = raw.toUpperCase().endsWith('.CSV') ? raw : '${raw.toUpperCase()}.csv';
                _previewDataset(filename, n: 120);
                _runForecast();
              },
              child: _forecasting ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Get Forecast'),
            )
          ]),
          const SizedBox(height: 12),
          Row(children: [
            const Text('Horizon (days):'),
            const SizedBox(width: 12),
            Expanded(
              child: Slider(
                value: _horizon.toDouble(),
                min: 30,
                max: 365,
                divisions: 335,
                label: '$_horizon',
                onChanged: (v) => setState(() => _horizon = v.round()),
              ),
            ),
            SizedBox(width: 56, child: Text('$_horizon', textAlign: TextAlign.center)),
          ]),
          if (_loading) const LinearProgressIndicator(),
          if (_error != null) Padding(padding: const EdgeInsets.all(8), child: Text(_error!, style: const TextStyle(color: Colors.red))),
          const SizedBox(height: 8),
          _buildSummary(),
          const SizedBox(height: 8),
          Expanded(
            child: _preview.isEmpty && _predictions.isEmpty
                ? Center(child: Text(_loading ? 'Loading...' : 'No data — preview or run forecast', style: TextStyle(color: Colors.grey.shade700)))
                : SingleChildScrollView(
                child: Column(
                  children: [
                    _buildChart(),
                    const SizedBox(height: 8),
                    if (_preview.isNotEmpty)
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(8.0),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            const Text('Recent History (preview)', style: TextStyle(fontWeight: FontWeight.w700)),
                            const SizedBox(height: 8),
                            SizedBox(
                              height: 140,
                              child: ListView.builder(
                                itemCount: _preview.length,
                                itemBuilder: (_, i) {
                                  final r = _preview[i];
                                  return ListTile(
                                    dense: true,
                                    visualDensity: VisualDensity.compact,
                                    title: Text(r['ds'] as String),
                                    trailing: Text((r['y'] as double).toStringAsFixed(2)),
                                  );
                                },
                              ),
                            )
                          ]),
                        ),
                      ),
                    if (_predictions.isNotEmpty)
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(8.0),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            const Text('Predictions', style: TextStyle(fontWeight: FontWeight.w700)),
                            const SizedBox(height: 8),
                            SizedBox(
                              height: 200,
                              child: ListView.builder(
                                itemCount: _predictions.length,
                                itemBuilder: (_, i) {
                                  final p = _predictions[i];
                                  return ListTile(
                                    dense: true,
                                    visualDensity: VisualDensity.compact,
                                    title: Text(p['ds'] as String),
                                    trailing: Text((p['y'] as double).toStringAsFixed(2)),
                                  );
                                },
                              ),
                            ),
                          ]),
                        ),
                      )
                  ],
                )),
          )
        ]),
      ),
    );
  }
}