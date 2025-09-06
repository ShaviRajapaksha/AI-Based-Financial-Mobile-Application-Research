import 'dart:convert';
import 'package:flutter/material.dart';
import '../../services/api_service.dart';
import 'news_article_detail.dart';
import '../../services/auth_service.dart';

class NewsScreen extends StatefulWidget {
  const NewsScreen({super.key});
  @override
  State<NewsScreen> createState() => _NewsScreenState();
}

class _NewsScreenState extends State<NewsScreen> {
  final ApiService _api = ApiService();
  final _qCtl = TextEditingController(text: "finance markets");
  bool _loading = false;
  String? _error;
  List<Map<String, dynamic>> _items = [];
  String _source = '';
  int _totalResults = 0;
  Map<String, dynamic>? _lastRaw;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool showLoading = true}) async {
    if (showLoading) setState(() { _loading = true; _error = null; });
    try {
      final res = await _api.fetchNewsRaw(q: _qCtl.text.trim(), page: 1, pageSize: 50);
      final items = (res['items'] as List).cast<Map<String, dynamic>>();
      setState(() {
        _items = items;
        _source = res['source']?.toString() ?? '';
        _totalResults = (res['totalResults'] is int) ? res['totalResults'] as int : int.tryParse(res['totalResults'].toString()) ?? items.length;
        _lastRaw = res['raw'] as Map<String, dynamic>?;
      });
      debugPrint('News loaded: ${_items.length} items, source=$_source, total=$_totalResults');
    } catch (e, st) {
      debugPrint('News load failed: $e\n$st');
      setState(() { _error = e.toString(); _items = []; _source = ''; _totalResults = 0; _lastRaw = null; });
    } finally {
      if (showLoading) setState(() { _loading = false; });
    }
  }

  Widget _tile(Map<String, dynamic> a) {
    final title = a['title'] ?? '';
    final desc = a['description'] ?? '';
    final image = a['url_to_image'];
    final bookmarked = a['bookmarked'] == true;
    return Card(
      child: ListTile(
        leading: image != null
            ? Image.network(image, width: 64, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Icon(Icons.image))
            : const Icon(Icons.article),
        title: Text(title),
        subtitle: Text((desc ?? '').replaceAll(RegExp(r'<[^>]*>'), ''), maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: Icon(bookmarked ? Icons.bookmark : Icons.bookmark_border, color: bookmarked ? Colors.amber : null),
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => NewsArticleDetail(articleId: a['id'], externalUrl: a['url']))).then((_) => _load()),
      ),
    );
  }

  void _showRawJson() {
    if (_lastRaw == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No raw response captured yet')));
      return;
    }
    final pretty = const JsonEncoder.withIndent('  ').convert(_lastRaw);
    showDialog(context: context, builder: (_) => AlertDialog(
      title: const Text('Raw JSON (preview)'),
      content: SizedBox(width: double.maxFinite, height: 400, child: SingleChildScrollView(child: SelectableText(pretty))),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close'))],
    ));
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return Center(child: Text('Error loading news:\n$_error', textAlign: TextAlign.center, style: const TextStyle(color: Colors.red)));
    if (_items.isEmpty) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('No articles found', style: TextStyle(fontSize: 16)),
        const SizedBox(height: 8),
        Text('Source: ${_source.isEmpty ? "n/a" : _source}    Total: $_totalResults'),
        const SizedBox(height: 12),
        FilledButton(onPressed: () => _load(), child: const Text('Retry')),
        const SizedBox(height: 8),
        OutlinedButton(onPressed: _showRawJson, child: const Text('Show raw response')),
      ]));
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.all(8),
        itemCount: _items.length,
        itemBuilder: (_, i) => _tile(_items[i]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = AuthService.user;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Investment News'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: () => _load()),
          IconButton(icon: const Icon(Icons.code), onPressed: _showRawJson),
          if (user != null) IconButton(icon: const Icon(Icons.bookmarks), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const _BookmarksScreen())).then((_) => _load())),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(children: [
          Row(children: [
            Expanded(child: TextField(controller: _qCtl, decoration: const InputDecoration(labelText: 'Search'))),
            const SizedBox(width: 8),
            FilledButton(onPressed: () => _load(), child: const Text('Search')),
          ]),
          const SizedBox(height: 8),
          if (_source.isNotEmpty || _totalResults > 0)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6.0),
              child: Row(children: [
                Text('Source: $_source'),
                const SizedBox(width: 12),
                Text('Total: $_totalResults'),
                const Spacer(),
              ]),
            ),
          Expanded(child: _body()),
        ]),
      ),
    );
  }
}

/* Bookmarks screen (same as before) */
class _BookmarksScreen extends StatefulWidget {
  const _BookmarksScreen({super.key});
  @override
  State<_BookmarksScreen> createState() => _BookmarksScreenState();
}

class _BookmarksScreenState extends State<_BookmarksScreen> {
  final ApiService _api = ApiService();
  bool _loading = true;
  List<Map<String, dynamic>> _items = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final res = await _api.listBookmarks();
      setState(() => _items = res);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Load bookmarks failed: $e')));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Bookmarks')),
      body: _loading ? const Center(child: CircularProgressIndicator()) : ListView.builder(
        itemCount: _items.length,
        itemBuilder: (_, i) {
          final item = _items[i];
          final bm = item['bookmark'] as Map<String, dynamic>;
          final art = item['article'] as Map<String, dynamic>?;
          return ListTile(
            title: Text(art?['title'] ?? bm['article_id'].toString()),
            subtitle: Text(art?['description'] ?? ''),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => NewsArticleDetail(articleId: art != null ? art['id'] as int : bm['article_id'], externalUrl: art?['url']))).then((_) => _load()),
            trailing: IconButton(icon: const Icon(Icons.delete), onPressed: () async {
              try {
                await _api.deleteBookmark(bm['id'] as int);
                await _load();
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Delete failed: $e')));
              }
            }),
          );
        },
      ),
    );
  }
}
