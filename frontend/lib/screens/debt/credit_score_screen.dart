import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../services/api_service.dart';

class CreditScoreScreen extends StatefulWidget {
  const CreditScoreScreen({super.key});
  @override
  State<CreditScoreScreen> createState() => _CreditScoreScreenState();
}

class _CreditScoreScreenState extends State<CreditScoreScreen> {
  final ApiService _api = ApiService();
  bool _loading = true;
  String? _error;
  int _score = 600;
  Map<String, dynamic>? _metrics;
  List<Map<String, dynamic>> _badges = [];
  List<Map<String, dynamic>> _newlyAwarded = [];

  @override
  void initState() {
    super.initState();
    _loadScore();
  }

  /// A getter to compute the sum of recent payments, improving code clarity.
  /// **FIXED**: Now handles potential null values within the list to prevent runtime errors.
  double get _recentPaymentsSum =>
      (_metrics?['recent'] as List?)?.fold<double>(
          0.0, (sum, item) => sum + ((item as num?) ?? 0)) ??
          0.0;

  Future<void> _loadScore() async {
    setState(() {
      _loading = true;
      _error = null;
      _newlyAwarded = []; // Clear previous newly awarded badges on load
    });
    try {
      final res = await _api.get('/api/credit/score');
      setState(() {
        _score = (res['score'] as int?) ?? 600;
        _metrics = {
          "borrowed": res['borrowed'],
          "paid": res['paid'],
          "outstanding": res['outstanding'],
          "recent": res['recent_payments'],
          "has_plan": res['has_plan']
        };
      });
      await _loadBadges();
    } catch (e) {
      setState(() {
        _error = e.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _loadBadges() async {
    try {
      final res = await _api.get('/api/credit/badges');
      final arr = (res['badges'] as List<dynamic>? ?? []);
      setState(() {
        _badges = arr.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      });
    } catch (e) {
      debugPrint('Badges load failed: $e');
    }
  }

  Future<void> _refreshAndAward() async {
    setState(() {
      _loading = true;
      _error = null;
      _newlyAwarded = [];
    });
    try {
      final res = await _api.post('/api/credit/refresh');
      final newly = (res['new_badges'] as List<dynamic>?) ?? [];
      if (mounted) {
        setState(() {
          _newlyAwarded =
              newly.map((e) => Map<String, dynamic>.from(e as Map)).toList();
        });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(newly.isNotEmpty
              ? 'Success! You have new badges.'
              : 'Refreshed successfully. No new badges earned.'),
          backgroundColor: Colors.green,
        ));
      }
      // Reload all data to reflect the changes
      await _loadScore();
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString());
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Refresh failed: $e'),
          backgroundColor: Colors.redAccent,
        ));
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Credit & Achievements'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Text('Failed to load data: $_error',
              textAlign: TextAlign.center),
        ),
      )
          : RefreshIndicator(
        onRefresh: _refreshAndAward,
        child: ListView(
          padding: const EdgeInsets.all(16.0),
          children: [
            _buildHeaderCard(),
            const SizedBox(height: 24),
            if (_newlyAwarded.isNotEmpty) _buildNewlyAwardedSection(),
            _buildBadgesSection(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeaderCard() {
    final dateStr = DateFormat.yMMMMd().format(DateTime.now());
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _buildScoreCircle(),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'As of $dateStr',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'This score reflects your payment history and borrowing activity.',
                        style: TextStyle(color: Colors.black54, fontSize: 13),
                      ),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: _refreshAndAward,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Refresh & Claim'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (_metrics != null) ...[
              const Divider(height: 32),
              _buildMetricsRow(),
            ]
          ],
        ),
      ),
    );
  }

  Widget _buildScoreCircle() {
    final pct = (_score - 300) / (850 - 300);
    final color = _score >= 700
        ? Colors.green
        : (_score >= 600 ? Colors.orange : Colors.redAccent);

    return SizedBox(
      width: 130,
      height: 130,
      child: Stack(
        alignment: Alignment.center,
        fit: StackFit.expand,
        children: [
          CircularProgressIndicator(
            strokeWidth: 12,
            value: pct.clamp(0.0, 1.0),
            color: color,
            backgroundColor: Colors.grey.shade200,
            strokeCap: StrokeCap.round,
          ),
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '$_score',
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                ),
                Text(
                  'Credit Score',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMetricsRow() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: [
        _buildMetricItem(
          'Outstanding',
          '\L\K\R${(_metrics!['outstanding'] ?? 0).toStringAsFixed(2)}',
        ),
        _buildMetricItem(
          'Paid (3m)',
          '\L\K\R${_recentPaymentsSum.toStringAsFixed(2)}',
        ),
        _buildMetricItem(
          'Has Plan',
          (_metrics!['has_plan'] == true) ? 'Yes' : 'No',
        ),
      ],
    );
  }

  Widget _buildMetricItem(String label, String value) {
    return Column(
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
      ],
    );
  }

  Widget _buildNewlyAwardedSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '🎉 Newly Awarded!',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        Card(
          color: Colors.green.shade50,
          child: Padding(
            padding: const EdgeInsets.all(8.0),
            child: Column(
              children: _newlyAwarded
                  .map((b) => ListTile(
                leading: const CircleAvatar(
                  backgroundColor: Colors.green,
                  child: Icon(Icons.emoji_events, color: Colors.white),
                ),
                title: Text(b['title'] ?? b['badge_key']),
                subtitle: Text(b['description'] ?? ''),
              ))
                  .toList(),
            ),
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  /// **FIXED**: Replaced GridView with a flexible Wrap widget to prevent overflows.
  Widget _buildBadgesSection() {
    if (_badges.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('All Achievements', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12, // Horizontal space between items
          runSpacing: 12, // Vertical space between rows
          children: _badges.map((badge) => _buildBadgeItem(badge)).toList(),
        ),
      ],
    );
  }

  /// A helper widget to build a single badge item.
  /// Used by the Wrap widget for a flexible layout.
  Widget _buildBadgeItem(Map<String, dynamic> b) {
    final earned = b['earned'] == true;
    // Calculate the width for a two-column layout
    final screenWidth = MediaQuery.of(context).size.width;
    // (Total Width - Page Padding - Space Between Widgets) / 2 columns
    final itemWidth = (screenWidth - 16 * 2 - 12) / 2;

    return SizedBox(
      width: itemWidth,
      child: Card(
        elevation: 0,
        color: earned ? Colors.teal.shade50 : Colors.grey.shade100,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: earned ? Colors.teal : Colors.grey.shade300,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12.0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                backgroundColor: earned ? Colors.teal : Colors.grey,
                child: Icon(
                  earned ? Icons.check_circle : Icons.lock,
                  color: Colors.white,
                  size: 20,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      b['title'],
                      style: const TextStyle(fontWeight: FontWeight.bold),
                      // No need for overflow since the height is now flexible
                    ),
                    const SizedBox(height: 2),
                    Text(
                      b['description'] ?? '',
                      style: Theme.of(context).textTheme.bodySmall,
                      // No need for maxLines either
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}