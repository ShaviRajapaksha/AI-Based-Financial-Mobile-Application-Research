class FinancialEntry {
  final int? id;
  String entryType; // SAVINGS | EXPENSES | INVESTMENTS | DEBT
  String? category;
  double amount;
  String currency;
  String? vendor;
  String? reference;
  String? notes;
  DateTime entryDate;
  String source; // manual | ocr
  String? rawText;

  FinancialEntry({
    this.id,
    required this.entryType,
    this.category,
    required this.amount,
    this.currency = 'LKR',
    this.vendor,
    this.reference,
    this.notes,
    required this.entryDate,
    this.source = 'manual',
    this.rawText,
  });

  factory FinancialEntry.fromJson(Map<String, dynamic> j) => FinancialEntry(
    id: j['id'],
    entryType: j['entry_type'],
    category: j['category'],
    amount: (j['amount'] as num).toDouble(),
    currency: j['currency'] ?? 'LKR',
    vendor: j['vendor'],
    reference: j['reference'],
    notes: j['notes'],
    entryDate: DateTime.parse(j['entry_date']),
    source: j['source'] ?? 'manual',
    rawText: j['raw_text'],
  );

  Map<String, dynamic> toJson() => {
    if (id != null) 'id': id,
    'entry_type': entryType,
    'category': category,
    'amount': amount,
    'currency': currency,
    'vendor': vendor,
    'reference': reference,
    'notes': notes,
    'entry_date': entryDate.toIso8601String().substring(0, 10),
    'source': source,
    'raw_text': rawText,
  };
}