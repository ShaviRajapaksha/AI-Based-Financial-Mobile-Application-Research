import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import '../providers/entry_provider.dart';
import 'edit_extracted_screen.dart';

class OcrUploadScreen extends StatefulWidget {
  const OcrUploadScreen({super.key});

  @override
  State<OcrUploadScreen> createState() => _OcrUploadScreenState();
}

class _OcrUploadScreenState extends State<OcrUploadScreen> with SingleTickerProviderStateMixin {
  bool _busy = false;
  Uint8List? _pickedBytes;
  String? _pickedName;
  String? _pickedMime;
  final ImagePicker _picker = ImagePicker();
  late AnimationController _anim;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 500));
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  Future<bool> _requestPermissions() async {
    if (Platform.isAndroid) {
      final status = await Permission.photos.request();
      if (status.isGranted) return true;
      final storage = await Permission.storage.request();
      return storage.isGranted;
    }
    return true;
  }

  Future<void> _pickImage() async {
    if (_busy) return;
    final ok = await _requestPermissions();
    if (!ok) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Permission denied to access images')));
      return;
    }

    try {
      setState(() => _busy = true);
      final XFile? picked = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 85,
      );
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      setState(() {
        _pickedBytes = bytes;
        _pickedName = picked.name;
        _pickedMime = picked.mimeType ?? 'image/jpeg';
      });
      _anim.forward(from: 0);
    } catch (e, st) {
      debugPrint('Pick failed: $e\n$st');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to pick image: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _uploadAndEdit() async {
    if (_pickedBytes == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Pick an image first')));
      return;
    }
    setState(() => _busy = true);

    try {
      // upload bytes -> provider sets lastOcrDraft
      final filename = _pickedName ?? 'capture.jpg';
      await context.read<EntryProvider>().uploadOCRBytes(_pickedBytes!, filename, mime: _pickedMime ?? 'image/jpeg');

      // navigate to edit screen and WAIT for result (true = saved)
      final result = await Navigator.push<bool>(
        context,
        MaterialPageRoute(builder: (_) => const EditExtractedScreen()),
      );

      if (result == true) {
        // entry saved — give feedback and clear selection so user can scan next receipt
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Entry saved ✔')));
          setState(() {
            _pickedBytes = null;
            _pickedName = null;
            _pickedMime = null;
          });
        }
      } else {
        // returned false / null: user edited but not saved or cancelled
      }
    } catch (e, st) {
      debugPrint('Upload / navigation failed: $e\n$st');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to analyze: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _heroCard(BuildContext c) {
    final theme = Theme.of(c);
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [theme.colorScheme.primaryContainer, theme.colorScheme.secondaryContainer], begin: Alignment.topLeft, end: Alignment.bottomRight),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(children: [
        ScaleTransition(
          scale: Tween(begin: 0.95, end: 1.0).animate(CurvedAnimation(parent: _anim, curve: Curves.easeOut)),
          child: CircleAvatar(
            radius: 34,
            backgroundColor: theme.colorScheme.primary,
            child: const Icon(Icons.receipt_long, size: 36, color: Colors.white),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Scan & extract', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text('Select a receipt image and we’ll extract the fields for you. Edit results before saving.', style: theme.textTheme.bodyMedium?.copyWith(color: Colors.black54)),
          ]),
        ),
        const SizedBox(width: 8),
        IconButton(
          icon: const Icon(Icons.info_outline),
          color: Colors.black54,
          onPressed: () {
            showModalBottomSheet(context: c, builder: (ctx) {
              return Padding(
                padding: const EdgeInsets.all(16),
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: const [
                  Text('Tip', style: TextStyle(fontWeight: FontWeight.bold)),
                  SizedBox(height: 8),
                  Text('• Use good lighting and keep the receipt flat\n• Crop or rotate photos in gallery for best results\n• You can edit extracted fields before saving'),
                ]),
              );
            });
          },
        )
      ]),
    );
  }

  Widget _previewCard() {
    if (_pickedBytes == null) {
      return Card(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 18),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.photo_library_outlined, size: 48, color: Colors.black26),
            const SizedBox(height: 12),
            const Text('No image selected', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            const Text('Tap the button below to pick a receipt image from your gallery', textAlign: TextAlign.center, style: TextStyle(color: Colors.black54)),
          ]),
        ),
      );
    }

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.memory(_pickedBytes!, width: 96, height: 96, fit: BoxFit.cover),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_pickedName ?? 'Image', style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Text('${(_pickedBytes!.length / 1024).toStringAsFixed(1)} KB', style: const TextStyle(color: Colors.black54)),
              const SizedBox(height: 12),
              Row(children: [
                FilledButton.icon(onPressed: _busy ? null : _uploadAndEdit, icon: const Icon(Icons.play_arrow), label: const Text('Analyze')),
                const SizedBox(width: 8),
                OutlinedButton.icon(onPressed: _busy ? null : () => setState(() => _pickedBytes = null), icon: const Icon(Icons.clear), label: const Text('Clear')),
              ]),
            ]),
          )
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Upload Receipt/Document'),
        actions: [
          IconButton(icon: const Icon(Icons.settings), onPressed: () => Navigator.pushNamed(context, '/settings')),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          _heroCard(context),
          const SizedBox(height: 16),
          _previewCard(),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _busy ? null : _pickImage,
                icon: const Icon(Icons.photo_library),
                label: const Text('Pick from gallery'),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              ),
            ),
            const SizedBox(width: 12),
            // quick example button (optional): try last OCR draft if available
            ElevatedButton.icon(
              onPressed: _busy
                  ? null
                  : () {
                final draft = context.read<EntryProvider>().lastOcrDraft;
                if (draft == null) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No parsed draft available')));
                  return;
                }
                // open editor using existing lastOcrDraft without uploading
                Navigator.push(context, MaterialPageRoute(builder: (_) => const EditExtractedScreen()));
              },
              icon: const Icon(Icons.edit),
              label: const Text('Edit last'),
              style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14)),
            )
          ]),
          const SizedBox(height: 12),
          if (_busy) LinearProgressIndicator(color: theme.colorScheme.primary),
        ]),
      ),
    );
  }
}