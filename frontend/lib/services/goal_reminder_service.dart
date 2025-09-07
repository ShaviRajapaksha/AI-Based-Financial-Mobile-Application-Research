import 'package:flutter/material.dart';
import 'notification_service.dart';

class GoalReminderService {

  static Future<void> scheduleGoalReminders(Map<String, dynamic> goal, {int daysBefore = 3}) async {
    if (goal == null) return;
    final raw = goal['target_date'] ?? goal['due_date'] ?? goal['deadline'];
    if (raw == null) return;

    DateTime due;
    if (raw is DateTime) {
      due = raw;
    } else {
      try {
        due = DateTime.parse(raw.toString());
      } catch (e) {
        debugPrint('Invalid goal date for scheduling: $raw');
        return;
      }
    }

    // normalize to local date/time: due at 09:00 local
    final dueLocal = DateTime(due.year, due.month, due.day, 9, 0, 0);
    final beforeLocal = dueLocal.subtract(Duration(days: daysBefore));

    // skip if dates in past
    final now = DateTime.now();
    if (beforeLocal.isBefore(now) && dueLocal.isBefore(now)) {
      debugPrint('Both reminder times are in the past; skipping scheduling for goal ${goal['id']}');
      return;
    }

    // deterministic ids
    final int gid = (goal['id'] is int) ? goal['id'] as int : goal.hashCode.abs();
    final int baseId = gid * 1000;

    // schedule 'before' reminder if it's still in future
    if (beforeLocal.isAfter(now)) {
      await NotificationService.instance.schedule(
        baseId + 1,
        title: 'Upcoming savings goal: ${goal['name'] ?? 'Goal'}',
        body: 'Target date in $daysBefore day(s) on ${dueLocal.toLocal().toString().split(" ").first}. Check progress.',
        scheduledDate: beforeLocal,
        payload: 'goal:$gid',
        exact: false,
      );
    }

    // schedule 'due' reminder if it's still in future
    if (dueLocal.isAfter(now)) {
      await NotificationService.instance.schedule(
        baseId + 2,
        title: 'Savings goal due today: ${goal['name'] ?? 'Goal'}',
        body: 'Today is the target date for your goal. Check your progress and contribute if needed.',
        scheduledDate: dueLocal,
        payload: 'goal:$gid',
        exact: false,
      );
    }
  }

  /// Schedule reminders for a list of goals (fire-and-forget)
  static Future<void> scheduleMany(List<Map<String, dynamic>> goals, {int daysBefore = 3}) async {
    for (final g in goals) {
      try {
        await scheduleGoalReminders(g, daysBefore: daysBefore);
      } catch (e) {
        debugPrint('Failed scheduling for goal ${g['id']}: $e');
      }
    }
  }

  /// Cancel reminders for a single goal (use when goal completed/deleted or toggle OFF)
  static Future<void> cancelGoalReminders(int goalId) async {
    final int baseId = goalId * 1000;
    await NotificationService.instance.cancel(baseId + 1);
    await NotificationService.instance.cancel(baseId + 2);
  }
}