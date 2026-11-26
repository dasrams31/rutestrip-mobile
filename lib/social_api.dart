part of 'api.dart';

/// Linimasa (social timeline): the client side of D:\dev\notes\social_api.md.
/// A part of api.dart so it can use the same private request helpers.
extension SocialApi on Api {
  Future<SocialPage<Post>> feed({String scope = 'following', String? cursor}) async =>
      SocialPage.fromJson(await _send('GET', '/api/v1/feed?${_query({'scope': scope, 'cursor': cursor})}') as Map, Post.fromJson);

  Future<List<StoryGroup>> stories() async => _list((await _send('GET', '/api/v1/stories') as Map)['data'], StoryGroup.fromJson);

  /// Multipart POST /posts. The same client_id sent again returns the post made the first time.
  Future<Post> createPost(PostDraft d) async {
    final req = http.MultipartRequest('POST', Uri.parse('${Api.baseUrl}/api/v1/posts'))
      ..headers.addAll(_headers)
      ..fields['type'] = d.type
      ..fields['client_id'] = d.clientId;
    if (d.body != null && d.body!.trim().isNotEmpty) req.fields['body'] = d.body!.trim();
    if (d.track != null) req.fields['track'] = jsonEncode(d.track);
    if (d.stats != null) req.fields['stats'] = jsonEncode(d.stats!.toJson());
    if (d.place != null) req.fields['place'] = jsonEncode(d.place!.toJson());
    if (d.routeId != null) req.fields['route_id'] = '${d.routeId}';
    if (d.photoPath != null) req.files.add(await http.MultipartFile.fromPath('photo', d.photoPath!));

    http.Response res;
    try {
      res = await http.Response.fromStream(await _client.send(req).timeout(const Duration(seconds: 90)));
    } on IOException {
      throw const ApiException(ApiError.network);
    } on TimeoutException {
      throw const ApiException(ApiError.network);
    } on http.ClientException {
      throw const ApiException(ApiError.network);
    }
    return Post.fromJson(_unwrap(_decode(res)));
  }

  Future<Post> post(int id) async => Post.fromJson(_unwrap(await _send('GET', '/api/v1/posts/$id')));

  Future<void> deletePost(int id) async => _send('DELETE', '/api/v1/posts/$id');

  Future<(bool, int)> setPostLike(int id, bool liked) async {
    final j = await _send(liked ? 'POST' : 'DELETE', '/api/v1/posts/$id/like') as Map;
    return (j['liked'] == true, _i(j['likes_count']) ?? 0);
  }

  Future<bool> setPostSave(int id, bool saved) async => (await _send(saved ? 'POST' : 'DELETE', '/api/v1/posts/$id/save') as Map)['saved'] == true;

  Future<SocialPage<Comment>> comments(int postId, {String? cursor}) async =>
      SocialPage.fromJson(await _send('GET', '/api/v1/posts/$postId/comments?${_query({'cursor': cursor})}') as Map, Comment.fromJson);

  Future<Comment> addComment(int postId, String body) async =>
      Comment.fromJson(_unwrap(await _send('POST', '/api/v1/posts/$postId/comments', body: {'body': body.trim()})));

  Future<void> deleteComment(int id) async => _send('DELETE', '/api/v1/comments/$id');

  Future<void> reportPost(int id, {String? reason}) async => _send('POST', '/api/v1/posts/$id/report', body: {'reason': ?reason});

  Future<List<UserBrief>> searchUsers(String q) async {
    final j = await _send('GET', '/api/v1/users/search?${_query({'q': q.trim()})}');
    return _list(j is Map ? j['data'] : j, UserBrief.fromJson);
  }

  Future<Profile> profile(int id) async => Profile.fromJson(_unwrap(await _send('GET', '/api/v1/users/$id')));

  Future<SocialPage<Post>> userPosts(int id, {String? cursor}) async =>
      SocialPage.fromJson(await _send('GET', '/api/v1/users/$id/posts?${_query({'cursor': cursor})}') as Map, Post.fromJson);

  /// [which]: followers or following.
  Future<SocialPage<UserBrief>> follows(int id, String which, {String? cursor}) async =>
      SocialPage.fromJson(await _send('GET', '/api/v1/users/$id/$which?${_query({'cursor': cursor})}') as Map, UserBrief.fromJson);

