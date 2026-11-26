import 'dart:async';

import 'package:geolocator/geolocator.dart';

import 'i18n.dart';

/// Who needs the GPS, strongest last.
enum LocNeed { preview, share, group, record }

/// The one GPS stream of the app.
///
/// geolocator keeps a single position stream per app: a second caller silently gets the
/// first caller's settings. So every screen asks here instead, and the stream always runs
/// with the strongest need: recording (every 3 s, foreground service with a notification),
/// then the offline group (every 10 s, foreground service so the group keeps working
/// with the screen off), then the map preview (every 5 s, no service).
class LocationHub {
  LocationHub._();

  static final instance = LocationHub._();

  final _needs = <Object, LocNeed>{};
  final _out = StreamController<Position>.broadcast();
  StreamSubscription<Position>? _sub;
  LocNeed? _active;
  String lang = 'id';
  String groupName = '';

  /// The GPS chip (LocationManager) instead of the fused provider, after the hiker declined
  /// Google's "Location Accuracy" dialog (the fused provider would ask again each time).
  bool _useManager = false;

  /// Positions (and stream errors) for every listener.
  Stream<Position> get positions => _out.stream;

  LocNeed? get active => _active;

  void require(Object owner, LocNeed need) {
    _needs[owner] = need;
    _apply();
  }

  void release(Object owner) {
    if (_needs.remove(owner) != null) _apply();
  }

  /// Restart with new notification text (language or group name changed).
  void refresh() {
    final a = _active;
    if (a == null) return;
    _active = null;
    _apply();
  }

  void _apply() {
    final top = _needs.values.fold<LocNeed?>(null, (a, b) => a == null || b.index > a.index ? b : a);
    if (top == _active) return;
    _sub?.cancel(); // also clears geolocator's cached stream
    _sub = null;
    _active = top;
    if (top == null) return;
    _sub = Geolocator.getPositionStream(locationSettings: _settings(top)).listen(_out.add, onError: _onError);
  }

  Future<void> _onError(Object e) async {
    // Declined "Location Accuracy" while location is on: go on with the GPS chip, quietly.
    if (e is LocationServiceDisabledException && !_useManager && await Geolocator.isLocationServiceEnabled()) {
      _useManager = true;
      refresh();
      return;
    }
    _out.addError(e);
  }

  /// Settings for a one-time position lookup that follow the same provider choice.
  AndroidSettings oneShot({Duration timeLimit = const Duration(seconds: 15)}) =>
      AndroidSettings(accuracy: LocationAccuracy.high, forceLocationManager: _useManager, timeLimit: timeLimit);

  AndroidSettings _settings(LocNeed need) => switch (need) {
    LocNeed.record => AndroidSettings(
      accuracy: LocationAccuracy.best,
      // Fused provider: uses the GPS chip in the mountains and Wi-Fi/cell indoors, so the first
      // fix comes fast. Without Play services geolocator falls back to the GPS chip itself.
      forceLocationManager: _useManager,
      distanceFilter: 5,
      intervalDuration: const Duration(seconds: 3),
      foregroundNotificationConfig: ForegroundNotificationConfig(
        notificationTitle: trLang(lang, 'record.title'),
        notificationText: trLang(lang, _needs.values.contains(LocNeed.group) ? 'notif.record.group' : 'notif.record'),
        enableWakeLock: true,
        setOngoing: true,
        notificationIcon: const AndroidResource(name: 'ic_launcher', defType: 'mipmap'),
      ),
    ),
    LocNeed.group => AndroidSettings(
      accuracy: LocationAccuracy.high,
      forceLocationManager: _useManager,
      distanceFilter: 10,
      intervalDuration: const Duration(seconds: 10),
      foregroundNotificationConfig: ForegroundNotificationConfig(
        notificationTitle: trLang(lang, 'notif.group.title', {'name': groupName}),
        notificationText: trLang(lang, 'notif.group'),
        enableWakeLock: false,
        setOngoing: true,
        notificationIcon: const AndroidResource(name: 'ic_launcher', defType: 'mipmap'),
      ),
    ),
    LocNeed.share => AndroidSettings(
      accuracy: LocationAccuracy.high,
      forceLocationManager: _useManager,
      distanceFilter: 15,
      intervalDuration: const Duration(seconds: 30),
      foregroundNotificationConfig: ForegroundNotificationConfig(
        notificationTitle: trLang(lang, 'notif.share.title'),
        notificationText: trLang(lang, 'notif.share'),
        enableWakeLock: false,
        setOngoing: true,
        notificationIcon: const AndroidResource(name: 'ic_launcher', defType: 'mipmap'),
      ),
    ),
    LocNeed.preview => AndroidSettings(
      accuracy: LocationAccuracy.high,
      forceLocationManager: _useManager,
      distanceFilter: 10,
      intervalDuration: const Duration(seconds: 5),
    ),
  };
}
