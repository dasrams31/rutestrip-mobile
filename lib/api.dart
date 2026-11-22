import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Client for https://rutestrip.ai.id: /api/v1 (docs/API.md) and the SSO API (docs/SSO.md).
class Api {
  /// Production by default. Test builds can point at a local backend:
  /// flutter run --dart-define=RUTESTRIP_API=http://127.0.0.1:8000 (debug builds only allow cleartext to localhost).
  static const baseUrl = String.fromEnvironment('RUTESTRIP_API', defaultValue: 'https://rutestrip.ai.id');

  final http.Client _client = http.Client();
  String lang = 'id';
  String? token;

  /// Called when the server rejects the token (expired, password changed, logged out everywhere).
  void Function()? onUnauthorized;

  Map<String, String> get _headers => {
    'Accept': 'application/json',
    'Accept-Language': lang,
    'User-Agent': 'RuteStripAndroid/1.0 (+https://rutestrip.ai.id)',
    if (token != null) 'Authorization': 'Bearer $token',
  };

  Future<dynamic> _send(String method, String path, {Map<String, dynamic>? body, Duration timeout = const Duration(seconds: 20)}) async {
    final uri = Uri.parse('$baseUrl$path');
    http.Response res;
    try {
      final req = switch (method) {
        'GET' => _client.get(uri, headers: _headers),
        'DELETE' => _client.delete(uri, headers: _headers),
        'PUT' => _client.put(uri, headers: {..._headers, 'Content-Type': 'application/json'}, body: jsonEncode(body ?? {})),
        _ => _client.post(uri, headers: {..._headers, 'Content-Type': 'application/json'}, body: jsonEncode(body ?? {})),
      };
      res = await req.timeout(timeout);
    } on SocketException {
      throw const ApiException(ApiError.network);
    } on TimeoutException {
      throw const ApiException(ApiError.network);
    } on http.ClientException {
      throw const ApiException(ApiError.network);
    }

    return _decode(res);
  }

  dynamic _decode(http.Response res) {
    dynamic data;
    try {
      data = res.body.isEmpty ? null : jsonDecode(res.body);
    } catch (_) {
      data = null;
    }

    if (res.statusCode >= 200 && res.statusCode < 300) return data;

    final map = data is Map ? data : const {};
    final err = map['error']?.toString();
    final isCode = err != null && RegExp(r'^[a-z_]+$').hasMatch(err);
    // Laravel's own throttle answer ("Too Many Attempts.") is English only: use the app's sentence instead.
    final message = res.statusCode == 429 && err == null ? null : (isCode ? map['message'] : (err ?? map['message']))?.toString();
    final fieldErrors = <String, String>{};
    if (map['errors'] is Map) {
      (map['errors'] as Map).forEach((k, v) {
        if (v is List && v.isNotEmpty) fieldErrors['$k'] = '${v.first}';
      });
    }
    if (res.statusCode == 401 && token != null) onUnauthorized?.call();
    final kind = switch (res.statusCode) {
      401 => ApiError.unauthorized,
      403 => ApiError.forbidden,
      404 => ApiError.notFound,
      422 => ApiError.validation,
      429 => ApiError.throttled,
      _ => ApiError.server,
    };
    throw ApiException(kind, status: res.statusCode, message: message, fieldErrors: fieldErrors);
  }

  // --- routes ---------------------------------------------------------------

  Future<RoutePage> routes({int page = 1, String? mountain, String? province}) async {
    final q = {'page': '$page', 'per_page': '20', 'mountain': ?mountain, 'province': ?province};
    final data = await _send('GET', '/api/v1/routes?${Uri(queryParameters: q).query}') as Map;
    final meta = data['meta'] as Map;
    return RoutePage(
      routes: (data['data'] as List).map((e) => RouteSummary.fromJson(e as Map)).toList(),
      page: meta['current_page'] as int,
      lastPage: meta['last_page'] as int,
      total: meta['total'] as int,
    );
  }

  Future<Filters> filters() async => Filters.fromJson(await _send('GET', '/api/v1/filters') as Map);

