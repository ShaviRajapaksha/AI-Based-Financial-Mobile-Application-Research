import 'package:flutter/material.dart';
import '../../services/api_service.dart';
import '../../services/notification_service.dart';
import 'debt_notifications_screen.dart';

class DebtAlertsScreen extends StatefulWidget {
  const DebtAlertsScreen({super.key});
  @override
  State<DebtAlertsScreen> createState() => _DebtAlertsScreenState();
}

class _DebtAlertsScreenState extends State<DebtAlertsScreen> {
  final ApiService _api = ApiService();
  final NotificationService _ns = NotificationService.instance;

  bool _loading = true;
  List<Map<String, dynamic>> _alerts = [];

  final _titleCtl = TextEditingController();
  final _msgCtl = TextEditingController();
  DateTime? _due;
  String _recurrence = 'none';
  final _amountCtl = TextEditingController();
  final _vendorCtl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
    _ns.initialize();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final res = await _api.get('/api/debt/alerts');
      setState(() => _alerts = (res['items'] as List<dynamic>).cast<Map<String, dynamic>>());
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Load failed: $e')));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _create() async {
    final t = _titleCtl.text.trim();
    if (t.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Title cannot be empty')));
      return;
    }
    final body = _msgCtl.text.trim();
    final amount = double.tryParse(_amountCtl.text.trim());
    final vendor = _vendorCtl.text.trim();
    final payload = {
      "title": t,
      "message": body,
      "due_date": _due?.toIso8601String(),
      "amount": amount,
      "vendor": vendor.isNotEmpty ? vendor : null,
      "recurrence": _recurrence,
      "priority": "normal"
    }..removeWhere((k, v) => v == null);

    setState(() => _loading = true);
    try {
      final res = await _api.post('/api/debt/alerts', body: payload);

      debugPrint('create alert response: ${res.runtimeType} -> $res');

      // Normalize response to Map<String,dynamic>
      Map<String, dynamic> alert;
      if (res is Map<String, dynamic>) {
        alert = Map<String, dynamic>.from(res);
      } else if (res is List && res.isNotEmpty && res[0] is Map) {
        // tolerate backend returning a list containing an object
        alert = Map<String, dynamic>.from(res[0] as Map);
      } else {
        throw Exception('Unexpected response from server when creating alert: ${res.runtimeType}');
      }

      final rawId = alert['id'];
      final int alertId = rawId is int ? rawId : int.tryParse(rawId?.toString() ?? '') ?? -1;
      if (alertId <= 0) {
        debugPrint('Warning: alert id invalid: $rawId');
      }

      // schedule local notification using NotificationService (if due provided)
      if (_due != null && alertId > 0) {
        await NotificationService.instance.schedule(
          alertId,
          title: alert['title'] ?? t,
          body: alert['message'] ?? '',
          scheduledDate: _due!,
          recurrence: alert['recurrence'] ?? 'none',
          payload: alert.toString(),
        );
      }

      // clear inputs & reload listing
      _titleCtl.clear();
      _msgCtl.clear();
      _amountCtl.clear();
      _vendorCtl.clear();
      setState(() {
        _due = null;
        _recurrence = 'none';
      });


      await _load();
      if(mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Alert created and scheduled')));
    } catch (e, st) {
      debugPrint('Create alert failed: $e\n$st');
      if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Create failed: $e')));
    } finally {
      if(mounted) setState(() => _loading = false);
    }
  }

  Future<void> _ack(int id) async {
    try {
      await _api.post('/api/debt/alerts/$id/ack');
      await _ns.cancel(id);
      await _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ack failed: $e')));
    }
  }

  Future<void> _openNotificationsPage() async {
    Navigator.push(context, MaterialPageRoute(builder: (_) => const DebtNotificationsScreen()));
  }

