import 'dart:async';
import 'dart:convert';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:geolocator/geolocator.dart';

import 'api.dart';
import 'location_hub.dart';
import 'recording_math.dart';

/// "Bagikan lokasi online": while the phone has signal, the latest position goes to a
/// secret link (rutestrip.ai.id/lacak/...) that family or the basecamp can open.
/// Only the newest position is kept on the server; the link ends at its expiry or on stop.
class LiveShare extends ChangeNotifier {
  LiveShare._();

  static final instance = LiveShare._();

  static const _key = 'live_share';
  final _secure = const FlutterSecureStorage();

  Api? _api;
  String? token, url;
  DateTime? expiresAt, sentAt;
  bool busy = false;
  StreamSubscription<Position>? _sub;
  Position? _lastSent;

  bool get active => token != null && expiresAt != null && expiresAt!.isAfter(DateTime.now());

  /// Restores a running share after the app restarts.
  Future<void> restore(Api api) async {
    _api = api;
    try {
      final raw = await _secure.read(key: _key);
      if (raw == null) return;
      final j = jsonDecode(raw) as Map;
      token = j['token'] as String?;
      url = j['url'] as String?;
      expiresAt = DateTime.tryParse('${j['expires_at']}')?.toLocal();
      if (active) {
        _listen();
      } else {
        await _clear();
      }
      notifyListeners();
    } catch (_) {
      await _clear();
    }
  }

  Future<void> start(Api api, int hours, {String? label}) async {
    _api = api;
    busy = true;
    notifyListeners();
    try {
      final r = await api.liveStart(hours, label: label);
      token = r.token;
      url = r.url;
      expiresAt = r.expiresAt;
      await _secure.write(key: _key, value: jsonEncode({'token': token, 'url': url, 'expires_at': expiresAt!.toUtc().toIso8601String()}));
      _listen();
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> stop() async {
    final t = token;
    await _clear();
    notifyListeners();
    if (t != null) {
      try {
        await _api?.liveStop(t);
      } catch (_) {
        // The link still ends at its expiry time on the server.
      }
    }
  }

  /// Signing out ends the share on this phone (the next account must not continue it).
  Future<void> signedOut() => stop();

  void _listen() {
    _sub ??= LocationHub.instance.positions.listen(_onPosition, onError: (_) {});
    LocationHub.instance.require(this, LocNeed.share);
  }

  Future<void> _clear() async {
    await _sub?.cancel();
    _sub = null;
    LocationHub.instance.release(this);
    token = url = null;
    expiresAt = sentAt = null;
    _lastSent = null;
    await _secure.delete(key: _key);
  }

  Future<void> _onPosition(Position p) async {
    final t = token, api = _api;
    if (t == null || api == null) return;
    if (!active) {
      await _clear();
      notifyListeners();
      return;
    }
    if (p.accuracy > 100) return;
    final last = _lastSent, at = sentAt;
    if (last != null && at != null) {
      final age = DateTime.now().difference(at);
      final moved = distanceM(last.latitude, last.longitude, p.latitude, p.longitude);
      // Every minute when moving, every 3 minutes when standing still: light on battery and data.
      if (age < const Duration(seconds: 60) || (moved < 15 && age < const Duration(minutes: 3))) return;
    }
    int? bat;
    try {
      bat = await Battery().batteryLevel;
    } catch (_) {}
    try {
      await api.livePosition(t, p.latitude, p.longitude, accuracy: p.accuracy, elevation: p.altitude == 0 ? null : p.altitude, battery: bat);
      _lastSent = p;
      sentAt = DateTime.now();
      notifyListeners();
    } on ApiException catch (e) {
      if (e.status == 410 || e.status == 404) {
        await _clear(); // ended on the server (expired or stopped elsewhere)
        notifyListeners();
      }
    } catch (_) {
      // No signal: the next fix tries again.
    }
  }
}
