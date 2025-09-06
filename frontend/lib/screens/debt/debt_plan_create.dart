import 'package:flutter/material.dart';
import '../../services/api_service.dart';

class DebtPlanCreate extends StatefulWidget {
  const DebtPlanCreate({super.key});
  @override
  State<DebtPlanCreate> createState() => _DebtPlanCreateState();
}

class _DebtPlanCreateState extends State<DebtPlanCreate> {
  final ApiService _api = ApiService();
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _vendor = TextEditingController();
  final _principal = TextEditingController();
  final _rate = TextEditingController();
  final _minPayment = TextEditingController();
  final _target = TextEditingController();
  final _notes = TextEditingController();
  bool _loading = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('New Debt Plan')),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Form(
          key: _formKey,
          child: ListView(children: [
            TextFormField(controller: _name, decoration: const InputDecoration(labelText: 'Name (e.g. Car loan)'), validator: (v) => v!.isEmpty ? 'required' : null),
            TextFormField(controller: _vendor, decoration: const InputDecoration(labelText: 'Vendor (optional)')),
            TextFormField(controller: _principal, decoration: const InputDecoration(labelText: 'Principal (amount)'), keyboardType: TextInputType.number, validator: (v) => (v == null || double.tryParse(v) == null) ? 'invalid' : null),
            TextFormField(controller: _rate, decoration: const InputDecoration(labelText: 'Annual interest %'), keyboardType: TextInputType.number, validator: (v) => (v == null || double.tryParse(v) == null) ? 'invalid' : null),
            TextFormField(controller: _minPayment, decoration: const InputDecoration(labelText: 'Minimum monthly payment (optional)'), keyboardType: TextInputType.number),
            TextFormField(controller: _target, decoration: const InputDecoration(labelText: 'Target monthly payment (optional)'), keyboardType: TextInputType.number),
            TextFormField(controller: _notes, decoration: const InputDecoration(labelText: 'Notes'), maxLines: 3),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _loading ? null : () async {
                if (!_formKey.currentState!.validate()) return;
                setState(() => _loading = true);
                try {
                  final body = {
                    "name": _name.text.trim(),
                    "vendor": _vendor.text.trim(),
                    "principal": double.parse(_principal.text.trim()),
                    "annual_interest_pct": double.parse(_rate.text.trim()),
                    "minimum_payment": _minPayment.text.trim().isEmpty ? null : double.parse(_minPayment.text.trim()),
                    "target_payment": _target.text.trim().isEmpty ? null : double.parse(_target.text.trim()),
                    "notes": _notes.text.trim(),
                  }..removeWhere((k, v) => v == null);
                  await _api.post('/api/debt/plans', body: body);
                  Navigator.pop(context);
                } catch (e) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Create failed: $e')));
                } finally {
                  setState(() => _loading = false);
                }
              },
              child: _loading ? const CircularProgressIndicator() : const Text('Create Plan'),
            ),
          ]),
        ),
      ),
    );
  }
}