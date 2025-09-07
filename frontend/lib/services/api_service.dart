import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'config_service.dart';
import 'auth_service.dart';

class ApiService {
  ApiService();

  String _url(String path) => "${ConfigService.baseUrl}$path";

  Map<String, String> _baseHeaders() {
    final headers = {'Accept': 'application/json'};
    final auth = AuthService.authHeader();
    if (auth.isNotEmpty) headers.addAll(auth);
    return headers;
  }

  Future<Map<String, dynamic>> getHealth() async {
    final uri = Uri.parse(_url('/api/health'));
    final r = await http.get(uri, headers: _baseHeaders());
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getCategories() async {
    final uri = Uri.parse(_url('/api/categories'));
    final r = await http.get(uri);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> login(String email, String password) async {
    final uri = Uri.parse(_url('/api/auth/login'));
    final r = await http.post(uri, headers: {'Content-Type': 'application/json'}, body: jsonEncode({'email': email, 'password': password}));
    if (r.statusCode >= 400) throw Exception(r.body);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> register(String email, String password, String? name) async {
    final uri = Uri.parse(_url('/api/auth/register'));
    final r = await http.post(uri, headers: {'Content-Type': 'application/json'}, body: jsonEncode({'email': email, 'password': password, 'name': name}));
    if (r.statusCode >= 400) throw Exception(r.body);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> updateProfile({String? name, String? oldPassword, String? newPassword}) async {
    final uri = Uri.parse(_url('/api/auth/update-profile'));
    final payload = <String, dynamic>{};
    if (name != null) payload['name'] = name;
    if (oldPassword != null) payload['old_password'] = oldPassword;
    if (newPassword != null) payload['new_password'] = newPassword;

    final r = await http.post(uri, headers: {..._baseHeaders(), 'Content-Type': 'application/json'}, body: jsonEncode(payload));
    if (r.statusCode >= 400) throw Exception(r.body);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> uploadForOCR(File file) async {
    final uri = Uri.parse(_url('/api/ocr/upload'));
    final req = http.MultipartRequest('POST', uri)
      ..headers.addAll(_baseHeaders())
      ..files.add(await http.MultipartFile.fromPath('file', file.path));
    final streamed = await req.send();
    final body = await streamed.stream.bytesToString();
    if (streamed.statusCode >= 400) {
      throw Exception(body);
    }
    return jsonDecode(body) as Map<String, dynamic>;
  }

  // Uploads a file from bytes
  Future<Map<String, dynamic>> uploadForOCRBytes(Uint8List bytes, String filename, {String mime = 'image/jpeg'}) async {
    final uri = Uri.parse(_url('/api/ocr/upload'));
    final req = http.MultipartRequest('POST', uri);
    // Add auth header to MultipartRequest
    req.headers.addAll(_baseHeaders());
    final safeName = filename.contains('.') ? filename : '$filename.jpg';
    final parts = mime.split('/');
    final contentType = parts.length == 2 ? MediaType(parts[0], parts[1]) : MediaType('image', 'jpeg');
    final multipartFile = http.MultipartFile.fromBytes('file', bytes, filename: safeName, contentType: contentType);
    req.files.add(multipartFile);
    final streamed = await req.send();
    final body = await streamed.stream.bytesToString();
    if (streamed.statusCode >= 400) throw Exception(body);
    return jsonDecode(body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> uploadForOCRFile(File file) async {
    final uri = Uri.parse(_url('/api/ocr/upload'));
    final req = http.MultipartRequest('POST', uri)
      ..headers.addAll(_baseHeaders())
      ..files.add(await http.MultipartFile.fromPath('file', file.path));
    final streamed = await req.send();
    final body = await streamed.stream.bytesToString();
    if (streamed.statusCode >= 400) {
      throw Exception('Server error ${streamed.statusCode}: $body');
    }
    return jsonDecode(body) as Map<String, dynamic>;
  }

  Future<List<Map<String, dynamic>>> listEntries({String? type}) async {
    var url = _url('/api/entries');
    if (type != null) url = _url('/api/entries?entry_type=$type');
    final r = await http.get(Uri.parse(url), headers: _baseHeaders());
    final data = jsonDecode(r.body) as Map<String, dynamic>;
    return (data['items'] as List).cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> createEntry(Map<String, dynamic> payload) async {
    final r = await http.post(Uri.parse(_url('/api/entries')), headers: {..._baseHeaders(), 'Content-Type': 'application/json'}, body: jsonEncode(payload));
    if (r.statusCode >= 400) throw Exception(r.body);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// GET: /api/predict/money_in_hand/<userId>
  Future<Map<String, dynamic>> getMoneyInHandForecast(int userId) async {
    final uri = Uri.parse(_url('/api/predict/money_in_hand/$userId'));
    final r = await http.get(uri, headers: _baseHeaders());
    if (r.statusCode >= 400) throw Exception('Forecast API: ${r.statusCode} ${r.body}');
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// GET: /api/predict/monthly_series/<userId>
  Future<List<Map<String, dynamic>>> getMonthlySeries(int userId) async {
    final uri = Uri.parse(_url('/api/predict/monthly_series/$userId'));
    final r = await http.get(uri, headers: _baseHeaders());
    if (r.statusCode >= 400) throw Exception('Monthly series API: ${r.statusCode} ${r.body}');
    final payload = jsonDecode(r.body) as Map<String, dynamic>;
    final list = (payload['series'] as List<dynamic>?) ?? [];
    return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  /// POST: /api/predict/retrain/<userId>
  /// schedules background retrain for the user; useful for manual re-compute
  Future<Map<String, dynamic>> retrainUserModel(int userId) async {
    final uri = Uri.parse(_url('/api/predict/retrain/$userId'));
    final r = await http.post(uri, headers: _baseHeaders());
    if (r.statusCode >= 400) throw Exception('Retrain API: ${r.statusCode} ${r.body}');
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  // Stocks / commodities / suggestions / news / community - add these methods:

  // Stock forecast: GET /api/invest/stock_forecast/<symbol>
  Future<Map<String, dynamic>> stockForecast(String symbol) async {
    final uri = Uri.parse(_url('/api/invest/stock_forecast/${Uri.encodeComponent(symbol)}'));
    final r = await http.get(uri, headers: _baseHeaders());
    if (r.statusCode >= 400) throw Exception('Stock forecast error ${r.statusCode}');
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  // Commodity forecast
  Future<Map<String, dynamic>> commodityForecast(String symbol) async {
    final uri = Uri.parse(_url('/api/invest/commodity_forecast/${Uri.encodeComponent(symbol)}'));
    final r = await http.get(uri, headers: _baseHeaders());
    if (r.statusCode >= 400) throw Exception('Commodity forecast error ${r.statusCode}');
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  // News
  Future<List<Map<String, dynamic>>> fetchInvestNews() async {
    final uri = Uri.parse(_url('/api/invest/news'));
    final r = await http.get(uri, headers: _baseHeaders());
    if (r.statusCode >= 400) throw Exception('News error ${r.statusCode}');
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return (j['articles'] as List<dynamic>? ?? []).map((e) => Map<String, dynamic>.from(e)).toList();
  }

  // Fetch paginated community posts (supports search q)
  Future<Map<String, dynamic>> fetchCommunityPosts({int page = 1, int pageSize = 20, String q = ""}) async {
    final uri = Uri.parse(_url('/api/community/posts?page=$page&page_size=$pageSize${q.isNotEmpty ? '&q=${Uri.encodeComponent(q)}' : ''}'));
    final r = await http.get(uri, headers: _baseHeaders());
    if (r.statusCode >= 400) throw Exception('Fetch posts failed: ${r.statusCode} ${r.body}');
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  // Create a new post
  Future<Map<String, dynamic>> createCommunityPost(String title, String body) async {
    final uri = Uri.parse(_url('/api/community/posts'));
    final r = await http.post(uri, headers: {..._baseHeaders(), 'Content-Type': 'application/json'}, body: jsonEncode({'title': title, 'body': body}));
    if (r.statusCode >= 400) throw Exception('Create post failed: ${r.statusCode} ${r.body}');
    return jsonDecode(r.body) as Map<String, dynamic>;
  }



  // Update post (owner only)
  Future<Map<String, dynamic>> updateCommunityPost(int postId, {required String title, String? body}) async {
    final uri = Uri.parse(_url('/api/community/posts/$postId'));
    final r = await http.post(uri, headers: {..._baseHeaders(), 'Content-Type': 'application/json'}, body: jsonEncode({'title': title, 'body': body}));
    if (r.statusCode >= 400) throw Exception('Update post failed: ${r.statusCode} ${r.body}');
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// Delete post (owner only)
  Future<void> deleteCommunityPost(int postId) async {
    final uri = Uri.parse(_url('/api/community/posts/$postId/delete'));
    final r = await http.post(uri, headers: _baseHeaders());
    if (r.statusCode >= 400) throw Exception('Delete post failed: ${r.statusCode} ${r.body}');
  }

  /// Fetch single post + paginated comments
  Future<Map<String, dynamic>> fetchCommunityPostDetail(int postId, {int commentsPage = 1, int commentsPageSize = 50}) async {
    final uri = Uri.parse(_url('/api/community/posts/$postId?comments_page=$commentsPage&comments_page_size=$commentsPageSize'));
    final r = await http.get(uri, headers: _baseHeaders());
    if (r.statusCode >= 400) throw Exception('Fetch post detail failed: ${r.statusCode} ${r.body}');
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// Create comment
  Future<Map<String, dynamic>> createCommunityComment(int postId, String body) async {
    final uri = Uri.parse(_url('/api/community/posts/$postId/comments'));
    final r = await http.post(uri, headers: {..._baseHeaders(), 'Content-Type': 'application/json'}, body: jsonEncode({'body': body}));
    if (r.statusCode >= 400) throw Exception('Create comment failed: ${r.statusCode} ${r.body}');
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// Vote on post (value -1|0|1) -> returns { status, post_id, vote_score, user_vote }
  Future<Map<String, dynamic>> votePostApi(int postId, int value) async {
    final uri = Uri.parse(_url('/api/community/posts/$postId/vote'));
    final r = await http.post(uri, headers: {..._baseHeaders(), 'Content-Type': 'application/json'}, body: jsonEncode({'value': value}));
    if (r.statusCode >= 400) throw Exception('Vote post failed: ${r.statusCode} ${r.body}');
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// Vote on comment (value -1|0|1) -> returns { status, comment_id, vote_score, user_vote }
  Future<Map<String, dynamic>> voteCommentApi(int postId, int commentId, int value) async {
    final uri = Uri.parse(_url('/api/community/posts/$postId/comments/$commentId/vote'));
    final r = await http.post(uri, headers: {..._baseHeaders(), 'Content-Type': 'application/json'}, body: jsonEncode({'value': value}));
    if (r.statusCode >= 400) throw Exception('Vote comment failed: ${r.statusCode} ${r.body}');
    return jsonDecode(r.body) as Map<String, dynamic>;
  }



  // create suggestion
  Future<Map<String, dynamic>> createInvestmentPlan(int userId, String goal, double targetAmount, int horizonMonths, String riskProfile, {String? notes}) async {
    final uri = Uri.parse(_url('/api/invest/suggestion/$userId'));
    final body = {
      "goal": goal,
      "target_amount": targetAmount,
      "horizon_months": horizonMonths,
      "risk_profile": riskProfile,
      "notes": notes,
    };
    final r = await http.post(uri, headers: {..._baseHeaders(), 'Content-Type': 'application/json'}, body: jsonEncode(body));
    if (r.statusCode >= 400) throw Exception('Create plan failed: ${r.statusCode} ${r.body}');
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  // list user's plans
  Future<List<Map<String, dynamic>>> listInvestmentPlans(int userId) async {
    final uri = Uri.parse(_url('/api/invest/suggestions/$userId'));
    final r = await http.get(uri, headers: _baseHeaders());
    if (r.statusCode >= 400) throw Exception('List plans failed: ${r.statusCode}');
    final arr = jsonDecode(r.body) as List<dynamic>;
    return arr.map((e) => Map<String,dynamic>.from(e)).toList();
  }

  // get single plan
  Future<Map<String, dynamic>> getInvestmentPlan(int userId, int planId) async {
    final uri = Uri.parse(_url('/api/invest/suggestions/$userId/$planId'));
    final r = await http.get(uri, headers: _baseHeaders());
    if (r.statusCode >= 400) throw Exception('Get plan failed: ${r.statusCode}');
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  // delete plan
  Future<void> deleteInvestmentPlan(int userId, int planId) async {
    final uri = Uri.parse(_url('/api/invest/suggestions/$userId/$planId'));
    final r = await http.delete(uri, headers: _baseHeaders());
    if (r.statusCode >= 400) throw Exception('Delete plan failed: ${r.statusCode} ${r.body}');
  }

  Future<Map<String, dynamic>> createInvestmentPlanSimple({
    required String goal,
    required double targetAmount,
    required int horizonMonths,
    required String riskProfile,
    String? notes,
  }) async {
    final uri = Uri.parse(_url('/api/invest/suggestion'));
    final body = {
      "goal": goal,
      "target_amount": targetAmount,
      "horizon_months": horizonMonths,
      "risk_profile": riskProfile,
      if (notes != null) "notes": notes,
    };
    final r = await http.post(uri,
      headers: {..._baseHeaders(), 'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    if (r.statusCode >= 400) {
      // try to include server body for debugging
      String txt = r.body;
      throw Exception('Create plan failed (${r.statusCode}): $txt');
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  // GET /api/invest/news?q=...&page=1&page_size=20
  Future<List<Map<String, dynamic>>> fetchNews({String q = "finance markets", int page = 1, int pageSize = 20}) async {
    final uri = Uri.parse(_url('/api/invest/news?q=${Uri.encodeComponent(q)}&page=$page&page_size=$pageSize'));
    final r = await http.get(uri, headers: _baseHeaders());
    if (r.statusCode >= 400) throw Exception('News fetch failed: ${r.statusCode} ${r.body}');
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    final items = (j['items'] as List<dynamic>? ?? []);
    return items.map((e) => Map<String, dynamic>.from(e)).toList();
  }

  // GET single article
  Future<Map<String, dynamic>> fetchArticle(int articleId) async {
    final uri = Uri.parse(_url('/api/invest/news/$articleId'));
    final r = await http.get(uri, headers: _baseHeaders());
    if (r.statusCode >= 400) throw Exception('Article fetch failed: ${r.statusCode} ${r.body}');
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  // POST bookmark {article_id} or {url,...}
  Future<Map<String, dynamic>> bookmarkArticle({int? articleId, String? url, String? title, String? description}) async {
    final uri = Uri.parse(_url('/api/invest/news/bookmark'));
    final body = <String, dynamic>{};
    if (articleId != null) body['article_id'] = articleId;
    if (url != null) body['url'] = url;
    if (title != null) body['title'] = title;
    if (description != null) body['description'] = description;
    final r = await http.post(uri, headers: {..._baseHeaders(), 'Content-Type': 'application/json'}, body: jsonEncode(body));
    if (r.statusCode >= 400) throw Exception('Bookmark failed: ${r.statusCode} ${r.body}');
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  // GET bookmarks
  Future<List<Map<String, dynamic>>> listBookmarks() async {
    final uri = Uri.parse(_url('/api/invest/news/bookmarks'));
    final r = await http.get(uri, headers: _baseHeaders());
    if (r.statusCode >= 400) throw Exception('List bookmarks failed: ${r.statusCode} ${r.body}');
    final arr = jsonDecode(r.body) as List<dynamic>;
    return arr.map((e) => Map<String, dynamic>.from(e)).toList();
  }

  // DELETE bookmark by id
  Future<void> deleteBookmark(int bookmarkId) async {
    final uri = Uri.parse(_url('/api/invest/news/bookmarks/$bookmarkId'));
    final r = await http.delete(uri, headers: _baseHeaders());
    if (r.statusCode >= 400) throw Exception('Delete bookmark failed: ${r.statusCode} ${r.body}');
  }

  // Add this method into your ApiService class
  Future<Map<String, dynamic>> fetchNewsRaw({
    String q = "finance markets",
    int page = 1,
    int pageSize = 50,
  }) async {
    final uri = Uri.parse(_url('/api/invest/news?q=${Uri.encodeComponent(q)}&page=$page&page_size=$pageSize'));
    final headers = _baseHeaders();
    debugPrint('API: fetchNews -> GET $uri, headers: $headers');
    final resp = await http.get(uri, headers: headers).timeout(const Duration(seconds: 20));
    debugPrint('API fetchNews status=${resp.statusCode}');
    // print up to first 2000 chars of body to avoid console spam
    final bodyPreview = resp.body.length > 2000 ? resp.body.substring(0, 2000) + '...(truncated)' : resp.body;
    debugPrint('API fetchNews body (preview): $bodyPreview');

    if (resp.statusCode >= 400) {
      throw Exception('News fetch failed ${resp.statusCode}: ${resp.body}');
    }
    final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
    final items = List<Map<String, dynamic>>.from((decoded['items'] as List? ?? []).map((e) => Map<String, dynamic>.from(e)));
    return {
      'items': items,
      'source': decoded['source'] ?? 'unknown',
      'totalResults': decoded['totalResults'] ?? items.length,
      'raw': decoded, // keep raw for debugging UI
    };
  }

  Future<List<Map<String, dynamic>>> listStockDatasets() async {
    final uri = Uri.parse(_url('/api/invest/stock/datasets'));
    debugPrint('API: listStockDatasets -> GET $uri');
    final r = await http.get(uri, headers: _baseHeaders()).timeout(const Duration(seconds: 20));
    if (r.statusCode >= 400) throw Exception('Datasets fetch failed: ${r.statusCode} ${r.body}');
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    final ds = (j['datasets'] as List<dynamic>?) ?? [];
    return ds.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<Map<String, dynamic>> previewStockDataset(String filename, {int n = 200}) async {
    final uri = Uri.parse(_url('/api/invest/stock/preview?filename=${Uri.encodeComponent(filename)}&n=$n'));
    debugPrint('API: previewStockDataset -> GET $uri');
    final r = await http.get(uri, headers: _baseHeaders()).timeout(const Duration(seconds: 20));
    if (r.statusCode >= 400) throw Exception('Preview failed: ${r.statusCode} ${r.body}');
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return j;
  }

  Future<Map<String, dynamic>> forecastStock({
    required String filename,
    int futureDays = 183,
    int epochs = 40,
    int timeStep = 60,
    int batchSize = 32,
    int hiddenSize = 64,
  }) async {
    final uri = Uri.parse(_url('/api/invest/stock/forecast'));
    final body = jsonEncode({
      "filename": filename,
      "future_days": futureDays,
      "epochs": epochs,
      "time_step": timeStep,
      "batch_size": batchSize,
      "hidden_size": hiddenSize,
    });
    debugPrint('API: forecastStock -> POST $uri body: $body');
    final r = await http.post(uri, headers: {..._baseHeaders(), 'Content-Type': 'application/json'}, body: body).timeout(const Duration(seconds: 600)); // training can be slow
    if (r.statusCode >= 400) throw Exception('Forecast failed: ${r.statusCode} ${r.body}');
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return j;
  }

  /*
  Map<String, String> _baseHeaders() {
    // if you already have auth token management, include Authorization header
    final Map<String, String> headers = {};
    final token = AuthService.token; // adapt to your auth service
    if (token != null) headers['Authorization'] = 'Bearer $token';
    return headers;
  }
  */

  Future<dynamic> get(String path) async {
    final uri = Uri.parse(_url(path));
    final r = await http.get(uri, headers: _baseHeaders());
    if (r.statusCode >= 400) throw Exception('${r.statusCode}: ${r.body}');
    return jsonDecode(r.body);
  }

  Future<dynamic> post(String path, {Map<String, dynamic>? body}) async {
    final uri = Uri.parse(_url(path));
    final r = await http.post(uri, headers: {..._baseHeaders(), 'Content-Type': 'application/json'}, body: jsonEncode(body ?? {}));
    if (r.statusCode >= 400) throw Exception('${r.statusCode}: ${r.body}');
    return jsonDecode(r.body);
  }

  /// NEW: delete helper supporting optional JSON body
  Future<dynamic> delete(String path, {Map<String, dynamic>? body}) async {
    final uri = Uri.parse(_url(path));

    if (body == null) {
      final r = await http.delete(uri, headers: _baseHeaders());
      if (r.statusCode >= 400) throw Exception('${r.statusCode}: ${r.body}');
      if (r.body.isEmpty) return {};
      return jsonDecode(r.body);
    } else {
      // use a streamed Request to include a JSON body with DELETE
      final req = http.Request('DELETE', uri);
      req.headers.addAll({..._baseHeaders(), 'Content-Type': 'application/json'});
      req.body = jsonEncode(body);
      final streamed = await req.send().timeout(const Duration(seconds: 30));
      final resp = await http.Response.fromStream(streamed);
      if (resp.statusCode >= 400) throw Exception('${resp.statusCode}: ${resp.body}');
      if (resp.body.isEmpty) return {};
      return jsonDecode(resp.body);
    }
  }

  Future<Map<String, dynamic>> getCreditScore() async {
    final r = await get('/api/credit/score');
    return Map<String, dynamic>.from(r);
  }

  Future<Map<String, dynamic>> refreshCreditScore() async {
    final r = await post('/api/credit/refresh');
    return Map<String, dynamic>.from(r);
  }

  Future<List<Map<String, dynamic>>> listCreditBadges() async {
    final r = await get('/api/credit/badges');
    final arr = (r['badges'] as List<dynamic>?) ?? [];
    return arr.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  // Generate a debt report (returns metadata)
  Future<Map<String, dynamic>> generateDebtReport({String? name, String? start, String? end}) async {
    final uri = Uri.parse(_url('/api/debt/reports'));
    final body = <String, dynamic>{};
    if (name != null) body['name'] = name;
    if (start != null) body['start'] = start;
    if (end != null) body['end'] = end;
    final r = await http.post(uri, headers: {..._baseHeaders(), 'Content-Type': 'application/json'}, body: jsonEncode(body));
    if (r.statusCode >= 400) throw Exception('Generate report failed: ${r.statusCode} ${r.body}');
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  // List user reports
  Future<List<Map<String, dynamic>>> listDebtReports() async {
    final uri = Uri.parse(_url('/api/debt/reports'));
    final r = await http.get(uri, headers: _baseHeaders());
    if (r.statusCode >= 400) throw Exception('List reports failed: ${r.statusCode} ${r.body}');
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    final items = (j['items'] as List<dynamic>? ?? []);
    return items.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<Uint8List> downloadDebtReport(int reportId) async {
    final uri = Uri.parse(_url('/api/debt/reports/$reportId/download'));
    final r = await http.get(uri, headers: _baseHeaders()); // <-- Uses your auth headers
    if (r.statusCode >= 400) {
      throw Exception('Download failed: ${r.statusCode} ${r.body}');
    }
    return r.bodyBytes;
  }



  // Savings Goals
  Future<List<Map<String, dynamic>>> listSavingsGoals() async {
    final uri = Uri.parse(_url('/api/expense/goals'));
    final r = await http.get(uri, headers: _baseHeaders());
    if (r.statusCode >= 400) throw Exception('List goals failed: ${r.statusCode} ${r.body}');
    final j = jsonDecode(r.body) as List<dynamic>;
    return j.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<Map<String, dynamic>> createSavingsGoal({
    required String name,
    required double targetAmount,
    String? targetDateIso,
    String? notes,
  }) async {
    final uri = Uri.parse(_url('/api/expense/goals'));
    final body = {
      'name': name,
      'target_amount': targetAmount,
      if (targetDateIso != null) 'target_date': targetDateIso,
      if (notes != null) 'notes': notes,
    };
    final r = await http.post(uri, headers: {..._baseHeaders(), 'Content-Type':'application/json'}, body: jsonEncode(body));
    if (r.statusCode >= 400) throw Exception('Create goal failed: ${r.statusCode} ${r.body}');
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getSavingsGoal(int goalId) async {
    final uri = Uri.parse(_url('/api/expense/goals/$goalId'));
    final r = await http.get(uri, headers: _baseHeaders());
    if (r.statusCode >= 400) throw Exception('Get goal failed: ${r.statusCode} ${r.body}');
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> contributeToGoal(int goalId, double amount, {String? dateIso, String? notes}) async {
    final uri = Uri.parse(_url('/api/expense/goals/$goalId/contribute'));
    final body = {
      'amount': amount,
      if (dateIso != null) 'date': dateIso,
      if (notes != null) 'notes': notes,
    };
    final r = await http.post(uri, headers: {..._baseHeaders(), 'Content-Type': 'application/json'}, body: jsonEncode(body));
    if (r.statusCode >= 400) throw Exception('Contribute failed: ${r.statusCode} ${r.body}');
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

// Reports
  Future<Map<String, dynamic>> createSavingsReport({required int goalId, String? name}) async {
    final uri = Uri.parse(_url('/api/expense/reports'));
    final body = {'goal_id': goalId, if (name != null) 'name': name};
    final r = await http.post(uri, headers: {..._baseHeaders(), 'Content-Type':'application/json'}, body: jsonEncode(body));
    if (r.statusCode >= 400) throw Exception('Create report failed: ${r.statusCode} ${r.body}');
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  Future<List<Map<String, dynamic>>> listSavingsReports() async {
    final uri = Uri.parse(_url('/api/expense/reports'));
    final r = await http.get(uri, headers: _baseHeaders());
    if (r.statusCode >= 400) throw Exception('List reports failed: ${r.statusCode} ${r.body}');
    final arr = jsonDecode(r.body) as List<dynamic>;
    return arr.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  String savingsReportDownloadUrl(int reportId) {
    final base = ConfigService.baseUrl ?? '';
    final p = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    return '$p/api/expense/reports/$reportId/download';
  }

// Suggestions
  Future<Map<String, dynamic>> fetchSavingsSuggestions() async {
    final uri = Uri.parse(_url('/api/expense/suggestions'));
    final r = await http.get(uri, headers: _baseHeaders());
    if (r.statusCode >= 400) throw Exception('Suggestions failed: ${r.statusCode} ${r.body}');
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// POST /api/invest/compute
  Future<Map<String, dynamic>> computeInvestmentPlan({
    required String goal,
    required double targetAmount,
    required int horizonMonths,
    required String riskProfile,
  }) async {
    final uri = Uri.parse(_url('/api/invest/compute'));
    final body = jsonEncode({
      "goal": goal,
      "target_amount": targetAmount,
      "horizon_months": horizonMonths,
      "risk_profile": riskProfile,
    });
    debugPrint('API: computeInvestmentPlan -> POST $uri body: $body');
    final r = await http.post(uri, headers: {..._baseHeaders(), 'Content-Type': 'application/json'}, body: body).timeout(const Duration(seconds: 30));
    if (r.statusCode >= 400) throw Exception('Compute failed: ${r.statusCode} ${r.body}');
    return jsonDecode(r.body) as Map<String, dynamic>;
  }
}
