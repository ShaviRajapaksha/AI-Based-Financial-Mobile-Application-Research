import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/entry_provider.dart';
import '../main.dart';

class EntriesListScreen extends StatefulWidget {
  const EntriesListScreen({super.key});

  @override
  State<EntriesListScreen> createState() => _EntriesListScreenState();
}

class _EntriesListScreenState extends State<EntriesListScreen> with RouteAware {
  bool _loading = false;
  String _selectedType = 'All';
  final List<String> _types = ['All', 'INCOME', 'SAVINGS', 'EXPENSES', 'INVESTMENTS', 'DEBT'];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
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
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    try {
      await context.read<EntryProvider>().refresh();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // Defensive accessors to support Map or model objects
  String _entryTypeOf(dynamic e) {
    try {
      if (e is Map) return (e['entry_type'] ?? e['entryType'] ?? '').toString().toUpperCase();
      return (e.entryType ?? e.entry_type ?? '').toString().toUpperCase();
    } catch (_) {
      return '';
    }
  }

  double _amountOf(dynamic e) {
    try {
      if (e is Map) {
        final v = e['amount'];
        if (v == null) return 0.0;
        return v is int ? v.toDouble() : (v as num).toDouble();
      }
      final v = e.amount;
      if (v == null) return 0.0;
      return v is int ? v.toDouble() : (v as num).toDouble();
    } catch (_) {
      return 0.0;
    }
  }

  String _titleOf(dynamic e) {
    try {
      if (e is Map) return (e['vendor'] ?? e['category'] ?? 'Entry').toString();
      return (e.vendor ?? e.category ?? 'Entry').toString();
    } catch (_) {
      return 'Entry';
    }
  }

  String _subtitleOf(dynamic e) {
    try {
      if (e is Map) return (e['entry_date'] ?? e['entryDate'] ?? '').toString();
      final d = e.entryDate ?? e.entry_date;
      if (d == null) return '';
      if (d is String) return d;
      return (d as DateTime).toIso8601String().split('T').first;
    } catch (_) {
      return '';
    }
  }

  Color _chipColor(String type, BuildContext context) {
    final theme = Theme.of(context);
    if (type == 'INCOME') return Colors.green.shade600;
    if (type == 'EXPENSES') return theme.colorScheme.error;
    // other types use primary variant
    return theme.colorScheme.primary;
  }

  Widget _buildEntryTile(dynamic e) {
    final type = _entryTypeOf(e);
    final amount = _amountOf(e);
    final title = _titleOf(e);
    final subtitle = _subtitleOf(e);

    final isIncome = type == 'INCOME';

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        leading: CircleAvatar(
          backgroundColor: isIncome ? Colors.green.shade50 : Theme.of(context).colorScheme.primaryContainer,
          child: Icon(
            isIncome ? Icons.trending_up : Icons.receipt_long,
            color: isIncome ? Colors.green.shade700 : Theme.of(context).colorScheme.onPrimaryContainer,
          ),
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: subtitle.isNotEmpty ? Text(subtitle) : null,
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              (isIncome ? '+ ' : '') + amount.toStringAsFixed(2),
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: isIncome ? Colors.green.shade800 : Theme.of(context).textTheme.bodyLarge?.color,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: _chipColor(type, context).withOpacity(0.12),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: _chipColor(type, context).withOpacity(0.2)),
              ),
              child: Text(
                type,
                style: TextStyle(
                  color: _chipColor(type, context),
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
            )
          ],
        ),
        onTap: () {
          // optionally navigate to detail/edit
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final allEntries = context.watch<EntryProvider>().entries;
    // filter client-side — "All" means no filter
    final filtered = (_selectedType == 'All')
        ? allEntries
        : allEntries.where((e) => _entryTypeOf(e) == _selectedType).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Entries'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _refresh),
          IconButton(icon: const Icon(Icons.settings), onPressed: () => Navigator.pushNamed(context, '/settings')),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surface,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.black12),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            value: _selectedType,
                            items: _types.map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(),
                            onChanged: (v) {
                              if (v == null) return;
                              setState(() => _selectedType = v);
                              // optional: if not All, you can call provider.refresh with server-side filtering
                              // but client-side filtering guarantees "All" works even if backend filter behavior differs.
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _loading
                  ? const Expanded(child: Center(child: CircularProgressIndicator()))
                  : filtered.isEmpty
                  ? Expanded(
                child: Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.inbox, size: 60, color: Colors.black26),
                    const SizedBox(height: 12),
                    Text(_selectedType == 'All' ? 'No entries yet' : 'No $_selectedType entries', style: const TextStyle(color: Colors.black54)),
                  ]),
                ),
              )
                  : Expanded(
                child: ListView.builder(
                  physics: const AlwaysScrollableScrollPhysics(),
                  itemCount: filtered.length,
                  itemBuilder: (context, idx) {
                    final e = filtered[idx];
                    return _buildEntryTile(e);
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}