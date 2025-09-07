import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/entry_provider.dart';
import '../models/financial_entry.dart'; // assume you have this model mapping

class EditExtractedScreen extends StatefulWidget {
  const EditExtractedScreen({super.key});

  @override
  State<EditExtractedScreen> createState() => _EditExtractedScreenState();
}

class _EditExtractedScreenState extends State<EditExtractedScreen> {
  final _formKey = GlobalKey<FormState>();
  bool _saving = false;

  late String _entryType;
  late TextEditingController _amountCtl;
  late TextEditingController _vendorCtl;
  late TextEditingController _categoryCtl;
  late TextEditingController _notesCtl;
  late DateTime _entryDate;
  Map<String, dynamic>? _draft;

  @override
  void initState() {
    super.initState();
    final prov = context.read<EntryProvider>();
    _draft = prov.lastOcrDraft ?? {};
    _entryType = (_draft?['entry_type'] as String?)?.toUpperCase() ?? 'EXPENSES';
    _amountCtl = TextEditingController(text: _draft?['amount']?.toString() ?? '');
    _vendorCtl = TextEditingController(text: _draft?['vendor'] ?? _draft?['merchant'] ?? '');
    _categoryCtl = TextEditingController(text: _draft?['category'] ?? '');
    _notesCtl = TextEditingController(text: _draft?['notes'] ?? _draft?['raw_text'] ?? '');
    final dateStr = _draft?['entry_date'] as String?;
    _entryDate = dateStr != null ? DateTime.tryParse(dateStr) ?? DateTime.now() : DateTime.now();
  }

  @override
  void dispose() {
    _amountCtl.dispose();
    _vendorCtl.dispose();
    _categoryCtl.dispose();
    _notesCtl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final amount = double.tryParse(_amountCtl.text.replaceAll(',', '')) ?? 0.0;
      final entry = FinancialEntry(
        id: null,
        entryType: _entryType,
        category: _categoryCtl.text.trim().isEmpty ? null : _categoryCtl.text.trim(),
        amount: amount,
        currency: _draft?['currency'] ?? 'LKR',
        vendor: _vendorCtl.text.trim().isEmpty ? null : _vendorCtl.text.trim(),
        reference: _draft?['reference'],
        notes: _notesCtl.text.trim().isEmpty ? null : _notesCtl.text.trim(),
        entryDate: _entryDate,
        source: 'ocr',
        rawText: _draft?['raw_text'] ?? '',
      );

      // create via provider (will post to backend & add to entries list)
      final created = await context.read<EntryProvider>().create(entry);

      // success -> pop with true (ocr_upload_screen awaits this)
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e, st) {
      debugPrint('Save failed: $e\n$st');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Save failed: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _entryDate,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked != null) setState(() => _entryDate = picked);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Review extracted data')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const SizedBox(height: 6),
              Card(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Detected text', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    Text(_draft?['raw_text'] ?? '(no raw text)', style: const TextStyle(color: Colors.black87)),
                  ]),
                ),
              ),
              const SizedBox(height: 12),
              Form(
                key: _formKey,
                child: Column(children: [
                  Row(children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        value: _entryType,
                        items: const [
                          DropdownMenuItem(value: 'INCOME', child: Text('Income')),
                          DropdownMenuItem(value: 'SAVINGS', child: Text('Savings')),
                          DropdownMenuItem(value: 'EXPENSES', child: Text('Expenses')),
                          DropdownMenuItem(value: 'INVESTMENTS', child: Text('Investments')),
                          DropdownMenuItem(value: 'DEBT', child: Text('Debt')),
                        ],
                        onChanged: (v) => setState(() => _entryType = v ?? _entryType),
                        decoration: const InputDecoration(labelText: 'Type'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: _categoryCtl,
                        decoration: const InputDecoration(labelText: 'Category'),
                      ),
                    )
                  ]),
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(
                      child: TextFormField(
                        controller: _vendorCtl,
                        decoration: const InputDecoration(labelText: 'Vendor'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: _amountCtl,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(labelText: 'Amount'),
                        validator: (v) {
                          if (v == null || v.trim().isEmpty) return 'Amount required';
                          if (double.tryParse(v.replaceAll(',', '')) == null) return 'Enter a valid number';
                          return null;
                        },
                      ),
                    ),
                  ]),
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _pickDate,
                        icon: const Icon(Icons.calendar_month),
                        label: Text('Date: ${_entryDate.toLocal().toIso8601String().split('T').first}'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: _notesCtl,
                        decoration: const InputDecoration(labelText: 'Notes'),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 18),
                  _saving
                      ? const Center(child: CircularProgressIndicator())
                      : Row(children: [
                    Expanded(child: FilledButton(onPressed: _save, child: const Text('Save Entry'))),
                    const SizedBox(width: 12),
                    Expanded(
                        child: OutlinedButton(
                            onPressed: () => Navigator.pop(context, false), child: const Text('Cancel'))),
                  ])
                ]),
              )
            ]),
          ),
        ),
      ),
    );
  }
}