  Future<RouteDetail> route(int id) async => RouteDetail.fromJson(await routeJson(id));

  /// The detail as the server sent it, so it can be saved for offline use.
  Future<Map<String, dynamic>> routeJson(int id) async => Map<String, dynamic>.from((await _send('GET', '/api/v1/routes/$id') as Map)['data'] as Map);

  Future<SearchResult> search(String query, {bool allRoutes = false}) async {
    final data = await _send('POST', '/api/v1/search', body: {'query': query, if (allRoutes) 'all_routes': true}, timeout: const Duration(seconds: 60));
    return SearchResult.fromJson(data as Map);
  }

  Future<(bool, int)> setLike(int routeId, bool liked) async {
    final data = await _send('POST', '/api/v1/routes/$routeId/like', body: {'liked': liked}) as Map;
    return (data['liked'] == true, (data['count'] as num).toInt());
  }

  Future<List<RouteSummary>> likes() async {
    final data = await _send('GET', '/api/v1/likes') as Map;
    return (data['data'] as List).map((e) => RouteSummary.fromJson(e as Map)).toList();
  }

  // --- route page extras ----------------------------------------------------------

  Future<Reviews> reviews(int routeId) async => Reviews.fromJson(await _send('GET', '/api/v1/routes/$routeId/reviews') as Map);

  Future<Reviews> writeReview(int routeId, int rating, String? comment) async => Reviews.fromJson(
    await _send(
      'POST',
      '/api/v1/routes/$routeId/reviews',
      body: {'rating': rating, if (comment != null && comment.trim().isNotEmpty) 'comment': comment.trim()},
    ) as Map,
  );

  Future<Conditions> conditions(int routeId) async =>
      Conditions.fromJson(await _send('GET', '/api/v1/routes/$routeId/conditions', timeout: const Duration(seconds: 30)) as Map);

  Future<List<GpxVersionInfo>> versions(int routeId) async =>
      ((await _send('GET', '/api/v1/routes/$routeId/versions') as Map)['data'] as List).map((e) => GpxVersionInfo.fromJson(e as Map)).toList();

  // --- account -------------------------------------------------------------------

  Future<Dashboard> dashboard() async => Dashboard.fromJson(await _send('GET', '/api/v1/me') as Map);

  Future<(List<SearchEntry>, int lastPage)> history({int page = 1}) async {
    final data = await _send('GET', '/api/v1/me/history?page=$page') as Map;
    return ((data['data'] as List).map((e) => SearchEntry.fromJson(e as Map)).toList(), ((data['meta'] as Map)['last_page'] as num).toInt());
  }

  Future<AppUser> updateProfile(String name, String email) async =>
      AppUser.fromJson((await _send('PUT', '/api/v1/me/profile', body: {'name': name, 'email': email}) as Map)['user'] as Map);

  /// Returns the new token: the old one stops working on the server.
  Future<AuthResult> updatePassword(String current, String password, String confirmation) async => AuthResult.fromJson(
    await _send('PUT', '/api/v1/me/password', body: {'current_password': current, 'password': password, 'password_confirmation': confirmation}) as Map,
  );

  Future<void> updateLocale(String locale) async => _send('PUT', '/api/v1/me/locale', body: {'locale': locale});

  Future<void> logoutEverywhere() async => _send('POST', '/api/v1/me/logout-all');

  // --- GPX upload ------------------------------------------------------------------

  /// Multipart POST /api/v1/routes. Processing on the server can take a while.
  Future<(RouteSummary, String)> upload({required String name, String? description, required String path, bool cleanTrack = true}) async {
    final req = http.MultipartRequest('POST', Uri.parse('$baseUrl/api/v1/routes'))
      ..headers.addAll(_headers)
      ..fields['name'] = name
      ..fields['clean_track'] = cleanTrack ? '1' : '0';
    if (description != null && description.trim().isNotEmpty) req.fields['description'] = description.trim();
    req.files.add(await http.MultipartFile.fromPath('gpx_file', path));

    http.Response res;
    try {
      res = await http.Response.fromStream(await _client.send(req).timeout(const Duration(minutes: 3)));
    } on SocketException {
      throw const ApiException(ApiError.network);
    } on TimeoutException {
      throw const ApiException(ApiError.network);
    } on http.ClientException {
      throw const ApiException(ApiError.network);
    }
    final data = _decode(res);
    return (RouteSummary.fromJson((data as Map)['data'] as Map), '${data['message'] ?? ''}');
  }

