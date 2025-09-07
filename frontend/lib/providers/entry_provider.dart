import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import '../models/financial_entry.dart';
import '../services/api_service.dart';

class EntryProvider with ChangeNotifier {
  final ApiService api;
  EntryProvider(this.api);

  List<FinancialEntry> _entries = [];
  bool loading = false;
  Map<String, dynamic>? lastOcrDraft;

  List<FinancialEntry> get entries => _entries;

  Future<void> refresh([String? type]) async {
    loading = true;
    notifyListeners();
    try {
      final items = await api.listEntries(type: type);
      _entries = items.map((j) => FinancialEntry.fromJson(j)).toList();
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  // Upload from File
  Future<void> uploadOCR(File file) async {
    try {
      lastOcrDraft = await api.uploadForOCRFile(file);
      notifyListeners();
    } catch (e) {
      rethrow;
    }
  }

  // Upload from bytes
  Future<String?> uploadOCRBytes(Uint8List bytes, String filename, {String mime = 'image/jpeg'}) async {
    try {
      final parsed = await api.uploadForOCRBytes(bytes, filename, mime: mime);
      lastOcrDraft = parsed;
      notifyListeners();
      return null;
    } catch (e) {
      // return error string for UI display
      final err = e?.toString() ?? 'Unknown error';
      debugPrint('EntryProvider.uploadOCRBytes error: $err');
      return err;
    }
  }

  Future<FinancialEntry> create(FinancialEntry e) async {
    final j = await api.createEntry(e.toJson());
    final created = FinancialEntry.fromJson(j);
    _entries.insert(0, created);
    notifyListeners();
    return created;
  }

  // Clear local caches when logging out
  void clearForLogout() {
    _entries = [];
    lastOcrDraft = null;
    notifyListeners();
  }
}