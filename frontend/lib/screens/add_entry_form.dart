import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../models/financial_entry.dart';
import '../providers/entry_provider.dart';
import '../widgets/labeled_text_field.dart';

class AddEntryForm extends StatefulWidget {
  final Map<String, dynamic>? draft;
  const AddEntryForm({super.key, this.draft});

  @override
  State<AddEntryForm> createState() => _AddEntryFormState();
}

class _AddEntryFormState extends State<AddEntryForm> {
  final _formKey = GlobalKey<FormState>();
  final _amountCtl = TextEditingController();
  final _currencyCtl = TextEditingController(text: 'LKR');
  final _vendorCtl = TextEditingController();
  final _refCtl = TextEditingController();
  final _notesCtl = TextEditingController();
  final _categoryCtl = TextEditingController();

  String _entryType = 'EXPENSES';
  DateTime _entryDate = DateTime.now();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final d = widget.draft;
    if (d != null) {
      _entryType = d['entry_type'] ?? _entryType;
      _vendorCtl.text = d['vendor'] ?? '';
      _amountCtl.text = d['amount']?.toString() ?? '';
      _currencyCtl.text = d['currency'] ?? 'LKR';
      _refCtl.text = d['reference'] ?? '';
      if (d['entry_date'] != null) {
        _entryDate = DateTime.tryParse(d['entry_date']) ?? _entryDate;
      }
      _notesCtl.text = d['raw_text'] ?? '';
    }
  }

  @override
  void dispose() {
    _amountCtl.dispose();
    _currencyCtl.dispose();
    _vendorCtl.dispose();
    _refCtl.dispose();
    _notesCtl.dispose();
    _categoryCtl.dispose();
    super.dispose();
  }

  Future<void> _save(BuildContext ctx) async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final provider = ctx.read<EntryProvider>();
    final entry = FinancialEntry(
      entryType: _entryType,
      category: _categoryCtl.text.isEmpty ? null : _categoryCtl.text,
      amount: double.parse(_amountCtl.text),
      currency: _currencyCtl.text.isEmpty ? 'LKR' : _currencyCtl.text,
      vendor: _vendorCtl.text.isEmpty ? null : _vendorCtl.text,
      reference: _refCtl.text.isEmpty ? null : _refCtl.text,
      notes: _notesCtl.text.isEmpty ? null : _notesCtl.text,
      entryDate: _entryDate,
      source: widget.draft != null ? 'ocr' : 'manual',
      rawText: widget.draft != null ? widget.draft!['raw_text'] : null,
    );
    try {
      await provider.create(entry);
      if (mounted) Navigator.pop(ctx, true);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text('Save failed: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Add Entry'),
        actions: [IconButton(icon: const Icon(Icons.settings), onPressed: () => Navigator.pushNamed(context, '/settings'))],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: ElevatedButton.icon(
            onPressed: _saving ? null : () => _save(context),
            icon: _saving ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save),
            label: Text(_saving ? 'Saving...' : 'Save Entry'),
          ),
        ),
      ),
      body: Form(
        key: _formKey,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          DropdownButtonFormField<String>(
            value: _entryType,
            decoration: const InputDecoration(labelText: 'Entry Type'),
            items: const [
              DropdownMenuItem(value: 'INCOME', child: Text('INCOME')),
              DropdownMenuItem(value: 'SAVINGS', child: Text('SAVINGS')),
              DropdownMenuItem(value: 'EXPENSES', child: Text('EXPENSES')),
              DropdownMenuItem(value: 'INVESTMENTS', child: Text('INVESTMENTS')),
              DropdownMenuItem(value: 'DEBT', child: Text('DEBT')),
            ],
            onChanged: (v) => setState(() => _entryType = v ?? 'EXPENSES'),
          ),
          const SizedBox(height: 12),
          LabeledTextField(label: 'Category', controller: _categoryCtl),
          const SizedBox(height: 12),
          LabeledTextField(label: 'Vendor', controller: _vendorCtl),
          const SizedBox(height: 12),
          TextFormField(
            controller: _amountCtl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Amount'),
            validator: (v) => (v == null || double.tryParse(v) == null) ? 'Enter a valid number' : null,
          ),
          const SizedBox(height: 12),
          LabeledTextField(label: 'Currency', controller: _currencyCtl),
          const SizedBox(height: 12),
          LabeledTextField(label: 'Reference', controller: _refCtl),
          const SizedBox(height: 12),
          TextFormField(controller: _notesCtl, maxLines: 5, decoration: const InputDecoration(labelText: 'Notes / Raw Text')),
          const SizedBox(height: 12),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Date'),
            subtitle: Text(DateFormat('yyyy-MM-dd').format(_entryDate)),
            trailing: IconButton(
              icon: const Icon(Icons.date_range),
              onPressed: () async {
                final picked = await showDatePicker(context: context, firstDate: DateTime(2000), lastDate: DateTime(2100), initialDate: _entryDate);
                if (picked != null) setState(() => _entryDate = picked);
              },
            ),
          )
        ]),
      ),
    );
  }
}