import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../services/api_service.dart';
import '../../services/auth_service.dart';

class NewsArticleDetail extends StatefulWidget {
  final int? articleId;
  final String? externalUrl; // fallback open url if no articleId
  const NewsArticleDetail({super.key, this.articleId, this.externalUrl});
  @override
  State<NewsArticleDetail> createState() => _NewsArticleDetailState();
}

class _NewsArticleDetailState extends State<NewsArticleDetail> {
  final ApiService _api = ApiService();
  Map<String, dynamic>? _article;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    if (widget.articleId != null) _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final res = await _api.fetchArticle(widget.articleId!);
      setState(() => _article = res);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Load failed: $e')));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _bookmark() async {
    try {
      if (_article != null && _article!['id'] != null) {
        await _api.bookmarkArticle(articleId: _article!['id'] as int);
      } else if (widget.externalUrl != null) {
        await _api.bookmarkArticle(url: widget.externalUrl!, title: _article?['title']);
      }
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Bookmarked')));
      await _load();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Bookmark failed: $e')));
    }
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not open URL')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final art = _article;
    return Scaffold(
      appBar: AppBar(title: Text(art?['title'] ?? 'Article'), actions: [
        IconButton(icon: const Icon(Icons.bookmark_add), onPressed: _bookmark),
      ]),
      body: _loading ? const Center(child: CircularProgressIndicator()) : Padding(
        padding: const EdgeInsets.all(12),
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (art != null && art['url_to_image'] != null) Image.network(art['url_to_image'], errorBuilder: (_, __, ___) => const SizedBox.shrink()),
            const SizedBox(height: 8),
            Text(art?['title'] ?? '', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(art?['description'] ?? ''),
            const SizedBox(height: 12),
            Text(art?['content'] ?? ''),
            const SizedBox(height: 16),
            if ((art?['url'] ?? widget.externalUrl) != null) FilledButton.icon(
              onPressed: () => _openUrl(art?['url'] ?? widget.externalUrl!),
              icon: const Icon(Icons.open_in_browser),
              label: const Text('Open full article'),
            )
          ]),
        ),
      ),
    );
  }
}