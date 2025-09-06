import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../services/api_service.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';

class DebtReportScreen extends StatefulWidget {
  const DebtReportScreen({super.key});
  @override
  State<DebtReportScreen> createState() => _DebtReportScreenState();
}

class _DebtReportScreenState extends State<DebtReportScreen> {
  final ApiService _api = ApiService();
  bool _loading = false;
  List<Map<String, dynamic>> _reports = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final items = await _api.listDebtReports();
      setState(() => _reports = items);
    } catch (e) {
      debugPrint('load reports failed: $e');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Load failed: $e')));
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _openReport(Map<String, dynamic> r) async {
    final id = r['id'];
    final name = r['name'] ?? 'report.pdf';
    if (id == null) return;

    setState(() => _loading = true);
    try {
      // 1. Download the file bytes using the authenticated API service
      final bytes = await _api.downloadDebtReport(id as int);

      // 2. Get a temporary directory to store the file
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/$name');

      // 3. Write the bytes to the file
      await file.writeAsBytes(bytes, flush: true);

      // 4. Open the local file using open_filex
      final result = await OpenFilex.open(file.path);
      if (result.type != ResultType.done) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not open file: ${result.message}')));
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to open report: $e')));
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _generate() async {
    final nameCtl = TextEditingController(text: 'Debt report ${DateFormat.yMMMd().format(DateTime.now())}');
    await showDialog(context: context, builder: (ctx) {
      return AlertDialog(
        title: const Text('Generate report'),
        content: TextField(controller: nameCtl, decoration: const InputDecoration(labelText: 'Report name')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () async {
            Navigator.pop(ctx);
            setState(() => _loading = true);
            try {
              final res = await _api.generateDebtReport(name: nameCtl.text);
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Report generated')));
              await _load();
              final id = res['id'];
              if (id != null) {
                // Create a map to pass to the existing _openReport method
                final reportData = {
                  'id': id,
                  'name': nameCtl.text.endsWith('.pdf') ? nameCtl.text : '${nameCtl.text}.pdf'
                };
                await _openReport(reportData); // Re-use your new, robust open logic!
              }
            } catch (e) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Generate failed: $e')));
            } finally {
              setState(() => _loading = false);
            }
          }, child: const Text('Generate')),
        ],
      );
    });
  }

  Future<void> _deleteReport(int id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete report?'),
        content: const Text('This will remove the saved PDF from server.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _loading = true);
    try {
      await _api.delete('/api/debt/reports/$id');
      await _load();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Delete failed: $e')));
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Debt Reports'),
        actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _load)],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _generate,
        icon: const Icon(Icons.picture_as_pdf),
        label: const Text('Generate'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: _loading ? const Center(child: CircularProgressIndicator()) : _reports.isEmpty
            ? const Center(child: Text('No reports yet — generate one'))
            : ListView.builder(
          itemCount: _reports.length,
          itemBuilder: (_, i) {
            final r = _reports[i];
            final created = r['created_at'];
            return Card(
              child: ListTile(
                title: Text(r['name'] ?? 'Report ${r['id']}'),
                subtitle: Text('Created: ${created ?? '-'} • Size: ${r['size'] ?? '-'} bytes'),
                onTap: () => _openReport(r),
                trailing: IconButton(icon: const Icon(Icons.delete), onPressed: () => _deleteReport(r['id'] as int)),
              ),
            );
          },
        ),
      ),
    );
  }
}