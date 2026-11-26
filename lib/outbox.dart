import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import 'api.dart';

/// Where the outbox keeps its queue and the photo copies.
abstract class OutboxStore {
  Future<List<PostDraft>> load();
  Future<void> save(List<PostDraft> items);

  /// Copies the photo out of the picker's cache, which Android may clear.
  Future<String> keepPhoto(String path, String clientId);
  Future<void> dropPhoto(String? path);
}

/// `outbox/queue.json` and `outbox/<client_id>.<ext>` in the app documents.
class FileOutboxStore implements OutboxStore {
  const FileOutboxStore();

  Future<Directory> _dir() async {
    final d = Directory('${(await getApplicationDocumentsDirectory()).path}/outbox');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  @override
  Future<List<PostDraft>> load() async {
    final f = File('${(await _dir()).path}/queue.json');
    if (!await f.exists()) return [];
    return [
      for (final e in jsonDecode(await f.readAsString()) as List)
        if (e is Map) PostDraft.fromJson(e),
    ];
  }

  @override
  Future<void> save(List<PostDraft> items) async {
    final f = File('${(await _dir()).path}/queue.json');
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode([for (final d in items) d.toJson()]), flush: true);
    await tmp.rename(f.path);
  }

  @override
  Future<String> keepPhoto(String path, String clientId) async {
    final dot = path.lastIndexOf('.');
    final ext = dot > 0 && path.length - dot <= 5 ? path.substring(dot) : '.jpg';
    return (await File(path).copy('${(await _dir()).path}/$clientId$ext')).path;
  }

  @override
  Future<void> dropPhoto(String? path) async {
    // Only the outbox's own copies; a photo elsewhere on the phone is never deleted.
    if (path == null || !File(path).parent.path.endsWith('outbox')) return;
    final f = File(path);
    if (await f.exists()) await f.delete();
  }
}

/// Posts written without signal wait here (with their client_id) and are sent when the
/// network is back: on app resume, when Linimasa opens, and every few minutes.
class Outbox extends ChangeNotifier with WidgetsBindingObserver {
  Outbox({this.store = const FileOutboxStore()});

  static final instance = Outbox();

  static const retryEvery = Duration(minutes: 3);

  final OutboxStore store;

  /// Sends one post (Api.createPost in the app, a fake in tests).
  Future<Post> Function(PostDraft)? sender;

  final items = <PostDraft>[];

  /// Grows by one for every queued post that went out, so the feed knows to reload.
  int sentCount = 0;

  Future<void>? _loaded;
  Future<int>? _flushing;
  Timer? _timer;

  Future<void> _ready() => _loaded ??= () async {
    try {
      items.addAll(await store.load());
    } catch (_) {
      // No storage (tests) or a broken file: start with an empty queue.
    }
    notifyListeners();
  }();

  /// Called by the signed-in shell. Posts queued by another account on this phone are dropped.
  Future<void> start(Api api, int userId) async {
    sender = api.createPost;
    owner = userId;
    if (_timer == null) {
      WidgetsBinding.instance.addObserver(this);
      _timer = Timer.periodic(retryEvery, (_) => flush());
    }
    await _ready();
    for (final d in items.where((d) => d.userId != userId).toList()) {
      items.remove(d);
      await store.dropPhoto(d.photoPath).catchError((_) {});
    }
    await flush();
  }

  /// The signed-in account; queued posts carry it.
  int? owner;

  void stop() {
    if (_timer == null) return;
    _timer!.cancel();
    _timer = null;
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) flush();
  }

  List<PostDraft> get pending => items.where((d) => d.error == null).toList();

  /// Sends now. Returns the post, or null when there is no network and it was queued.
  /// Other errors (validation, limits) are thrown to the composer.
  Future<Post?> submit(PostDraft d) async {
    await _ready();
    try {
      final post = await sender!(d);
      return post;
    } on ApiException catch (e) {
      if (e.kind != ApiError.network) rethrow;
    }
    if (d.photoPath != null) {
      try {
        d.photoPath = await store.keepPhoto(d.photoPath!, d.clientId);
      } catch (_) {
        // Keep the original path; it usually survives until the retry.
      }
    }
    d.userId ??= owner;
    items.add(d);
    await _save();
    notifyListeners();
    return null;
  }

  /// Tries every queued post, oldest first. Stops at the first network failure.
  /// Returns how many went out.
  Future<int> flush() => _flushing ??= _flush().whenComplete(() => _flushing = null);

  Future<int> _flush() async {
    await _ready();
    final send = sender;
    if (send == null) return 0;
    var sent = 0;
    for (final d in pending) {
      try {
        await send(d);
        items.remove(d);
        await store.dropPhoto(d.photoPath).catchError((_) {});
        sent++;
      } on ApiException catch (e) {
        if (e.kind == ApiError.validation || e.kind == ApiError.forbidden || e.kind == ApiError.notFound) {
          // The server will never take this one: keep it visible so the hiker can remove it.
          d.error = e.message ?? '${e.status ?? ''}';
          continue;
        }
        break; // network, limits, server trouble or signed out: try again later
      } catch (_) {
        break;
      }
    }
    sentCount += sent;
    await _save();
    notifyListeners();
    return sent;
  }

  Future<void> cancel(String clientId) async {
    await _ready();
    final i = items.indexWhere((d) => d.clientId == clientId);
    if (i < 0) return;
    final d = items.removeAt(i);
    await store.dropPhoto(d.photoPath).catchError((_) {});
    await _save();
    notifyListeners();
  }

  Future<void> _save() async {
    try {
      await store.save(items);
    } catch (_) {}
  }
}