  // --- community chat (Obrolan Pendaki) and assistant -----------------------------

  Future<ChatPage> messages({int? after, int? before}) async {
    final q = {'after': ?after?.toString(), 'before': ?before?.toString()};
    final data = await _send('GET', '/api/v1/community/messages${q.isEmpty ? '' : '?${Uri(queryParameters: q).query}'}') as Map;
    return ChatPage.fromJson(data);
  }

  Future<ChatMessage> sendMessage(String body) async =>
      ChatMessage.fromJson((await _send('POST', '/api/v1/community/messages', body: {'body': body}) as Map)['message'] as Map);

  Future<ChatMessage> deleteMessage(int id) async => ChatMessage.fromJson((await _send('DELETE', '/api/v1/community/messages/$id') as Map)['message'] as Map);

  Future<ChatMessage> reportMessage(int id) async =>
      ChatMessage.fromJson((await _send('POST', '/api/v1/community/messages/$id/report') as Map)['message'] as Map);

  /// Asisten RuteStrip. History items: {role: user|assistant, text}.
  Future<String> ask(String message, List<Map<String, String>> history) async {
    final data = await _send('POST', '/api/v1/assistant', body: {'message': message, 'history': history}, timeout: const Duration(seconds: 45)) as Map;
    return '${data['reply'] ?? ''}';
  }

  // --- account (SSO) -------------------------------------------------------------

  Future<AuthResult> login(String email, String password) async =>
      AuthResult.fromJson(await _send('POST', '/api/sso/login', body: {'email': email, 'password': password}) as Map);

  Future<AppUser> me() async => AppUser.fromJson((await _send('GET', '/api/sso/me') as Map)['user'] as Map);

  /// Register needs the same proof-of-work check as the website form (ALTCHA).
  Future<AuthResult> register({required String name, required String email, required String password, required String confirmation}) async {
    final challenge = await _send('GET', '/altcha/challenge') as Map;
    final altcha = await compute(solveAltcha, Map<String, dynamic>.from(challenge));
    final data = await _send(
      'POST',
      '/api/sso/register',
      body: {'name': name, 'email': email, 'password': password, 'password_confirmation': confirmation, 'website': '', 'altcha': altcha},
    );
    return AuthResult.fromJson(data as Map);
  }
}

/// Finds n with sha256(salt + n) == challenge and returns the base64 payload ALTCHA expects.
String solveAltcha(Map<String, dynamic> c) {
  final salt = c['salt'] as String;
  final target = c['challenge'] as String;
  final max = (c['maxnumber'] as num?)?.toInt() ?? 1000000;
  for (var n = 0; n <= max; n++) {
    if (sha256.convert(utf8.encode('$salt$n')).toString() == target) {
      return base64.encode(
        utf8.encode(jsonEncode({'algorithm': c['algorithm'] ?? 'SHA-256', 'challenge': target, 'number': n, 'salt': salt, 'signature': c['signature']})),
      );
    }
  }
  throw const ApiException(ApiError.server);
}

enum ApiError { network, unauthorized, forbidden, notFound, validation, throttled, server }

class ApiException implements Exception {
  const ApiException(this.kind, {this.status, this.message, this.fieldErrors = const {}});

  final ApiError kind;
  final int? status;
  final String? message;
  final Map<String, String> fieldErrors;

  @override
  String toString() => 'ApiException($kind, $status, $message)';
}

double? _d(dynamic v) => v is num ? v.toDouble() : null;
int? _i(dynamic v) => v is num ? v.toInt() : null;