  Future<(bool, int)> setFollow(int id, bool follow) async {
    final j = await _send(follow ? 'POST' : 'DELETE', '/api/v1/users/$id/follow') as Map;
    return (j['following'] == true, _i(j['followers_count']) ?? 0);
  }

  Future<SocialPage<Post>> saved({String? cursor}) async =>
      SocialPage.fromJson(await _send('GET', '/api/v1/me/saved?${_query({'cursor': cursor})}') as Map, Post.fromJson);

  /// PUT /me/profile with the current name and email plus the new bio.
  Future<String?> updateBio(AppUser user, String bio) async {
    final j = await _send('PUT', '/api/v1/me/profile', body: {'name': user.name, 'email': user.email, 'bio': bio.trim().isEmpty ? null : bio.trim()}) as Map;
    final u = j['user'] is Map ? j['user'] as Map : j;
    return u.containsKey('bio') ? u['bio'] as String? : (bio.trim().isEmpty ? null : bio.trim());
  }
}

String _query(Map<String, String?> q) => Uri(
  queryParameters: {
    for (final e in q.entries)
      if (e.value != null && e.value!.isNotEmpty) e.key: e.value!,
  },
).query;

/// Single objects may come bare or wrapped in {"data": ...}.
Map _unwrap(dynamic j) => j is Map && j['data'] is Map ? j['data'] as Map : j as Map;

/// One cursor page: {"data": [...], "next_cursor": "opaque" | null}.
class SocialPage<T> {
  SocialPage(this.items, this.nextCursor);

  SocialPage.fromJson(Map j, T Function(Map) f) : items = _list(j['data'], f), nextCursor = j['next_cursor'] is String ? j['next_cursor'] as String : null;

  final List<T> items;
  final String? nextCursor;
}

class UserBrief {
  UserBrief({required this.id, required this.name, this.bio, this.isFollowing = false});

  UserBrief.fromJson(Map j) : id = _i(j['id']) ?? 0, name = '${j['name'] ?? ''}', bio = j['bio'] as String?, isFollowing = j['is_following'] == true;

  final int id;
  final String name;
  final String? bio;
  bool isFollowing;
}

class Profile {
  Profile.fromJson(Map j)
    : id = _i(j['id']) ?? 0,
      name = '${j['name'] ?? ''}',
      bio = j['bio'] as String?,
      followersCount = _i(j['followers_count']) ?? 0,
      followingCount = _i(j['following_count']) ?? 0,
      postsCount = _i(j['posts_count']) ?? 0,
      isFollowing = j['is_following'] == true,
      followsMe = j['follows_me'] == true,
      isMe = j['is_me'] == true;

  final int id;
  final String name;
  String? bio;
  int followersCount, followingCount, postsCount;
  bool isFollowing;
  final bool followsMe, isMe;
}

class PostStats {
  const PostStats({required this.distanceKm, required this.gainM, required this.movingS});

  PostStats.fromJson(Map j) : distanceKm = _d(j['distance_km']) ?? 0, gainM = _i(j['gain_m']) ?? 0, movingS = _i(j['moving_s']) ?? 0;

  final double distanceKm;
  final int gainM, movingS;

  Map<String, Object> toJson() => {'distance_km': double.parse(distanceKm.toStringAsFixed(2)), 'gain_m': gainM, 'moving_s': movingS};
}

class Place {
  const Place({required this.lat, required this.lng, required this.label});

  Place.fromJson(Map j) : lat = _d(j['lat']) ?? 0, lng = _d(j['lng']) ?? 0, label = '${j['label'] ?? ''}';

  final double lat, lng;
  final String label;

  Map<String, Object> toJson() => {'lat': lat, 'lng': lng, 'label': label.length > 80 ? label.substring(0, 80) : label};
}

