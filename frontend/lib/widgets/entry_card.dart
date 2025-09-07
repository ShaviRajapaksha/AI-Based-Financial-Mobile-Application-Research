import 'package:flutter/material.dart';
import '../models/financial_entry.dart';

class EntryCard extends StatelessWidget {
  final FinancialEntry entry;
  const EntryCard({super.key, required this.entry});

  Color _typeColor(String t, BuildContext ctx) {
    switch (t) {
      case 'SAVINGS':
        return Colors.green.shade700;
      case 'INVESTMENTS':
        return Colors.blue.shade700;
      case 'DEBT':
        return Colors.red.shade700;
      default:
        return Theme.of(ctx).colorScheme.primary;
    }
  }

  @override
  Widget build(BuildContext context) {
    final typeColor = _typeColor(entry.entryType, context);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
        child: Row(
          children: [
            CircleAvatar(
              radius: 26,
              backgroundColor: typeColor.withOpacity(0.18),
              child: Icon(Icons.receipt_long, color: typeColor),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(
                  children: [
                    Expanded(child: Text(entry.vendor ?? (entry.category ?? '—'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600))),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: typeColor.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text('${entry.amount.toStringAsFixed(2)} ${entry.currency}', style: TextStyle(color: typeColor, fontWeight: FontWeight.bold)),
                    )
                  ],
                ),
                const SizedBox(height: 6),
                Row(children: [
                  Chip(label: Text(entry.entryType), visualDensity: VisualDensity.compact),
                  const SizedBox(width: 8),
                  if (entry.category != null) Text('• ${entry.category}', style: const TextStyle(fontSize: 12, color: Colors.black54)),
                  const Spacer(),
                  Text(entry.entryDate.toIso8601String().substring(0, 10), style: const TextStyle(fontSize: 12, color: Colors.black54)),
                ]),
                if ((entry.notes ?? '').isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(entry.notes ?? '', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
                ]
              ]),
            ),
          ],
        ),
      ),
    );
  }
}