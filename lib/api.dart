import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Client for https://rutestrip.ai.id: /api/v1 (docs/API.md) and the SSO API (docs/SSO.md).
class Api {
  static const baseUrl = 'https://rutestrip.ai.id';

  final http.Client _client = http.Client();
  String lang = 'id';
  String? token;

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
      final req = method == 'GET'
          ? _client.get(uri, headers: _headers)
          : _client.post(uri, headers: {..._headers, 'Content-Type': 'application/json'}, body: jsonEncode(body ?? {}));
      res = await req.timeout(timeout);
    } on SocketException {
      throw const ApiException(ApiError.network);
    } on TimeoutException {
      throw const ApiException(ApiError.network);
    } on http.ClientException {
      throw const ApiException(ApiError.network);
    }

    dynamic data;
    try {
      data = res.body.isEmpty ? null : jsonDecode(res.body);
    } catch (_) {
      data = null;
    }

    if (res.statusCode >= 200 && res.statusCode < 300) return data;

    final map = data is Map ? data : const {};
    final message = (map['error'] ?? map['message'])?.toString();
    final fieldErrors = <String, String>{};
    if (map['errors'] is Map) {
      (map['errors'] as Map).forEach((k, v) {
        if (v is List && v.isNotEmpty) fieldErrors['$k'] = '${v.first}';
      });
    }
    final kind = switch (res.statusCode) {
      401 => ApiError.unauthorized,
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

  Future<RouteDetail> route(int id) async => RouteDetail.fromJson((await _send('GET', '/api/v1/routes/$id') as Map)['data'] as Map);

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

enum ApiError { network, unauthorized, notFound, validation, throttled, server }

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
      similar = (j['similar'] as List? ?? const []).map((e) => RouteSummary.fromJson(e as Map)).toList(),
      super.fromJson();

  final String? description, narrative, difficultyHint, naismithNote;
  final List<List<double>> coordinates;
  final TrailPoint? basecampPoint, summitPoint;
  final List<List<double>> profile; // [km, m]
  final bool liked;
  final List<RouteSummary> similar;
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
  AppUser.fromJson(Map j) : id = (j['id'] as num).toInt(), name = '${j['name'] ?? ''}', email = '${j['email'] ?? ''}';

  final int id;
  final String name, email;
}

class AuthResult {
  AuthResult.fromJson(Map j) : token = j['token'] as String, user = AppUser.fromJson(j['user'] as Map);

  final String token;
  final AppUser user;
}
