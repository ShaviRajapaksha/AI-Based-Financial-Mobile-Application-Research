import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:fl_chart/fl_chart.dart'; // Import the new package

import '../providers/entry_provider.dart';
import '../main.dart'; // For routeObserver

class SummaryScreen extends StatefulWidget {
  const SummaryScreen({super.key});

  @override
  State<SummaryScreen> createState() => _SummaryScreenState();
}

class _SummaryScreenState extends State<SummaryScreen> with RouteAware {
  bool _loading = false;
  int _touchedIndex = -1; // For pie chart interactivity

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refresh();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    routeObserver.subscribe(this, ModalRoute.of(context)!);
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    super.dispose();
  }

  @override
  void didPopNext() {
    _refresh(); // Refresh data when returning to this screen
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    try {
      await context.read<EntryProvider>().refresh();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // --- Helper Methods for Data Processing ---

  double _safeAmount(dynamic e) {
    try {
      if (e is Map) return (e['amount'] ?? 0.0) as double;
      final v = e.amount;
      return v is int ? v.toDouble() : (v ?? 0.0);
    } catch (_) {
      return 0.0;
    }
  }

  String _entryTypeOf(dynamic e) {
    try {
      if (e is Map) return (e['entry_type'] ?? e['entryType'] ?? '').toString().toUpperCase();
      return (e.entryType ?? '').toString().toUpperCase();
    } catch (_) {
      return '';
    }
  }

  // --- UI Widget Builders ---

  /// Builds the top card showing the overall financial balance.
  Widget _buildNetBalanceCard(double netBalance, double totalIncome, double totalExpenses) {
    final theme = Theme.of(context);
    final isPositive = netBalance >= 0;

    return Card(
      elevation: 4,
      shadowColor: (isPositive ? Colors.green : Colors.red).withOpacity(0.2),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(
            colors: isPositive
                ? [Colors.green.shade600, Colors.green.shade400]
                : [Colors.red.shade600, Colors.red.shade400],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Net Balance',
              style: theme.textTheme.titleMedium?.copyWith(color: Colors.white70),
            ),
            const SizedBox(height: 8),
            Text(
              'LKR ${netBalance.toStringAsFixed(2)}',
              style: theme.textTheme.displaySmall?.copyWith(color: Colors.white, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _buildIncomeExpenseRow(Icons.arrow_upward, 'Income', totalIncome, Colors.white),
                _buildIncomeExpenseRow(Icons.arrow_downward, 'Expenses', totalExpenses, Colors.white),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Helper for the NetBalanceCard.
  Widget _buildIncomeExpenseRow(IconData icon, String label, double value, Color color) {
    return Row(
      children: [
        Icon(icon, color: color, size: 16),
        const SizedBox(width: 8),
        Text(
          '$label: ${value.toStringAsFixed(0)}',
          style: TextStyle(color: color, fontSize: 14),
        ),
      ],
    );
  }

  /// Builds the interactive Pie Chart.
  Widget _buildPieChart(Map<String, double> data, Map<String, Color> colors, double total) {
    if (total == 0) {
      return const Center(
        child: Text("No data to display.\nAdd some entries to see the summary.", textAlign: TextAlign.center),
      );
    }

    // UPDATED: Now includes all categories with a value > 0 for the chart.
    final chartData = data.entries
        .where((entry) => entry.value > 0)
        .toList();

    return AspectRatio(
      aspectRatio: 1.2,
      child: PieChart(
        PieChartData(
          pieTouchData: PieTouchData(
            touchCallback: (FlTouchEvent event, pieTouchResponse) {
              setState(() {
                if (!event.isInterestedForInteractions || pieTouchResponse == null || pieTouchResponse.touchedSection == null) {
                  _touchedIndex = -1;
                  return;
                }
                _touchedIndex = pieTouchResponse.touchedSection!.touchedSectionIndex;
              });
            },
          ),
          borderData: FlBorderData(show: false),
          sectionsSpace: 4,
          centerSpaceRadius: 60,
          sections: List.generate(chartData.length, (i) {
            final entry = chartData[i];
            final isTouched = i == _touchedIndex;
            final fontSize = isTouched ? 16.0 : 12.0;
            final radius = isTouched ? 90.0 : 80.0;
            final percentage = (entry.value / total * 100);

            return PieChartSectionData(
              color: colors[entry.key],
              value: entry.value,
              title: '${percentage.toStringAsFixed(1)}%',
              radius: radius,
              titleStyle: TextStyle(
                fontSize: fontSize,
                fontWeight: FontWeight.bold,
                color: Colors.white,
                shadows: [Shadow(color: Colors.black.withOpacity(0.5), blurRadius: 2)],
              ),
            );
          }),
        ),
      ),
    );
  }

  /// Builds the legend item for a category.
  Widget _buildLegendItem(String title, double value, Color color, double total) {
    final percentage = total > 0 ? (value / total * 100) : 0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        children: [
          Container(width: 16, height: 16, decoration: BoxDecoration(shape: BoxShape.circle, color: color)),
          const SizedBox(width: 12),
          Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const Spacer(),
          Text(
            'LKR ${value.toStringAsFixed(2)}',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 50,
            child: Text('(${percentage.toStringAsFixed(1)}%)', style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
          )
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final entries = context.watch<EntryProvider>().entries;
    double totalBy(String type) => entries.where((e) => _entryTypeOf(e) == type).fold(0.0, (sum, e) => sum + _safeAmount(e));

    final s = {
      'INCOME': totalBy('INCOME'),
      'SAVINGS': totalBy('SAVINGS'),
      'EXPENSES': totalBy('EXPENSES'),
      'INVESTMENTS': totalBy('INVESTMENTS'),
      'DEBT': totalBy('DEBT'),
    };

    // Define colors for each category
    final categoryColors = {
      'INCOME': Colors.green.shade500,
      'EXPENSES': Colors.red.shade400,
      'SAVINGS': Colors.blue.shade400,
      'INVESTMENTS': Colors.purple.shade400,
      'DEBT': Colors.orange.shade400,
    };

    // --- Calculations ---
    final totalIncomeForCard = s['INCOME']!;
    final totalExpensesForCard = s['EXPENSES']!;
    final netBalance = s['INCOME']! + s['SAVINGS']! - s['EXPENSES']!;

    // UPDATED: Calculate a grand total of all categories for the pie chart percentages.
    final grandTotal = s.values.fold(0.0, (sum, item) => sum + item);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Financial Summary'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // 1. Net Balance Card
            _buildNetBalanceCard(netBalance, totalIncomeForCard, totalExpensesForCard),
            const SizedBox(height: 24),

            // 2. Pie Chart
            Text('Financial Overview', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            // UPDATED: Pass the new grandTotal to the pie chart.
            _buildPieChart(s, categoryColors, grandTotal),
            const SizedBox(height: 24),

            // 3. Legend
            // UPDATED: All legend items now use grandTotal for consistent percentages.
            _buildLegendItem('Income', s['INCOME']!, categoryColors['INCOME']!, grandTotal),
            const Divider(),
            _buildLegendItem('Expenses', s['EXPENSES']!, categoryColors['EXPENSES']!, grandTotal),
            _buildLegendItem('Savings', s['SAVINGS']!, categoryColors['SAVINGS']!, grandTotal),
            _buildLegendItem('Investments', s['INVESTMENTS']!, categoryColors['INVESTMENTS']!, grandTotal),
            _buildLegendItem('Debt', s['DEBT']!, categoryColors['DEBT']!, grandTotal),
          ],
        ),
      ),
    );
  }
}