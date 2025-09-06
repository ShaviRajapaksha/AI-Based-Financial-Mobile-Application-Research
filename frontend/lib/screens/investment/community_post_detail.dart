import 'dart:async';
import 'package:flutter/material.dart';
import '../../services/api_service.dart';
import '../../services/auth_service.dart';

class CommunityPostDetail extends StatefulWidget {
  final int postId;
  const CommunityPostDetail({super.key, required this.postId});
  @override
  State<CommunityPostDetail> createState() => _CommunityPostDetailState();
}

class _CommunityPostDetailState extends State<CommunityPostDetail> {
  final ApiService _api = ApiService();
  final ScrollController _scroll = ScrollController();
  final TextEditingController _commentCtl = TextEditingController();

  Map<String, dynamic>? _post;
  List<Map<String, dynamic>> _comments = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _commentsPage = 1;
  final int _commentsPageSize = 30;

  @override
  void initState() {
    super.initState();
    _loadPage();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _commentCtl.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_hasMore || _loadingMore || _loading) return;
    if (_scroll.position.pixels >= (_scroll.position.maxScrollExtent - 160)) {
      _loadMoreComments();
    }
  }

  Future<void> _loadPage({bool refresh = false}) async {
    if (refresh) {
      _commentsPage = 1;
      _hasMore = true;
      _comments.clear();
    }
    setState(() => _loading = true);
    try {
      final uri = "/api/community/posts/${widget.postId}?comments_page=$_commentsPage&comments_page_size=$_commentsPageSize";
      final resp = await _api.get(uri);
      // resp: { post: {...}, comments: [...], comments_page, comments_total ... }
      setState(() {
        if (resp['post'] != null) {
          _post = Map<String, dynamic>.from(resp['post'] as Map);
        }
        final items = List<Map<String, dynamic>>.from(resp['comments'] as List? ?? []);
        if (_commentsPage == 1) {
          _comments = items;
        } else {
          _comments.addAll(items);
        }
        _hasMore = (items.length == _commentsPageSize);
      });
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Load failed: $e')));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadMoreComments() async {
    if (!_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      _commentsPage += 1;
      final uri = "/api/community/posts/${widget.postId}?comments_page=$_commentsPage&comments_page_size=$_commentsPageSize";
      final resp = await _api.get(uri);
      final items = List<Map<String, dynamic>>.from(resp['comments'] as List? ?? []);
      setState(() {
        _comments.addAll(items);
        _hasMore = (items.length == _commentsPageSize);
      });
    } catch (e) {
      _commentsPage -= 1;
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Load more comments failed: $e')));
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _togglePostVote(int desired) async {
    if (_post == null) return;
    final prev = (_post!['user_vote'] ?? 0) as int;
    final send = (prev == desired) ? 0 : desired;
    final oldScore = (_post!['vote_score'] ?? 0) as int;
    setState(() {
      _post!['user_vote'] = send;
      _post!['vote_score'] = oldScore - prev + send;
    });
    try {
      await _api.post('/api/community/posts/${_post!['id']}/vote', body: {'value': send});
    } catch (e) {
      setState(() {
        _post!['user_vote'] = prev;
        _post!['vote_score'] = oldScore;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Vote failed: $e')));
    }
  }

  Future<void> _toggleCommentVote(int commentIndex, int desired) async {
    final comment = _comments[commentIndex];
    final prev = (comment['user_vote'] ?? 0) as int;
    final send = (prev == desired) ? 0 : desired;
    final oldScore = (comment['vote_score'] ?? 0) as int;

    // optimistic
    setState(() {
      comment['user_vote'] = send;
      comment['vote_score'] = oldScore - prev + send;
    });

    try {
      await _api.post('/api/community/posts/${widget.postId}/comments/${comment['id']}/vote', body: {'value': send});
    } catch (e) {
      // revert
      setState(() {
        comment['user_vote'] = prev;
        comment['vote_score'] = oldScore;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Vote failed: $e')));
    }
  }

  Future<void> _addComment() async {
    final text = _commentCtl.text.trim();
    if (text.isEmpty) return;
    setState(() => _loading = true);
    try {
      final res = await _api.createCommunityComment(widget.postId, text);
      // server returns created comment
      // prepend to list for immediate feedback
      setState(() {
        _comments.insert(0, res);
        _post!['comment_count'] = ((_post!['comment_count'] ?? 0) as int) + 1;
        _commentCtl.clear();
      });
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Comment failed: $e')));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Widget _buildHeader() {
    if (_post == null) return const SizedBox.shrink();
    final title = _post!['title'] ?? '';
    final author = _post!['author_name'] ?? _post!['author_email'] ?? 'User';
    final score = _post!['vote_score'] ?? 0;
    final userVote = (_post!['user_vote'] ?? 0) as int;

    return Card(
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text('By $author • Score: $score • ${_post!['comment_count'] ?? 0} comments', style: const TextStyle(color: Colors.black54)),
          const SizedBox(height: 12),
          if ((_post!['body'] ?? "").toString().isNotEmpty) Text(_post!['body'] ?? ''),
          const SizedBox(height: 12),
          Row(children: [
            IconButton(icon: Icon(Icons.thumb_up, color: userVote == 1 ? Colors.green : Colors.black54), onPressed: () => _togglePostVote(1)),
            IconButton(icon: Icon(Icons.thumb_down, color: userVote == -1 ? Colors.red : Colors.black54), onPressed: () => _togglePostVote(-1)),
            const Spacer(),
            Text('Score: ${_post!['vote_score'] ?? 0}'),
          ])
        ]),
      ),
    );
  }

  Widget _buildCommentTile(Map<String, dynamic> c, int index) {
    final author = c['author_name'] ?? c['author_email'] ?? 'User';
    final score = c['vote_score'] ?? 0;
    final userVote = (c['user_vote'] ?? 0) as int;
    final body = c['body'] ?? '';

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: ListTile(
        title: Text(body),
        subtitle: Text('by $author • ${c['created_at'] ?? ''}'),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          Text('$score'),
          const SizedBox(width: 8),
          IconButton(icon: Icon(Icons.thumb_up, color: userVote == 1 ? Colors.green : Colors.black54), onPressed: () => _toggleCommentVote(index, 1)),
          IconButton(icon: Icon(Icons.thumb_down, color: userVote == -1 ? Colors.red : Colors.black54), onPressed: () => _toggleCommentVote(index, -1)),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_post?['title'] ?? 'Post'),
      ),
      body: _loading && _post == null
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
        Expanded(
          child: RefreshIndicator(
            onRefresh: () async {
              _commentsPage = 1;
              _hasMore = true;
              await _loadPage(refresh: true);
            },
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.only(bottom: 12),
              itemCount: 1 + _comments.length + (_hasMore ? 1 : 0),
              itemBuilder: (ctx, i) {
                if (i == 0) return _buildHeader();
                final idx = i - 1;
                if (idx < _comments.length) return _buildCommentTile(_comments[idx], idx);
                // load more indicator
                if (_loadingMore) {
                  return const Padding(padding: EdgeInsets.symmetric(vertical: 16), child: Center(child: CircularProgressIndicator()));
                } else {
                  // trigger load more (optimistic)
                  _loadMoreComments();
                  return const Padding(padding: EdgeInsets.symmetric(vertical: 16), child: Center(child: CircularProgressIndicator()));
                }
              },
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: _commentCtl,
                decoration: const InputDecoration(hintText: 'Write a comment...', border: OutlineInputBorder(), contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10)),
                minLines: 1,
                maxLines: 4,
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(onPressed: _addComment, child: const Icon(Icons.send)),
          ]),
        ),
      ]),
    );
  }
}