  Future<void> _pickDateTime() async {
    final dt = await showDatePicker(
      context: context,
      initialDate: DateTime.now().add(const Duration(days: 1)),
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365 * 5)), // 5 years out
    );
    if (dt == null || !mounted) return;

    final t = await showTimePicker(
      context: context,
      initialTime: const TimeOfDay(hour: 9, minute: 0),
    );
    if (t == null) return;

    setState(() {
      _due = DateTime(dt.year, dt.month, dt.day, t.hour, t.minute);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Create New Alert'),
        actions: [
          IconButton(icon: const Icon(Icons.notifications_active_outlined), onPressed: _openNotificationsPage, tooltip: 'Pending Notifications'),
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load, tooltip: 'Refresh'),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(), // Ensures scrolling is always enabled
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Card(
                    elevation: 2,
                    clipBehavior: Clip.antiAlias,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        TextFormField(controller: _titleCtl, decoration: const InputDecoration(labelText: 'Title', border: OutlineInputBorder())),
                        const SizedBox(height: 12),
                        TextFormField(controller: _msgCtl, decoration: const InputDecoration(labelText: 'Message (Optional)', border: OutlineInputBorder())),
                        const SizedBox(height: 12),
                        Row(children: [
                          Expanded(child: TextFormField(controller: _vendorCtl, decoration: const InputDecoration(labelText: 'Vendor (Optional)', border: OutlineInputBorder()))),
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 120,
                            child: TextFormField(controller: _amountCtl, decoration: const InputDecoration(labelText: 'Amount', prefixText: 'LKR ', border: OutlineInputBorder()), keyboardType: const TextInputType.numberWithOptions(decimal: true)),
                          )
                        ]),
                        const SizedBox(height: 16),
                        Wrap(
                          spacing: 16,
                          runSpacing: 12,
                          alignment: WrapAlignment.spaceBetween,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              'Due: ${_due != null ? _due!.toLocal().toString().split('.').first : 'Not set'}',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                FilledButton.icon(icon: const Icon(Icons.calendar_today), onPressed: _pickDateTime, label: const Text('Set Date')),
                                const SizedBox(width: 8),
                                DropdownButton<String>(
                                  value: _recurrence,
                                  underline: Container(height: 2, color: Theme.of(context).colorScheme.primary),
                                  items: const [
                                    DropdownMenuItem(value: 'none', child: Text('No Repeat')),
                                    DropdownMenuItem(value: 'daily', child: Text('Daily')),
                                    DropdownMenuItem(value: 'weekly', child: Text('Weekly')),
                                    DropdownMenuItem(value: 'monthly', child: Text('Monthly')),
                                  ],
                                  onChanged: (v) => setState(() => _recurrence = v ?? 'none'),
                                ),
                              ],
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                          OutlinedButton(onPressed: () { _titleCtl.clear(); _msgCtl.clear(); _amountCtl.clear(); _vendorCtl.clear(); setState(() => _due = null); }, child: const Text('Clear')),
                          const SizedBox(width: 12),
                          FilledButton(onPressed: _create, child: const Text('Create Alert')),
                        ]),
                      ]),
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (_loading) const LinearProgressIndicator(),
                  const SizedBox(height: 8),
                  // The Expanded widget was removed from here.
                  _alerts.isEmpty
                      ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 48.0),
                    child: Center(child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.check_circle_outline, size: 60, color: Colors.grey.shade400),
                        const SizedBox(height: 16),
                        const Text('No pending alerts. All clear! 🎉'),
                      ],
                    )),
                  )
                      : ListView.builder(
                    // These two properties are crucial for nesting a ListView inside a SingleChildScrollView.
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: _alerts.length,
                      itemBuilder: (_, i) {
                        final a = _alerts[i];
                        final due = a['due_date'] != null ? DateTime.parse(a['due_date']).toLocal() : null;
                        final isAcknowledged = a['acknowledged'] == true;
                        return Card(
                          color: isAcknowledged ? Colors.green.shade50 : null,
                          child: ListTile(
                            leading: CircleAvatar(child: Text(a['title']?[0] ?? 'A')),
                            title: Text(a['title'], style: TextStyle(decoration: isAcknowledged ? TextDecoration.lineThrough : null)),
                            subtitle: Text('${a['message'] ?? ''}\nDue: ${due != null ? due.toString().split('.').first : '—'} | Recurrence: ${a['recurrence'] ?? 'none'}'),
                            isThreeLine: true,
                            trailing: isAcknowledged
                                ? const Tooltip(message: 'Acknowledged', child: Icon(Icons.check_circle, color: Colors.green))
                                : Row(mainAxisSize: MainAxisSize.min, children: [
                              Tooltip(
                                message: 'Acknowledge',
                                child: IconButton(icon: const Icon(Icons.check_circle_outline, color: Colors.blueAccent), onPressed: () => _ack(a['id'])),
                              ),
                              Tooltip(
                                message: 'Cancel Notification',
                                child: IconButton(icon: const Icon(Icons.notifications_off_outlined, color: Colors.orange), onPressed: () async { await _ns.cancel(a['id']); if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Local notification canceled'))); }),
                              ),
                            ]),
                          ),
                        );
                      }
                  ),
                ]),
          ),
        ),
      ),
      // --- FIX END ---
    );
  }
}