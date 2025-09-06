import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart'; // Import this
import '../../services/api_service.dart';
import '../../services/notification_service.dart'; // And this

class DebtNotificationsScreen extends StatefulWidget {
  const DebtNotificationsScreen({super.key});
  @override
  State<DebtNotificationsScreen> createState() => _DebtNotificationsScreenState();
}

class _DebtNotificationsScreenState extends State<DebtNotificationsScreen> {
  final ApiService _api = ApiService();
  final NotificationService _ns = NotificationService.instance; // Re-add NotificationService
  List<Map<String, dynamic>> _alerts = [];
  List<PendingNotificationRequest> _pending = []; // Re-add list for local notifications
  bool _loading = true;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _loadAlerts();
  }

  Future<void> _loadAlerts() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      // First, get the alerts from your backend
      final res = await _api.get('/api/debt/alerts?show=unack');
      _alerts = (res['items'] as List<dynamic>).cast<Map<String, dynamic>>();

      // Then, get the list of notifications actually scheduled on the device
      await _ns.initialize();
      _pending = await _ns.pending();

    } catch (e) {
      _error = 'Failed to load reminders. Please try again.';
      debugPrint(e.toString());
    }
    setState(() => _loading = false);
  }

  Future<void> _acknowledgeAlert(int id) async {
    try {
      setState(() {
        _alerts.removeWhere((a) => a['id'] == id);
      });
      await _api.post('/api/debt/alerts/$id/ack');
      await _ns.cancel(id); // Also cancel the local notification
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Reminder marked as paid!'), backgroundColor: Colors.green),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not update reminder. Please try again.'), backgroundColor: Colors.red),
      );
      _loadAlerts();
    }
  }

  Future<void> _deleteAlert(int id) async {
    try {
      setState(() {
        _alerts.removeWhere((a) => a['id'] == id);
      });
      await _api.delete('/api/debt/alerts/$id');
      await _ns.cancel(id); // Also cancel the local notification
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Reminder dismissed.')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not dismiss reminder. Please try again.'), backgroundColor: Colors.red),
      );
      _loadAlerts();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Upcoming Reminders'),
        actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _loadAlerts)],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error.isNotEmpty) {
      return Center(child: Text(_error));
    }
    if (_alerts.isEmpty) {
      return _buildEmptyState();
    }
    return RefreshIndicator(
      onRefresh: _loadAlerts,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: _alerts.length,
        itemBuilder: (_, i) {
          final alert = _alerts[i];
          // ** Check if a local notification is pending for this alert **
          final isScheduled = _pending.any((p) => p.id == alert['id']);
          return _buildAlertCard(alert, isScheduled);
        },
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.notifications_off_outlined, size: 80, color: Colors.grey.shade400),
          const SizedBox(height: 16),
          const Text(
            'All Clear!',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            'You have no upcoming reminders.',
            style: TextStyle(fontSize: 16, color: Colors.grey.shade600),
          ),
        ],
      ),
    );
  }

  Widget _buildAlertCard(Map<String, dynamic> alert, bool isScheduled) {
    final priority = alert['priority'] ?? 'normal';
    final dueDate = alert['due_date'] != null ? DateTime.parse(alert['due_date']).toLocal() : null;

    final Color priorityColor = _getPriorityColor(priority);
    final (String formattedDate, Color dateColor) = _formatDueDate(dueDate);

    return Card(
      elevation: 2,
      margin: const EdgeInsets.symmetric(vertical: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      clipBehavior: Clip.antiAlias, // Ensures the stack respects the card's rounded corners
      child: Stack(
        children: [
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  width: 6,
                  decoration: BoxDecoration(color: priorityColor),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(12.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          alert['title'],
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                        ),
                        if (alert['message'] != null) ...[
                          const SizedBox(height: 4),
                          Text(alert['message'], style: const TextStyle(color: Colors.black54)),
                        ],
                        const Divider(height: 20),
                        _buildInfoRow(Icons.business_rounded, alert['vendor']),
                        _buildInfoRow(Icons.price_check_rounded,
                            alert['amount'] != null ? NumberFormat.currency(symbol: 'LKR ').format(alert['amount']) : null),
                        _buildInfoRow(Icons.repeat_rounded, alert['recurrence']),
                        const SizedBox(height: 12),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              formattedDate,
                              style: TextStyle(fontWeight: FontWeight.bold, color: dateColor, fontSize: 15),
                            ),
                            Row(
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                                  tooltip: 'Dismiss Reminder',
                                  onPressed: () => _deleteAlert(alert['id']),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.check_circle_outline, color: Colors.green),
                                  tooltip: 'Mark as Paid',
                                  onPressed: () => _acknowledgeAlert(alert['id']),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          // ** This is the "Scheduled" icon indicator **
          if (isScheduled)
            Positioned(
              top: 8,
              right: 8,
              child: Tooltip(
                message: 'Notification is scheduled',
                child: Icon(
                  Icons.notifications_active,
                  size: 18,
                  color: Colors.teal.shade400,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(IconData icon, String? text) {
    if (text == null || text.isEmpty || text == 'none') {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 6.0),
      child: Row(
        children: [
          Icon(icon, size: 16, color: Colors.grey.shade600),
          const SizedBox(width: 8),
          Text(
            text,
            style: TextStyle(fontSize: 14, color: Colors.grey.shade700),
          ),
        ],
      ),
    );
  }

  Color _getPriorityColor(String priority) {
    switch (priority) {
      case 'high': return Colors.red.shade400;
      case 'normal': return Colors.blue.shade400;
      case 'low': return Colors.grey.shade400;
      default: return Colors.blue.shade400;
    }
  }

  (String, Color) _formatDueDate(DateTime? date) {
    if (date == null) return ('No due date', Colors.grey);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final dueDate = DateTime(date.year, date.month, date.day);
    final difference = dueDate.difference(today).inDays;

    if (difference < 0) return ('Overdue', Colors.red.shade700);
    if (difference == 0) return ('Due Today', Colors.orange.shade700);
    if (difference == 1) return ('Due Tomorrow', Colors.orange.shade600);
    if (difference <= 7) return ('Due in $difference days', Colors.blue.shade600);
    return ('Due ${DateFormat.yMMMd().format(date)}', Colors.black87);
  }
}