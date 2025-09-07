import 'package:flutter/material.dart';

class LabeledTextField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final TextInputType? keyboardType;

  const LabeledTextField({super.key, required this.label, required this.controller, this.keyboardType});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }
}