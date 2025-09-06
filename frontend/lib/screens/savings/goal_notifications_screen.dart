import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';
import '../../services/api_service.dart';

class GoalNotificationsScreen extends StatefulWidget {
  const GoalNotificationsScreen({super.key});

  @override
  State<GoalNotificationsScreen> createState() => _GoalNotificationsScreenState();
}

class _GoalNotificationsScreenState extends State<GoalNotificationsScreen> {
  final ApiService _api = ApiService();
  bool _loading = true;
  bool _processing = false;
  List<_ReminderItem> _items = [];
  late SharedPreferences _prefs;
  final DateFormat _dateFmt = DateFormat.yMMMd();

  // look ahead window in days for reminders
  final int _lookAheadDays = 30;

  @override
  void initState() {
    super.initState();
    _initAll();
  }

  Future<void> _initAll() async {
    setState(() => _loading = true);
    _prefs = await SharedPreferences.getInstance();
    await _loadReminders();
    setState(() => _loading = false);
  }

  Future<void> _loadReminders() async {
    try {
      final res = await _api.get('/api/expense/goals'); // expected: List or {items: [...]}
      List<Map<String, dynamic>> goals = [];
      if (res is List) {
        goals = (res as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      } else if (res is Map && res['items'] != null && res['items'] is List) {
        goals = (res['items'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      }

      // Build reminder items from goals:
      final now = DateTime.now();
      final threshold = now.add(Duration(days: _lookAheadDays));

      final List<_ReminderItem> built = [];

      for (final g in goals) {
        try {
          final id = (g['id'] ?? g['goal_id'] ?? 0) as int;
          final name = (g['name'] ?? g['title'] ?? 'Goal #$id').toString();
          final targetDateRaw = g['target_date'] ?? g['deadline'] ?? g['targetDate'];
          if (targetDateRaw == null) continue;

          DateTime targetDate;
          if (targetDateRaw is DateTime) {
            targetDate = targetDateRaw;
          } else {
            // defensive parse
            targetDate = DateTime.parse(targetDateRaw.toString());
          }

          // if due within threshold or overdue -> create reminder
          if (targetDate.isBefore(threshold) || targetDate.isBefore(now.add(const Duration(days: 1)))) {
            final saved = _extractSavedAmount(g);
            final targetAmount = _extractTargetAmount(g);
            final daysLeft = targetDate.difference(now).inDays;
            final title = daysLeft < 0 ? 'Goal overdue' : (daysLeft == 0 ? 'Due today' : 'Due in $daysLeft day${daysLeft == 1 ? "" : "s"}');
            final msg = (saved != null && targetAmount != null)
                ? 'Goal "$name" target ${targetAmount.toStringAsFixed(0)} — saved ${saved.toStringAsFixed(0)} — ${_dateFmt.format(targetDate)}'
                : 'Goal "$name" is due on ${_dateFmt.format(targetDate)}';

            built.add(_ReminderItem(
              goalId: id,
              title: title,
              message: msg,
              dueDate: targetDate,
              goalName: name,
              rawGoal: g,
            ));
          }
        } catch (e) {
          // ignore single-goal parse errors
          debugPrint('Goal parse error: $e');
        }
      }

      // If backend gave nothing, provide demo reminder for UX/testing
      if (built.isEmpty) {
        final demoDue = DateTime.now().add(const Duration(days: 3));
        built.add(_ReminderItem(
          goalId: 0,
          title: 'Demo: Due in 3 days',
          message: 'Demo Goal "New Fridge" due on ${_dateFmt.format(demoDue)}',
          dueDate: demoDue,
          goalName: 'New Fridge',
          rawGoal: null,
        ));
      }

      // Sort newest (most recent due) first -> descending by dueDate
      built.sort((a, b) => b.dueDate.compareTo(a.dueDate));

      // Filter out items already acknowledged/ignored for today
      final todayKeyDate = _isoDate(DateTime.now());
      final filtered = built.where((it) {
        final k = _ackKeyFor(it.goalId, todayKeyDate);
        return !_prefs.containsKey(k); // if not present then show
      }).toList();

      setState(() {
        _items = filtered;
      });
    } catch (e, st) {
      debugPrint('Load reminders failed: $e\n$st');
      // fallback single demo
      final demoDue = DateTime.now().add(const Duration(days: 2));
      setState(() {
        _items = [
          _ReminderItem(
            goalId: 0,
            title: 'Demo reminder',
            message: 'Demo Goal "New Fridge" due on ${_dateFmt.format(demoDue)}',
            dueDate: demoDue,
            goalName: 'New Fridge',
            rawGoal: null,
          )
        ];
      });
    }
  }

  double? _extractSavedAmount(Map<String, dynamic>? g) {
    if (g == null) return null;
    try {
      if (g['progress'] != null) {
        final p = g['progress'];
        if (p is Map && p['total_saved'] != null) return (p['total_saved'] as num).toDouble();
      }
      if (g['total_saved'] != null) return (g['total_saved'] as num).toDouble();
      if (g['saved'] != null) return (g['saved'] as num).toDouble();
    } catch (_) {}
    return null;
  }

  double? _extractTargetAmount(Map<String, dynamic>? g) {
    if (g == null) return null;
    try {
      if (g['target_amount'] != null) return (g['target_amount'] as num).toDouble();
      if (g['target'] != null) return (g['target'] as num).toDouble();
    } catch (_) {}
    return null;
  }

  String _isoDate(DateTime d) {
    final dt = DateTime(d.year, d.month, d.day);
    return dt.toIso8601String().split('T').first;
  }

  String _ackKeyFor(int goalId, String isoDate) => 'goal_ack_${goalId}_$isoDate';

  Future<void> _ackNow(_ReminderItem item, String action) async {
    // action -> 'accepted' or 'ignored'
    setState(() => _processing = true);
    final todayKey = _isoDate(DateTime.now());
    final key = _ackKeyFor(item.goalId, todayKey);
    try {
      await _prefs.setString(key, action);

      // Attempt to notify backend (non-fatal)
      try {
        await _api.post('/api/expense/reminders/ack', body: {
          "goal_id": item.goalId,
          "date": todayKey,
          "action": action,
        });
      } catch (e) {
        // ignore server errors — this is optional
        debugPrint('Optional ack POST failed: $e');
      }

      // Remove showing this item from list
      setState(() {
        _items.removeWhere((it) => it.goalId == item.goalId && _isoDate(it.dueDate) == _isoDate(item.dueDate));
      });
    } catch (e) {
      debugPrint('Ack failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to update: $e')));
      }
    } finally {
      setState(() => _processing = false);
    }
  }

