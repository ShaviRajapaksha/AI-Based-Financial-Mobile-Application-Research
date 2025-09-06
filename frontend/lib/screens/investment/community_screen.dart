import 'dart:async';
import 'package:flutter/material.dart';
import '../../services/api_service.dart';
import 'community_post_detail.dart';

class CommunityScreen extends StatefulWidget {
  const CommunityScreen({super.key});
  @override
  State<CommunityScreen> createState() => _CommunityScreenState();
}

class _CommunityScreenState extends State<CommunityScreen> {
  final ApiService _api = ApiService();
  final ScrollController _scroll = ScrollController();
  final TextEditingController _searchCtl = TextEditingController();

  List<Map<String, dynamic>> _posts = [];
  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _page = 1;
  final int _pageSize = 20;
  String _query = "";

  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _loadInitial();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _searchCtl.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onScroll() {
    if (!_hasMore || _loadingMore || _loading) return;
    if (_scroll.position.pixels >= (_scroll.position.maxScrollExtent - 160)) {
      _loadMore();
    }
  }

  Future<void> _loadInitial({String? query}) async {
    _debounce?.cancel();
    setState(() {
      _loading = true;
      _page = 1;
      _hasMore = true;
      if (query != null) _query = query;
    });
    try {
      final uri = "/api/community/posts?page=$_page&page_size=$_pageSize${_query.isNotEmpty ? '&q=${Uri.encodeComponent(_query)}' : ''}";
      final resp = await _api.get(uri);
      // resp expected { items: [...], total: n, page: , page_size: }
      final items = List<Map<String, dynamic>>.from(resp['items'] as List? ?? []);
      setState(() {
        _posts = items;
        _hasMore = (items.length == _pageSize);
      });
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Load failed: $e')));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadMore() async {
    if (!_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      _page += 1;
      final uri = "/api/community/posts?page=$_page&page_size=$_pageSize${_query.isNotEmpty ? '&q=${Uri.encodeComponent(_query)}' : ''}";
      final resp = await _api.get(uri);
      final items = List<Map<String, dynamic>>.from(resp['items'] as List? ?? []);
      setState(() {
        _posts.addAll(items);
        _hasMore = (items.length == _pageSize);
      });
    } catch (e) {
      _page -= 1;
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Load more failed: $e')));
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _refresh() async {
    await _loadInitial();
  }

  Future<void> _createPostDialog() async {
    final titleCtl = TextEditingController();
    final bodyCtl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New Post'),
        content: SizedBox(
          height: 280,
          child: Column(children: [
            TextField(controller: titleCtl, decoration: const InputDecoration(labelText: 'Title')),
            const SizedBox(height: 8),
            Expanded(child: TextField(controller: bodyCtl, decoration: const InputDecoration(labelText: 'Body'), maxLines: null, expands: true)),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Post')),
        ],
      ),
    );
    if (ok != true) return;
    final title = titleCtl.text.trim();
    final body = bodyCtl.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Title required')));
      return;
    }
    try {
      await _api.createCommunityPost(title, body);
      await _loadInitial();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Posted')));
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Create failed: $e')));
    }
  }

  Future<void> _onSearchChanged(String value) async {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 450), () {
      _loadInitial(query: value);
    });
  }

  Future<void> _voteTogglePost(int index, int desired) async {
    // desired is 1 for up, -1 for down
    final post = _posts[index];
    final prev = (post['user_vote'] ?? 0) as int;
    int sendValue;
    if (prev == desired) {
      sendValue = 0; // toggle off
    } else {
      sendValue = desired;
    }
    final oldScore = (post['vote_score'] ?? 0) as int;

    // optimistic update
    setState(() {
      post['user_vote'] = sendValue;
      post['vote_score'] = oldScore - prev + sendValue;
    });

    try {
      await _api.post('/api/community/posts/${post['id']}/vote', body: {'value': sendValue});
      // server returns new score usually; optionally re-fetch item to sync
    } catch (e) {
      // revert on error
      setState(() {
        post['user_vote'] = prev;
        post['vote_score'] = oldScore;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Vote failed: $e')));
    }
  }

  Widget _buildPostTile(Map<String, dynamic> p, int index) {
    final title = p['title'] ?? '';
    final author = p['author_name'] ?? p['author_email'] ?? 'User';
    final commentCount = p['comment_count'] ?? 0;
    final score = p['vote_score'] ?? 0;
    final userVote = (p['user_vote'] ?? 0) as int;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: ListTile(
        title: Text(title),
        subtitle: Text('$author • $commentCount comments • Score: $score'),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(
            icon: Icon(Icons.thumb_up, color: userVote == 1 ? Colors.green : Colors.black54),
            onPressed: () => _voteTogglePost(index, 1),
            tooltip: 'Upvote',
          ),
          IconButton(
            icon: Icon(Icons.thumb_down, color: userVote == -1 ? Colors.red : Colors.black54),
            onPressed: () => _voteTogglePost(index, -1),
            tooltip: 'Downvote',
          ),
        ]),
        onTap: () async {
          await Navigator.push(context, MaterialPageRoute(builder: (_) => CommunityPostDetail(postId: p['id'] as int)));
          // refresh single item after returning
          await _loadInitial(query: _query);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Community'),
        actions: [
          IconButton(icon: const Icon(Icons.add), onPressed: _createPostDialog),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(52),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8),
            child: TextField(
              controller: _searchCtl,
              textInputAction: TextInputAction.search,
              onSubmitted: (v) => _loadInitial(query: v),
              onChanged: _onSearchChanged,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: 'Search posts',
                suffixIcon: IconButton(icon: const Icon(Icons.clear), onPressed: () {
                  _searchCtl.clear();
                  _loadInitial(query: "");
                }),
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
        onRefresh: _refresh,
        child: ListView.builder(
          controller: _scroll,
          padding: const EdgeInsets.all(8),
          itemCount: _posts.length + (_hasMore ? 1 : 0),
          itemBuilder: (ctx, i) {
            if (i < _posts.length) return _buildPostTile(_posts[i], i);
            // loading indicator at list end
            if (_loadingMore) {
              return const Padding(padding: EdgeInsets.symmetric(vertical: 16), child: Center(child: CircularProgressIndicator()));
            } else {
              // trigger load more when visible
              _loadMore();
              return const Padding(padding: EdgeInsets.symmetric(vertical: 16), child: Center(child: CircularProgressIndicator()));
            }
          },
        ),
      ),
    );
  }
}