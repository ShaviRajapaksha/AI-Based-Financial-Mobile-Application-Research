import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/api_service.dart';
import '../../services/auth_service.dart';

class ExpenseChatScreen extends StatefulWidget {
  const ExpenseChatScreen({super.key});
  @override
  State<ExpenseChatScreen> createState() => _ExpenseChatScreenState();
}

class _ExpenseChatScreenState extends State<ExpenseChatScreen> with WidgetsBindingObserver {
  final ApiService _api = ApiService();
  final TextEditingController _inputCtl = TextEditingController();
  final ScrollController _scroll = ScrollController();

  late stt.SpeechToText _speech;
  late FlutterTts _tts;

  bool _speechAvailable = false;
  bool _isListening = false;
  bool _isSending = false;
  bool _isSpeaking = false;
  bool _autoSpeak = true;

  double _ttsRate = 0.5;
  double _ttsPitch = 1.0;

  // Messages: List of maps {role: 'user'|'assistant', text: '...', ts: 'ISO string'}
  List<Map<String, dynamic>> _messages = [];
  final int _maxHistoryItems = 300; // cap to limit local storage size

  String? _prefsKey; // set per user

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _speech = stt.SpeechToText();
    _tts = FlutterTts();

    _initSpeech();
    _initTts();
    _initPrefsAndLoadHistory();
  }

  Future<void> _initPrefsAndLoadHistory() async {
    final user = AuthService.user;
    final uid = user != null ? user['id']?.toString() ?? 'anon' : 'anon';
    _prefsKey = 'expense_chat_history_user_$uid';
    await _loadHistory();
  }

  Future<void> _loadHistory() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_prefsKey ?? '');
      if (raw != null && raw.isNotEmpty) {
        final List<dynamic> arr = jsonDecode(raw) as List<dynamic>;
        final loaded = arr.map<Map<String, dynamic>>((e) {
          final m = Map<String, dynamic>.from(e as Map);
          return {
            'role': m['role'] ?? 'assistant',
            'text': m['text'] ?? '',
            'ts': m['ts'] ?? DateTime.now().toIso8601String(),
          };
        }).toList();
        if (mounted) {
          setState(() {
            _messages = loaded;
          });
          // wait a tick then scroll
          WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
        }
      }
    } catch (e) {
      debugPrint('Failed to load chat history: $e');
    }
  }

  Future<void> _saveHistory() async {
    try {
      if (_prefsKey == null) return;
      final sp = await SharedPreferences.getInstance();
      // Trim if necessary
      final trimmed = (_messages.length > _maxHistoryItems)
          ? _messages.sublist(_messages.length - _maxHistoryItems)
          : _messages;
      await sp.setString(_prefsKey!, jsonEncode(trimmed));
    } catch (e) {
      debugPrint('Failed to save chat history: $e');
    }
  }

  Future<void> _clearHistoryConfirm() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear chat history'),
        content: const Text('This will remove the local chat history for this account. Continue?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Clear')),
        ],
      ),
    );
    if (ok == true) {
      await _clearHistory();
    }
  }

  Future<void> _clearHistory() async {
    try {
      final sp = await SharedPreferences.getInstance();
      if (_prefsKey != null) await sp.remove(_prefsKey!);
      if (mounted) setState(() => _messages.clear());
    } catch (e) {
      debugPrint('Failed to clear history: $e');
    }
  }

  void _addMessageLocal(String role, String text) {
    final entry = {'role': role, 'text': text, 'ts': DateTime.now().toIso8601String()};
    setState(() {
      _messages.add(entry);
      // cap length in-memory too
      if (_messages.length > _maxHistoryItems) {
        _messages = _messages.sublist(_messages.length - _maxHistoryItems);
      }
    });
    _saveHistory();
    _scrollToBottom();
  }

  Future<void> _initSpeech() async {
    try {
      _speechAvailable = await _speech.initialize(
        onStatus: (status) {
          debugPrint('Speech status: $status');
          if (status == 'done' || status == 'notListening') {
            if (mounted) setState(() => _isListening = false);
          }
        },
        onError: (err) {
          debugPrint('Speech error: $err');
          if (mounted) setState(() => _isListening = false);
        },
      );
    } catch (e) {
      debugPrint('Speech init failed: $e');
      _speechAvailable = false;
    }
    if (mounted) setState(() {});
  }

  void _initTts() {
    _tts.setStartHandler(() {
      if (mounted) setState(() => _isSpeaking = true);
    });
    _tts.setCompletionHandler(() {
      if (mounted) setState(() => _isSpeaking = false);
    });
    _tts.setErrorHandler((msg) {
      debugPrint('TTS error: $msg');
      if (mounted) setState(() => _isSpeaking = false);
    });
    // set defaults (async calls OK without await)
    _tts.setSpeechRate(_ttsRate);
    _tts.setPitch(_ttsPitch);
  }

  Future<void> _startListening() async {
    if (!_speechAvailable) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Speech recognition not available')));
      return;
    }
    await _stopTts();

    setState(() => _isListening = true);

    await _speech.listen(
      onResult: (result) {
        try {
          _inputCtl.text = result.recognizedWords;
          _inputCtl.selection = TextSelection.fromPosition(TextPosition(offset: _inputCtl.text.length));
        } catch (e) {
          debugPrint('onResult parse error: $e');
        }
      },
      partialResults: true,
    );
  }

  Future<void> _stopListening() async {
    if (!_isListening) return;
    try {
      await _speech.stop();
    } catch (e) {
      debugPrint('stop listening error: $e');
    }
    if (mounted) setState(() => _isListening = false);
  }

  Future<void> _speak(String text) async {
    if (text.trim().isEmpty) return;
    await _stopTts();
    try {
      await _tts.setSpeechRate(_ttsRate);
      await _tts.setPitch(_ttsPitch);
      await _tts.speak(text);
    } catch (e) {
      debugPrint('TTS speak error: $e');
    }
  }

  Future<void> _stopTts() async {
    try {
      await _tts.stop();
    } catch (_) {}
    if (mounted) setState(() => _isSpeaking = false);
  }

  Future<void> _stopAll() async {
    await _stopListening();
    await _stopTts();
  }

  Future<void> _sendMessage() async {
    final text = _inputCtl.text.trim();
    if (text.isEmpty) return;

    // add user message locally and save
    _addMessageLocal('user', text);

    setState(() => _isSending = true);
    _inputCtl.clear();

    try {
      final res = await _api.post('/api/expense/chat', body: {"message": text});
      final reply = (res['reply'] ?? 'Sorry, no reply') as String;

      // add assistant reply locally and save
      _addMessageLocal('assistant', reply);

      if (_autoSpeak) {
        await _speak(reply);
      }
    } catch (e) {
      final errText = 'Failed to get reply: $e';
      _addMessageLocal('assistant', errText);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Chat send failed: $e')));
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  void _scrollToBottom() {
    Timer(const Duration(milliseconds: 120), () {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      _stopAll();
    }
    super.didChangeAppLifecycleState(state);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopAll();
    _inputCtl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<bool> _onWillPop() async {
    await _stopAll();
    return true;
  }

  Widget _buildMessageBubble(Map<String, dynamic> m) {
    final isUser = m['role'] == 'user';
    final text = m['text'] ?? '';
    final ts = m['ts'] ?? '';
    final bg = isUser ? Colors.blue.shade100 : Colors.grey.shade100;
    final align = isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6.0, horizontal: 12.0),
      child: Column(crossAxisAlignment: align, children: [
        Container(
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: SelectableText(text)),
            if (!isUser) ...[
              const SizedBox(width: 8),
              IconButton(
                icon: Icon(Icons.volume_up, color: _isSpeaking ? Colors.green : Colors.black54),
                onPressed: () async {
                  await _speak(text);
                },
                tooltip: 'Play reply',
              ),
            ],
          ]),
        ),
        const SizedBox(height: 6),
        Row(mainAxisSize: MainAxisSize.min, children: [
          if (ts != '')
            Text(_formatTs(ts), style: const TextStyle(fontSize: 11, color: Colors.black38)),
          const SizedBox(width: 8),
          Text(isUser ? 'You' : 'Assistant', style: const TextStyle(fontSize: 11, color: Colors.black54)),
        ])
      ]),
    );
  }

  String _formatTs(String iso) {
    try {
      final dt = DateTime.parse(iso).toLocal();
      return "${dt.year}-${_pad2(dt.month)}-${_pad2(dt.day)} ${_pad2(dt.hour)}:${_pad2(dt.minute)}";
    } catch (_) {
      return '';
    }
  }

  String _pad2(int v) => v.toString().padLeft(2, '0');

  @override
  Widget build(BuildContext context) {
    final micColor = _isListening ? Colors.redAccent : Theme.of(context).colorScheme.primary;
    return WillPopScope(
      onWillPop: _onWillPop,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Expense Assistant'),
          actions: [
            Row(children: [
              const Text('Auto-Speak'),
              Switch(value: _autoSpeak, onChanged: (v) => setState(() => _autoSpeak = v)),
              const SizedBox(width: 6),
            ]),
            PopupMenuButton<String>(
              onSelected: (s) async {
                if (s == 'stop') await _stopAll();
                if (s == 'clear') await _clearHistoryConfirm();
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'stop', child: Text('Stop speech')),
                const PopupMenuItem(value: 'clear', child: Text('Clear chat history')),
              ],
            ),
          ],
        ),
        body: Column(children: [
          Expanded(
            child: Container(
              color: Colors.transparent,
              child: ListView.builder(
                controller: _scroll,
                padding: const EdgeInsets.symmetric(vertical: 12),
                itemCount: _messages.length,
                itemBuilder: (_, i) => _buildMessageBubble(_messages[i]),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 6),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    const Text('Rate', style: TextStyle(fontSize: 12)),
                    Expanded(
                      child: Slider(
                        value: _ttsRate,
                        min: 0.2,
                        max: 1.0,
                        divisions: 8,
                        label: _ttsRate.toStringAsFixed(2),
                        onChanged: (v) {
                          setState(() => _ttsRate = v);
                        },
                      ),
                    ),
                  ]),
                  Row(children: [
                    const Text('Pitch', style: TextStyle(fontSize: 12)),
                    Expanded(
                      child: Slider(
                        value: _ttsPitch,
                        min: 0.6,
                        max: 1.6,
                        divisions: 10,
                        label: _ttsPitch.toStringAsFixed(2),
                        onChanged: (v) {
                          setState(() => _ttsPitch = v);
                        },
                      ),
                    ),
                  ]),
                ]),
              ),
            ]),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    controller: _inputCtl,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _sendMessage(),
                    decoration: InputDecoration(
                      hintText: _speechAvailable ? 'Type or press mic to speak' : 'Type your question',
                      filled: true,
                      fillColor: Colors.white,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    ),
                    maxLines: null,
                  ),
                ),
                const SizedBox(width: 8),
                Column(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(
                    icon: Icon(_isListening ? Icons.mic : Icons.mic_none, color: micColor),
                    iconSize: 32,
                    onPressed: () async {
                      if (_isListening) {
                        await _stopListening();
                      } else {
                        await _startListening();
                      }
                    },
                  ),
                  const SizedBox(height: 4),
                  FilledButton(
                    onPressed: _isSending ? null : _sendMessage,
                    child: _isSending ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.send),
                  ),
                ]),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}