  Future<void> _acceptAllToday() async {
    setState(() => _processing = true);
    final todayKey = _isoDate(DateTime.now());
    try {
      for (final it in List<_ReminderItem>.from(_items)) {
        final key = _ackKeyFor(it.goalId, todayKey);
        await _prefs.setString(key, 'accepted');
        // optional backend call; ignore results
        try {
          await _api.post('/api/expense/reminders/ack', body: {"goal_id": it.goalId, "date": todayKey, "action": "accepted"});
        } catch (_) {}
      }
      setState(() => _items.clear());
    } catch (e) {
      debugPrint('Accept all failed: $e');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Operation failed: $e')));
    } finally {
      setState(() => _processing = false);
    }
  }

  Widget _buildTile(_ReminderItem item) {
    final dueStr = _dateFmt.format(item.dueDate);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(item.title, style: const TextStyle(fontWeight: FontWeight.w700))),
            Text(dueStr, style: const TextStyle(color: Colors.black54, fontSize: 12)),
          ]),
          const SizedBox(height: 6),
          Text(item.message, style: const TextStyle(color: Colors.black87)),
          const SizedBox(height: 8),
          Row(children: [
            FilledButton.icon(
              onPressed: _processing ? null : () => _ackNow(item, 'accepted'),
              icon: const Icon(Icons.check),
              label: const Text('Accept Today'),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: _processing ? null : () => _ackNow(item, 'ignored'),
              icon: const Icon(Icons.close),
              label: const Text('Ignore Today'),
            ),
            const Spacer(),
            IconButton(
              tooltip: 'Details',
              onPressed: () => _showGoalDetails(item),
              icon: const Icon(Icons.info_outline),
            ),
          ])
        ]),
      ),
    );
  }

  void _showGoalDetails(_ReminderItem item) {
    showDialog(
      context: context,
      builder: (_) {
        final g = item.rawGoal;
        return AlertDialog(
          title: Text(item.goalName),
          content: g == null
              ? Text(item.message)
              : SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Due: ${_dateFmt.format(item.dueDate)}'),
              const SizedBox(height: 6),
              Text('Target: ${_extractTargetAmount(g)?.toStringAsFixed(2) ?? "N/A"}'),
              const SizedBox(height: 6),
              Text('Saved: ${_extractSavedAmount(g)?.toStringAsFixed(2) ?? "N/A"}'),
              const SizedBox(height: 12),
              const Text('Goal raw data:', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Text(g.toString(), style: const TextStyle(fontSize: 11)),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
          ],
        );
      },
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_items.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.notifications_off, size: 56, color: Colors.black26),
          const SizedBox(height: 12),
          const Text('No reminders for today', style: TextStyle(fontSize: 16)),
          const SizedBox(height: 6),
          Text('No upcoming goal deadlines in the next $_lookAheadDays days.', style: const TextStyle(color: Colors.black54)),
          const SizedBox(height: 16),
          FilledButton(onPressed: _loadReminders, child: const Text('Refresh')),
        ]),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadReminders,
      child: ListView.builder(
        padding: const EdgeInsets.only(top: 12, bottom: 32),
        itemCount: _items.length + 1,
        itemBuilder: (ctx, idx) {
          if (idx == 0) {
            // header row with Accept All
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(children: [
                Text('Latest Reminders', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                FilledButton.icon(
                  onPressed: _processing ? null : _acceptAllToday,
                  icon: const Icon(Icons.check_circle_outline),
                  label: const Text('Accept All Today'),
                ),
              ]),
            );
          }
          final item = _items[idx - 1];
          return _buildTile(item);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final count = _items.length;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Goal Reminders'),
        actions: [
          if (count > 0)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Center(child: Text('$count', style: const TextStyle(fontWeight: FontWeight.w700))),
            ),
        ],
      ),
      body: _buildBody(),
    );
  }
}

/// Internal reminder model
class _ReminderItem {
  final int goalId;
  final String title;
  final String message;
  final DateTime dueDate;
  final String goalName;
  final Map<String, dynamic>? rawGoal;

  _ReminderItem({
    required this.goalId,
    required this.title,
    required this.message,
    required this.dueDate,
    required this.goalName,
    required this.rawGoal,
  });
}