List<List<double>> _points(dynamic v) => v is List
    ? v.whereType<List>().where((p) => p.length >= 2 && p[0] is num && p[1] is num).map((p) => [(p[0] as num).toDouble(), (p[1] as num).toDouble()]).toList()
    : const [];

class RouteSummary {
  RouteSummary.fromJson(Map j)
    : id = (j['id'] as num).toInt(),
      name = '${j['name'] ?? ''}',
      mountain = j['mountain'] as String?,
      basecamp = j['basecamp'] as String?,
      province = j['province'] as String?,
      regency = j['regency'] as String?,
      distanceKm = _d(j['distance_km']),
      gainM = _i(j['elevation_gain_m']),
      hours = _d(j['naismith_duration_hour']),
      durationLabel = '${j['duration_label'] ?? ''}',
      summitRoute = j['summit_route'] != false,
      gradePct = _d(j['average_grade_pct']),
      steepestPct = _d(j['steepest_grade_pct']),
      maxElevationM = _i(j['max_elevation_m']),
      difficulty = '${j['difficulty_level'] ?? ''}',
      difficultyLabel = '${j['difficulty_label'] ?? j['difficulty_level'] ?? ''}',
      likes = _i(j['likes_count']) ?? 0,
      track = _points(j['track']),
      webUrl = '${j['web_url'] ?? Api.baseUrl}',
      similarity = _d(j['similarity_score']),
      matchLabel = j['match_label'] as String?,
      why = j['why'] as String?;

  final int id;
  final String name;
  final String? mountain, basecamp, province, regency;
  final double? distanceKm, hours, gradePct, steepestPct;
  final int? gainM, maxElevationM;
  final String durationLabel;
  final bool summitRoute;
  final String difficulty, difficultyLabel;
  final int likes;
  final List<List<double>> track;
  final String webUrl;
  final double? similarity;
  final String? matchLabel, why;

  /// 1 to 4 bars, as on the website.
  int get difficultyStep => switch (difficulty) {
    'Mudah' => 1,
    'Sedang' => 2,
    'Sulit' => 3,
    _ => 4,
  };

  String? get place => [regency, province].whereType<String>().where((s) => s.isNotEmpty).join(', ').ifEmptyNull();
}

extension on String {
  String? ifEmptyNull() => isEmpty ? null : this;
}

class TrailPoint {
  TrailPoint.fromJson(Map j)
    : name = j['name'] as String?,
      lat = (j['lat'] as num).toDouble(),
      lng = (j['lng'] as num).toDouble(),
      elevationM = _i(j['elevation_m']);

  final String? name;
  final double lat, lng;
  final int? elevationM;
}

class RouteDetail extends RouteSummary {
  RouteDetail.fromJson(super.j)
    : description = j['description'] as String?,
      narrative = j['narrative_text'] as String?,
      difficultyHint = j['difficulty_hint'] as String?,
      naismithNote = j['naismith_note'] as String?,
      coordinates = _points(j['coordinates']),
      basecampPoint = j['basecamp_point'] is Map ? TrailPoint.fromJson(j['basecamp_point'] as Map) : null,
      summitPoint = j['summit_point'] is Map ? TrailPoint.fromJson(j['summit_point'] as Map) : null,
      profile = _points(j['elevation_profile']),
      liked = j['liked'] == true,
      uploader = j['uploader'] as String?,
      averageRating = _d(j['average_rating']),
      reviewCount = _i(j['review_count']) ?? 0,
      gpxStatus = j['gpx_status'] as String?,
      practical = j['practical'] is Map ? Map<String, dynamic>.from(j['practical'] as Map) : const {},
      similar = (j['similar'] as List? ?? const []).map((e) => RouteSummary.fromJson(e as Map)).toList(),
      super.fromJson();

  final String? description, narrative, difficultyHint, naismithNote;
  final List<List<double>> coordinates;
  final TrailPoint? basecampPoint, summitPoint;
  final List<List<double>> profile; // [km, m]
  final bool liked;
  final List<RouteSummary> similar;
  final String? uploader, gpxStatus;
  final double? averageRating;
  final int reviewCount;
  final Map<String, dynamic> practical;
}