class Post {
  Post.fromJson(Map j)
    : id = _i(j['id']) ?? 0,
      type = '${j['type'] ?? 'status'}',
      body = j['body'] as String?,
      photoUrl = j['photo_url'] as String?,
      track = j['track'] is List ? _points(j['track']) : null,
      stats = j['stats'] is Map ? PostStats.fromJson(j['stats'] as Map) : null,
      place = j['place'] is Map ? Place.fromJson(j['place'] as Map) : null,
      routeId = (j['route'] as Map?)?['id'] is num ? ((j['route'] as Map)['id'] as num).toInt() : null,
      routeName = (j['route'] as Map?)?['name'] as String?,
      author = UserBrief.fromJson(j['author'] is Map ? j['author'] as Map : const {}),
      likesCount = _i(j['likes_count']) ?? 0,
      commentsCount = _i(j['comments_count']) ?? 0,
      liked = j['liked'] == true,
      saved = j['saved'] == true,
      isMine = j['is_mine'] == true,
      createdAt = DateTime.tryParse('${j['created_at'] ?? ''}')?.toLocal(),
      expiresAt = DateTime.tryParse('${j['expires_at'] ?? ''}')?.toLocal(),
      shareUrl = j['share_url'] as String?;

  final int id;

  /// status, photo, recording or story.
  final String type;
  final String? body, photoUrl, routeName, shareUrl;
  final List<List<double>>? track;
  final PostStats? stats;
  final Place? place;
  final int? routeId;
  final UserBrief author;
  int likesCount, commentsCount;
  bool liked, saved;
  final bool isMine;
  final DateTime? createdAt, expiresAt;
}

class Comment {
  Comment.fromJson(Map j)
    : id = _i(j['id']) ?? 0,
      body = '${j['body'] ?? ''}',
      author = UserBrief.fromJson(j['author'] is Map ? j['author'] as Map : const {}),
      createdAt = DateTime.tryParse('${j['created_at'] ?? ''}')?.toLocal(),
      isMine = j['is_mine'] == true;

  final int id;
  final String body;
  final UserBrief author;
  final DateTime? createdAt;
  final bool isMine;
}

/// Active stories of one author, oldest first.
class StoryGroup {
  StoryGroup.fromJson(Map j) : author = UserBrief.fromJson(j['author'] is Map ? j['author'] as Map : const {}), items = _list(j['items'], Post.fromJson);

  final UserBrief author;
  final List<Post> items;
}

/// A post being written, and the item kept in the offline outbox until it is sent.
class PostDraft {
  PostDraft({
    required this.clientId,
    required this.type,
    this.body,
    this.photoPath,
    this.track,
    this.stats,
    this.place,
    this.routeId,
    DateTime? createdAt,
    this.error,
    this.userId,
  }) : createdAt = createdAt ?? DateTime.now();

  PostDraft.fromJson(Map j)
    : clientId = '${j['client_id']}',
      type = '${j['type']}',
      body = j['body'] as String?,
      photoPath = j['photo_path'] as String?,
      track = j['track'] is List ? _points(j['track']) : null,
      stats = j['stats'] is Map ? PostStats.fromJson(j['stats'] as Map) : null,
      place = j['place'] is Map ? Place.fromJson(j['place'] as Map) : null,
      routeId = _i(j['route_id']),
      createdAt = DateTime.tryParse('${j['created_at'] ?? ''}') ?? DateTime.now(),
      error = j['error'] as String?,
      userId = _i(j['user_id']);

  final String clientId, type;
  final String? body;
  String? photoPath;
  final List<List<double>>? track;
  final PostStats? stats;
  final Place? place;
  final int? routeId;
  final DateTime createdAt;

  /// Set when the server refused the post (it will not be retried).
  String? error;

  /// The account that wrote it (another account signing in on this phone drops it).
  int? userId;

  Map<String, Object?> toJson() => {
    'user_id': userId,
    'client_id': clientId,
    'type': type,
    'body': body,
    'photo_path': photoPath,
    'track': track,
    'stats': stats?.toJson(),
    'place': place?.toJson(),
    'route_id': routeId,
    'created_at': createdAt.toIso8601String(),
    'error': error,
  };
}

/// A random id for the outbox (32 hex characters), so a retry never makes a second post.
String newClientId() {
  final r = math.Random.secure();
  return List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

/// At most [max] points, keeping the first and the last (the server takes 600).
List<List<double>> thinTrack(List<List<double>> pts, {int max = 600}) {
  if (pts.length <= max) return pts;
  final step = (pts.length - 1) / (max - 1);
  return [for (var i = 0; i < max; i++) pts[(i * step).round()]];
}