class RoutePage {
  RoutePage({required this.routes, required this.page, required this.lastPage, required this.total});

  final List<RouteSummary> routes;
  final int page, lastPage, total;
}

class NameCount {
  NameCount(this.name, this.count);

  final String name;
  final int count;
}

class Filters {
  Filters.fromJson(Map j)
    : mountains = (j['mountains'] as List).map((e) => NameCount('${e['name']}', (e['count'] as num).toInt())).toList(),
      provinces = (j['provinces'] as List).map((e) => NameCount('${e['name']}', (e['count'] as num).toInt())).toList(),
      examples = (j['examples'] as List).map((e) => '$e').toList(),
      totalRoutes = (j['total_routes'] as num).toInt();

  final List<NameCount> mountains, provinces;
  final List<String> examples;
  final int totalRoutes;
}

class SearchResult {
  SearchResult.fromJson(Map j)
    : query = '${j['query'] ?? ''}',
      results = (j['results'] as List? ?? const []).map((e) => RouteSummary.fromJson(e as Map)).toList(),
      message = j['message'] as String?,
      filterLine = (j['explanation'] as Map?)?['filter_line'] as String?,
      sortLine = (j['explanation'] as Map?)?['sort_line'] as String?,
      alsoLine = (j['explanation'] as Map?)?['also_line'] as String?,
      notice = (j['explanation'] as Map?)?['notice'] as String?,
      canSearchAll = (j['explanation'] as Map?)?['can_search_all'] == true,
      searchAllLabel = (j['explanation'] as Map?)?['search_all_label'] as String?,
      allRoutes = (j['plan'] as Map?)?['all_routes'] == true;

  final String query;
  final List<RouteSummary> results;
  final String? message, filterLine, sortLine, alsoLine, notice, searchAllLabel;
  final bool canSearchAll, allRoutes;
}

class AppUser {
  AppUser.fromJson(Map j) : id = (j['id'] as num).toInt(), name = '${j['name'] ?? ''}', email = '${j['email'] ?? ''}', locale = j['locale'] as String?;

  final int id;
  final String name, email;
  final String? locale;

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'email': email, 'locale': locale};
}

class AuthResult {
  AuthResult.fromJson(Map j) : token = j['token'] as String, user = AppUser.fromJson(j['user'] as Map);

  final String token;
  final AppUser user;
}

class ChatMessage {
  ChatMessage.fromJson(Map j)
    : id = (j['id'] as num).toInt(),
      name = '${j['name'] ?? ''}',
      mine = j['mine'] == true,
      deleted = j['deleted'] == true,
      body = j['body'] as String?,
      createdAt = DateTime.tryParse('${j['created_at'] ?? ''}')?.toLocal(),
      canDelete = j['can_delete'] == true,
      canReport = j['can_report'] == true,
      reported = j['reported'] == true;

  final int id;
  final String name;
  final bool mine, deleted, canDelete, canReport, reported;
  final String? body;
  final DateTime? createdAt;
}

class ChatPage {
  ChatPage.fromJson(Map j)
    : messages = (j['messages'] as List? ?? const []).map((e) => ChatMessage.fromJson(e as Map)).toList(),
      hasMore = j['has_more'] == true,
      deleted = (j['deleted'] as List? ?? const []).map((e) => (e as num).toInt()).toSet();

  final List<ChatMessage> messages;
  final bool hasMore;
  final Set<int> deleted;
}

class Review {
  Review.fromJson(Map j)
    : name = '${j['name'] ?? ''}',
      rating = _i(j['rating']),
      comment = j['comment'] as String?,
      createdAt = DateTime.tryParse('${j['created_at'] ?? ''}')?.toLocal();

  final String name;
  final int? rating;
  final String? comment;
  final DateTime? createdAt;
}

class Reviews {
  Reviews.fromJson(Map j)
    : average = _d(j['average_rating']),
      count = _i(j['review_count']) ?? 0,
      mine = _i(j['my_rating']),
      items = (j['reviews'] as List? ?? const []).map((e) => Review.fromJson(e as Map)).toList();

  final double? average;
  final int count;
  final int? mine;
  final List<Review> items;
}

class Weather {
  Weather.fromJson(Map j)
    : text = j['weather_text'] as String?,
      temperature = _d(j['temperature_c']),
      feels = _d(j['apparent_temperature_c']),
      humidity = _d(j['humidity_pct']),
      rain = _d(j['precipitation_mm']),
      wind = _d(j['wind_speed_kmh']),
      gusts = _d(j['wind_gusts_kmh']),
      windFrom = j['wind_direction'] as String?,
      elevation = _i(j['elevation_m']);

  final String? text, windFrom;
  final double? temperature, feels, humidity, rain, wind, gusts;
  final int? elevation;
}

class Conditions {
  Conditions.fromJson(Map j)
    : location = (j['location'] as Map?)?['label'] as String?,
      basecamp = j['points'] is Map && (j['points'] as Map)['basecamp'] is Map ? TrailPoint.fromJson((j['points'] as Map)['basecamp'] as Map) : null,
      directionsUrl = j['points'] is Map ? (((j['points'] as Map)['basecamp'] as Map?)?['directions_url'] as String?) : null,
      basecampWeather = (j['weather'] as Map?)?['basecamp'] is Map ? Weather.fromJson((j['weather'] as Map)['basecamp'] as Map) : null,
      summitWeather = (j['weather'] as Map?)?['summit'] is Map ? Weather.fromJson((j['weather'] as Map)['summit'] as Map) : null,
      updated = (j['weather'] as Map?)?['updated_label'] as String?,
      sunrise = (j['weather'] as Map?)?['sunrise'] as String?,
      sunset = (j['weather'] as Map?)?['sunset'] as String?,
      caution = (j['safety'] as Map?)?['level'] == 'caution',
      safety = ((j['safety'] as Map?)?['messages'] as List? ?? const []).map((e) => '$e').toList();

  final String? location, directionsUrl, updated, sunrise, sunset;
  final TrailPoint? basecamp;
  final Weather? basecampWeather, summitWeather;
  final bool caution;
  final List<String> safety;
}

class GpxVersionInfo {
  GpxVersionInfo.fromJson(Map j)
    : version = _i(j['version']) ?? 0,
      active = j['active'] == true,
      status = j['status'] as String?,
      statusLabel = j['status_label'] as String?,
      hash = '${j['hash'] ?? ''}',
      changeLog = j['change_log'] as String?,
      uploader = '${j['uploader'] ?? ''}',
      createdAt = DateTime.tryParse('${j['created_at'] ?? ''}')?.toLocal(),
      downloadUrl = j['download_url'] as String?;

  final int version;
  final bool active;
  final String? status, statusLabel, changeLog, downloadUrl;
  final String hash, uploader;
  final DateTime? createdAt;
}

class SearchEntry {
  SearchEntry.fromJson(Map j)
    : query = '${j['query'] ?? ''}',
      results = _i(j['results_count']) ?? 0,
      createdAt = DateTime.tryParse('${j['created_at'] ?? ''}')?.toLocal();

  final String query;
  final int results;
  final DateTime? createdAt;
}

class Dashboard {
  Dashboard.fromJson(Map j)
    : user = AppUser.fromJson(j['user'] as Map),
      favorites = _i((j['stats'] as Map)['favorites']) ?? 0,
      searches = _i((j['stats'] as Map)['searches']) ?? 0,
      comments = _i((j['stats'] as Map)['comments']) ?? 0,
      ratings = _i((j['stats'] as Map)['ratings']) ?? 0,
      recent = {
        // The same phrase searched twice shows once.
        for (final e in (j['recent_searches'] as List? ?? const [])) '${(e as Map)['query']}'.trim().toLowerCase(): SearchEntry.fromJson(e),
      }.values.toList();

  final AppUser user;
  final int favorites, searches, comments, ratings;
  final List<SearchEntry> recent;
}
