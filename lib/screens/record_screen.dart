import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:material_ui/material_ui.dart';

import '../api.dart';
import '../app_state.dart';
import '../i18n.dart';
import '../recording_math.dart';
import '../storage.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/contour_header.dart';
import '../widgets/trail_map.dart';

/// Route to follow while recording, set by "Rekam di jalur ini" on a route page.
final followRoute = ValueNotifier<RouteDetail?>(null);

enum _Status { idle, recording, paused }

/// Waypoint kinds the hiker can mark, with their map icons.
const waypointKinds = <String, IconData>{
  'pos': Icons.flag_outlined,
  'water': Icons.water_drop_outlined,
  'camp': Icons.cabin_outlined,
  'summit': Icons.landscape_outlined,
  'danger': Icons.warning_amber_rounded,
  'other': Icons.place_outlined,
};

/// GPS recording. A foreground service keeps it going with the screen off, the
/// recording is autosaved as a draft (survives the app being closed), and the map
/// shows the hiker's heading, zoom controls and guidance along a followed trail.
class RecordScreen extends StatefulWidget {
  const RecordScreen({super.key, required this.active});

  final bool active;

  @override
  State<RecordScreen> createState() => _RecordScreenState();
}

class _RecordScreenState extends State<RecordScreen> with WidgetsBindingObserver {
  static const _maxAccuracyM = 30.0; // fixes worse than this are skipped
  static const _gainStepM = 3.0; // altitude changes smaller than this are GPS noise
  static const _maxAgeS = 30; // older fixes are cached positions, not this walk
  static const _maxSpeedMs = 15.0; // 54 km/h: faster jumps are GPS errors
  static const _offRouteMinM = 40.0; // off the trail from here (or 1.5x the GPS accuracy)

  final _map = MapController();
  final _points = <TrackPoint>[];
  final _waypoints = <Waypoint>[];
  StreamSubscription<Position>? _sub, _preview;
  StreamSubscription<CompassEvent>? _compass;
  Timer? _ticker;
  _Status _status = _Status.idle;
  Position? _last;
  DateTime? _startedAt;
  final _moving = Stopwatch();
  Duration _movingBefore = Duration.zero; // moving time restored from a draft
  double _distanceM = 0, _gainM = 0;
  double? _refEle;
  int _jumps = 0, _sinceDraft = 0;
  DateTime _draftAt = DateTime.now();
  String? _problem;
  bool _problemForever = false, _restored = false;

  // Map camera: follow the hiker, and optionally turn the map with the hiker's heading.
  bool _follow = true, _turnWithHeading = false, _zoomedToHiker = false;
  double? _heading; // degrees from north, phone compass (GPS course as fallback)
  DateTime _headingAt = DateTime.fromMillisecondsSinceEpoch(0);
  double _mapRotation = 0;
  bool _offRoute = false;

  Duration get _movingTime => _movingBefore + _moving.elapsed;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    followRoute.addListener(_onFollow);
    _restoreDraft();
    _syncSensors();
  }

  @override
  void didUpdateWidget(covariant RecordScreen old) {
    super.didUpdateWidget(old);
    if (old.active != widget.active) _syncSensors();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    followRoute.removeListener(_onFollow);
    _sub?.cancel();
    _preview?.cancel();
    _compass?.cancel();
    _ticker?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Leaving the app: write the draft now, the system may close the app later.
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) _saveDraft();
  }

  // ---------------------------------------------------------------------------
  // Sensors: compass while the tab is visible; a light position preview before recording.
  // ---------------------------------------------------------------------------

  Future<void> _syncSensors() async {
    final visible = widget.active || _status == _Status.recording;
    if (visible && _compass == null) {
      _compass = FlutterCompass.events?.listen(_onCompass);
    } else if (!visible) {
      await _compass?.cancel();
      _compass = null;
    }
    if (widget.active && _status == _Status.idle && _preview == null) {
      final p = await Geolocator.checkPermission();
      if (!mounted || !(p == LocationPermission.always || p == LocationPermission.whileInUse)) return;
      if (!await Geolocator.isLocationServiceEnabled()) return;
      _preview = Geolocator.getPositionStream(
        locationSettings: AndroidSettings(
          accuracy: LocationAccuracy.high,
          forceLocationManager: true,
          distanceFilter: 10,
          intervalDuration: const Duration(seconds: 5),
        ),
      ).listen(_onPreview, onError: (_) {});
    } else if (!widget.active || _status != _Status.idle) {
      await _preview?.cancel();
      _preview = null;
    }
  }

  void _onCompass(CompassEvent e) {
    final h = e.heading;
    if (h == null || !mounted) return;
    final now = DateTime.now();
    final prev = _heading;
    // At most ~10 updates a second and only for a visible change: light on standard phones.
    if (prev != null && (((h - prev + 540) % 360) - 180).abs() < 2) return;
    if (now.difference(_headingAt).inMilliseconds < 100) return;
    _headingAt = now;
    setState(() => _heading = (h + 360) % 360);
    if (_turnWithHeading) _rotateMap(-_heading!);
  }

  void _onPreview(Position p) {
    if (!mounted || _status != _Status.idle) return;
    setState(() => _last = p);
    _autoCamera(p);
  }

  // ---------------------------------------------------------------------------
  // Camera
  // ---------------------------------------------------------------------------

  void _onFollow() {
    if (!mounted) return;
    setState(() {});
    if (followRoute.value != null) WidgetsBinding.instance.addPostFrameCallback((_) => _fitAll());
  }

  /// First fix: zoom to the hiker. Afterwards keep them centred while following.
  void _autoCamera(Position p) {
    if (!_follow) return;
    final here = LatLng(p.latitude, p.longitude);
    try {
      final zoom = !_zoomedToHiker || _map.camera.zoom < 14 ? 16.0 : _map.camera.zoom;
      _map.move(here, zoom);
      _zoomedToHiker = true;
    } catch (_) {}
  }

  /// The followed trail, what was recorded and the hiker, all on screen.
  void _fitAll() {
    final pts = <LatLng>[
      ...?followRoute.value?.coordinates.map((p) => LatLng(p[0], p[1])),
      ..._points.map((p) => LatLng(p.lat, p.lng)),
      if (_last != null) LatLng(_last!.latitude, _last!.longitude),
    ];
    if (pts.isEmpty) return;
    setState(() => _follow = false);
    try {
      if (pts.length == 1) {
        _map.move(pts.first, 16);
      } else {
        _map.fitCamera(CameraFit.coordinates(coordinates: pts, padding: const EdgeInsets.fromLTRB(48, 96, 72, 48), maxZoom: 17));
      }
    } catch (_) {}
  }

  void _zoom(double by) {
    try {
      _map.move(_map.camera.center, (_map.camera.zoom + by).clamp(3, 19).toDouble());
    } catch (_) {}
  }

  void _rotateMap(double degrees) {
    try {
      _map.rotate(degrees);
      setState(() => _mapRotation = degrees);
    } catch (_) {}
  }

  /// Compass button: a turned map goes back to north up; a north-up map starts turning with the hiker.
  void _compassTap() {
    if (_turnWithHeading || _mapRotation.abs() > 1) {
      setState(() => _turnWithHeading = false);
      _rotateMap(0);
    } else if (_heading != null) {
      setState(() => _turnWithHeading = true);
      _rotateMap(-_heading!);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr(context, 'record.no_compass'))));
    }
  }

  void _centerOnMe() {
    final p = _last;
    if (p == null) return;
    setState(() => _follow = true);
    _zoomedToHiker = false;
    _autoCamera(p);
  }

  // ---------------------------------------------------------------------------
  // Recording
  // ---------------------------------------------------------------------------

  Future<bool> _ready() async {
    setState(() {
      _problem = null;
      _problemForever = false;
    });
    if (!await Geolocator.isLocationServiceEnabled()) {
      setState(() => _problem = 'record.service_off');
      return false;
    }
    var p = await Geolocator.checkPermission();
    if (p == LocationPermission.denied) p = await Geolocator.requestPermission();
    if (p == LocationPermission.deniedForever) {
      setState(() {
        _problem = 'record.permission.forever';
        _problemForever = true;
      });
      return false;
    }
    if (p == LocationPermission.denied) {
      setState(() => _problem = 'record.permission');
      return false;
    }
    return true;
  }

  Future<void> _start() async {
    if (!await _ready() || !mounted) return;
    final lang = AppScope.read(context).lang;
    await _preview?.cancel();
    _preview = null;
    _startedAt ??= DateTime.now();
    _restored = false;
    _moving.start();
    _sub = Geolocator.getPositionStream(
      locationSettings: AndroidSettings(
        accuracy: LocationAccuracy.best,
        // GPS chip directly: works in the mountains without mobile data or Play services.
        forceLocationManager: true,
        distanceFilter: 5,
        intervalDuration: const Duration(seconds: 3),
        foregroundNotificationConfig: ForegroundNotificationConfig(
          notificationTitle: trLang(lang, 'record.title'),
          notificationText: trLang(lang, 'record.note').split(';').first,
          enableWakeLock: true,
          setOngoing: true,
          notificationIcon: const AndroidResource(name: 'ic_launcher', defType: 'mipmap'),
        ),
      ),
    ).listen(_onPosition, onError: _onLocationError);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
    setState(() => _status = _Status.recording);
    _syncSensors();
    _saveDraft();
  }

  /// The stream failed: stop cleanly and say why instead of looking like it still records.
  void _onLocationError(Object e) {
    if (kDebugMode) debugPrint('RuteStrip location error: $e');
    _sub?.cancel();
    _sub = null;
    _ticker?.cancel();
    _moving.stop();
    if (!mounted) return;
    setState(() {
      _problem = switch (e) {
        PermissionDeniedException() => 'record.permission',
        LocationServiceDisabledException() => 'record.service_off',
        _ => 'record.gps_error',
      };
      _status = _points.isEmpty ? _Status.idle : _Status.paused;
    });
    _saveDraft();
  }

  void _onPosition(Position p) {
    if (!mounted) return;
    setState(() {
      _last = p;
      // No compass sensor: the GPS course is the heading while walking.
      if (_compass == null && p.speed > 0.6 && p.heading >= 0) _heading = p.heading;
    });
    _autoCamera(p);
    _checkRoute(p);
    if (_status != _Status.recording || p.accuracy > _maxAccuracyM) return;

    final point = TrackPoint(p.latitude, p.longitude, p.altitude == 0 ? null : p.altitude, p.timestamp.toUtc());
    // A cached fix from before the recording, or a jump no hiker can make, is not part of the walk.
    if (DateTime.now().toUtc().difference(point.time).inSeconds > _maxAgeS) return;
    if (_points.isNotEmpty) {
      final prev = _points.last;
      final step = Geolocator.distanceBetween(prev.lat, prev.lng, point.lat, point.lng);
      final seconds = point.time.difference(prev.time).inMilliseconds / 1000;
      if (seconds <= 0 || step / seconds > _maxSpeedMs) {
        // Three jumps in a row from a lone first point: that first point was the bad one.
        if (++_jumps >= 3 && _points.length == 1) {
          _points.clear();
          _jumps = 0;
        } else {
          return;
        }
      } else {
        _jumps = 0;
        _distanceM += step;
      }
    }
    final ele = point.ele;
    if (ele != null) {
      if (_refEle == null) {
        _refEle = ele;
      } else if (ele - _refEle! >= _gainStepM) {
        _gainM += ele - _refEle!;
        _refEle = ele;
      } else if (_refEle! - ele >= _gainStepM) {
        _refEle = ele;
      }
    }
    _points.add(point);
    // Draft every 5 points or 10 seconds: a killed app loses at most a few seconds of walking.
    if (++_sinceDraft >= 5 || DateTime.now().difference(_draftAt).inSeconds >= 10) _saveDraft();
  }

  /// Off-route warning (with a buzz when it starts) and progress along a followed trail.
  void _checkRoute(Position p) {
    final route = followRoute.value?.coordinates ?? const <List<double>>[];
    final prog = routeProgress(route, p.latitude, p.longitude);
    if (prog == null) return;
    final limit = math.max(_offRouteMinM, p.accuracy * 1.5);
    final off = _offRoute ? prog.offRouteM > limit * 0.7 : prog.offRouteM > limit;
    if (off && !_offRoute && _status == _Status.recording) HapticFeedback.heavyImpact();
    if (off != _offRoute) setState(() => _offRoute = off);
  }

  void _pause() {
    _sub?.cancel();
    _sub = null;
    _ticker?.cancel();
    _moving.stop();
    setState(() => _status = _Status.paused);
    _saveDraft();
    _syncSensors();
  }

  Future<void> _mark() async {
    final p = _last;
    if (p == null) return;
    final kind = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(tr(context, 'wpt.title').toUpperCase(), style: RS.head(26, color: RS.z9)),
            ),
            for (final e in waypointKinds.entries)
              ListTile(
                minTileHeight: 52,
                leading: Icon(e.value, color: RS.z7),
                title: Text(tr(context, 'wpt.${e.key}')),
                onTap: () => Navigator.pop(context, e.key),
              ),
          ],
        ),
      ),
    );
    if (kind == null || !mounted) return;
    setState(
      () => _waypoints.add(Waypoint(lat: p.latitude, lng: p.longitude, ele: p.altitude == 0 ? null : p.altitude, time: DateTime.now().toUtc(), kind: kind)),
    );
    _saveDraft();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr(context, 'wpt.added', {'name': tr(context, 'wpt.$kind')}))));
  }

  Future<void> _finish() async {
    _pause();
    if (_points.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr(context, 'record.too_short'))));
      await _reset();
      return;
    }
    final name = TextEditingController(text: _defaultName());
    final keep = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text(tr(context, 'record.save')),
        content: TextField(
          controller: name,
          decoration: InputDecoration(labelText: tr(context, 'record.name')),
          maxLength: 120,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr(context, 'record.discard'))),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr(context, 'record.save'))),
        ],
      ),
    );
    if (!mounted) return;
    if (keep == true) {
      await RecordingStore.save(
        Recording(
          id: _startedAt!.millisecondsSinceEpoch.toString(),
          name: name.text.trim().isEmpty ? _defaultName() : name.text.trim(),
          startedAt: _startedAt!,
          points: List.of(_points),
          distanceKm: _distanceM / 1000,
          gainM: _gainM,
          movingSeconds: _movingTime.inSeconds,
          waypoints: List.of(_waypoints),
        ),
      );
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr(context, 'record.saved'))));
      await _reset();
    } else {
      final sure = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          content: Text(tr(context, 'record.discard.confirm')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr(context, 'chat.cancel'))),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: RS.err),
              onPressed: () => Navigator.pop(context, true),
              child: Text(tr(context, 'record.discard')),
            ),
          ],
        ),
      );
      if (sure == true) await _reset();
    }
  }

  Future<void> _reset() async {
    await RecordingStore.clearDraft();
    if (!mounted) return;
    setState(() {
      _points.clear();
      _waypoints.clear();
      _distanceM = 0;
      _gainM = 0;
      _refEle = null;
      _jumps = 0;
      _startedAt = null;
      _moving.reset();
      _movingBefore = Duration.zero;
      _restored = false;
      _offRoute = false;
      _status = _Status.idle;
    });
    _syncSensors();
  }

  // ---------------------------------------------------------------------------
  // Draft: autosave and restore
  // ---------------------------------------------------------------------------

  Future<void> _saveDraft() async {
    _sinceDraft = 0;
    _draftAt = DateTime.now();
    if (_startedAt == null || _status == _Status.idle) return;
    final f = followRoute.value;
    await RecordingStore.saveDraft({
      'started_at': _startedAt!.toIso8601String(),
      'points': _points.map((p) => p.toJson()).toList(),
      'waypoints': _waypoints.map((w) => w.toJson()).toList(),
      'distance_m': _distanceM,
      'gain_m': _gainM,
      'ref_ele': _refEle,
      'moving_ms': _movingTime.inMilliseconds,
      if (f != null) 'follow': {'id': f.id, 'name': f.name, 'coordinates': f.coordinates},
    });
  }

  Future<void> _restoreDraft() async {
    final d = await RecordingStore.loadDraft();
    if (d == null || !mounted) return;
    try {
      setState(() {
        _startedAt = DateTime.parse('${d['started_at']}');
        _points
          ..clear()
          ..addAll((d['points'] as List).map((p) => TrackPoint.fromJson(p as List)));
        _waypoints
          ..clear()
          ..addAll((d['waypoints'] as List? ?? const []).map((w) => Waypoint.fromJson(w as Map)));
        _distanceM = (d['distance_m'] as num).toDouble();
        _gainM = (d['gain_m'] as num).toDouble();
        _refEle = (d['ref_ele'] as num?)?.toDouble();
        _movingBefore = Duration(milliseconds: (d['moving_ms'] as num).toInt());
        _status = _Status.paused;
        _restored = true;
      });
      final f = d['follow'];
      if (f is Map && followRoute.value == null) followRoute.value = RouteDetail.fromJson(f);
      WidgetsBinding.instance.addPostFrameCallback((_) => _fitAll());
    } catch (_) {
      await RecordingStore.clearDraft(); // unreadable draft
    }
  }

  // ---------------------------------------------------------------------------

  String _defaultName() {
    final t = _startedAt ?? DateTime.now();
    final follow = followRoute.value?.name;
    final stamp = '${t.day}/${t.month}/${t.year} ${t.hour.toString().padLeft(2, '0')}.${t.minute.toString().padLeft(2, '0')}';
    return follow != null ? '$follow ($stamp)' : '${tr(context, 'record.title')} $stamp';
  }

  String _elapsed() {
    final s = _movingTime.inSeconds;
    final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
    return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}' : '${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }

  String _dir(double degrees) => tr(context, 'dir.${compassIndex(degrees)}');

  @override
  Widget build(BuildContext context) {
    final follow = followRoute.value;
    final planned = follow?.coordinates.map((p) => LatLng(p[0], p[1])).toList() ?? const <LatLng>[];
    final recorded = _points.map((p) => LatLng(p.lat, p.lng)).toList();
    final here = _last == null ? null : LatLng(_last!.latitude, _last!.longitude);

    return Scaffold(
      body: Column(
        children: [
          ContourHeader(
            seed: 55,
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const HeaderBar(),
                Text(tr(context, 'record.title').toUpperCase(), style: RS.head(32, color: Colors.white)),
                const SizedBox(height: 2),
                Text(
                  follow != null ? tr(context, 'record.following', {'name': follow.name}) : tr(context, 'record.lead'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Color(0xFFD1FAE5), fontSize: 14, height: 1.35),
                ),
              ],
            ),
          ),
          Expanded(
            child: Stack(
              children: [
                FlutterMap(
                  mapController: _map,
                  options: MapOptions(
                    initialCenter: const LatLng(-7.4, 110.4),
                    initialZoom: 7,
                    initialCameraFit: planned.length >= 2 ? CameraFit.coordinates(coordinates: planned, padding: const EdgeInsets.all(48)) : null,
                    interactionOptions: const InteractionOptions(flags: InteractiveFlag.all),
                    onPositionChanged: (camera, hasGesture) {
                      if (hasGesture && (_follow || _turnWithHeading)) {
                        setState(() {
                          _follow = false;
                          if ((camera.rotation - _mapRotation).abs() > 1) _turnWithHeading = false;
                        });
                      }
                      if ((camera.rotation - _mapRotation).abs() > 1) setState(() => _mapRotation = camera.rotation);
                    },
                  ),
                  children: [
                    TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'id.ai.rutestrip.app', maxZoom: 19),
                    if (planned.length >= 2)
                      PolylineLayer(
                        polylines: [Polyline(points: planned, strokeWidth: 5, color: RS.z9.withValues(alpha: 0.45))],
                      ),
                    if (recorded.length >= 2)
                      PolylineLayer(
                        polylines: [
                          Polyline(points: recorded, strokeWidth: 7, color: Colors.white),
                          Polyline(points: recorded, strokeWidth: 4.5, color: RS.z7),
                        ],
                      ),
                    MarkerLayer(
                      markers: [
                        for (final w in _waypoints)
                          Marker(
                            point: LatLng(w.lat, w.lng),
                            width: 30,
                            height: 30,
                            rotate: true,
                            child: Semantics(
                              label: tr(context, 'wpt.${w.kind}'),
                              child: Container(
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  shape: BoxShape.circle,
                                  border: Border.all(color: RS.z9, width: 2),
                                ),
                                child: Icon(waypointKinds[w.kind] ?? Icons.place_outlined, size: 16, color: RS.z9),
                              ),
                            ),
                          ),
                        if (here != null)
                          Marker(
                            point: here,
                            width: 44,
                            height: 44,
                            child: Semantics(
                              label: tr(context, 'record.you'),
                              child: _HikerMarker(heading: _heading),
                            ),
                          ),
                      ],
                    ),
                    const OsmAttribution(),
                  ],
                ),
                if (follow != null && here != null) Positioned(left: 12, right: 72, top: 12, child: _guidance(context, here)),
                Positioned(right: 12, top: 12, child: _controls(context, here)),
              ],
            ),
          ),
          _panel(context),
        ],
      ),
    );
  }

  Widget _guidance(BuildContext context, LatLng here) {
    final prog = routeProgress(followRoute.value!.coordinates, here.latitude, here.longitude);
    if (prog == null) return const SizedBox.shrink();
    final toTrail = bearingDeg(here.latitude, here.longitude, prog.nearestLat, prog.nearestLng);
    return Semantics(
      liveRegion: _offRoute,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: _offRoute ? RS.warnBg : Colors.white,
          border: Border.all(color: _offRoute ? RS.warnLine : RS.line),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_offRoute)
              Text(
                tr(context, 'guide.off', {'m': fmtNum(context, prog.offRouteM), 'dir': _dir(toTrail)}),
                style: const TextStyle(color: RS.warnInk, fontWeight: FontWeight.w700, fontSize: 14, height: 1.35),
              )
            else
              Text(
                tr(context, 'guide.left', {'km': fmtNum(context, prog.leftM / 1000, 1), 'pct': (prog.fraction * 100).round()}),
                style: const TextStyle(color: RS.ink, fontWeight: FontWeight.w700, fontSize: 14),
              ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(value: prog.fraction, minHeight: 6, backgroundColor: RS.line, color: RS.z7),
            ),
          ],
        ),
      ),
    );
  }

  Widget _controls(BuildContext context, LatLng? here) {
    Widget btn(IconData icon, String tip, VoidCallback onTap, {bool on = false, Widget? child}) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Tooltip(
        message: tip,
        child: Material(
          color: on ? RS.z9 : Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: const BorderSide(color: RS.edge),
          ),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 48,
              height: 48,
              child: Center(child: child ?? Icon(icon, color: on ? Colors.white : RS.z9)),
            ),
          ),
        ),
      ),
    );
    return Column(
      children: [
        // Needle points to north on the map; tap: north up, or turn the map with you.
        btn(
          Icons.navigation,
          tr(context, _turnWithHeading ? 'map.north' : 'map.turn'),
          _compassTap,
          on: _turnWithHeading,
          child: Semantics(
            label: tr(context, 'map.compass'),
            child: Transform.rotate(
              angle: _mapRotation * math.pi / 180,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    tr(context, 'map.n'),
                    style: TextStyle(fontSize: 10, height: 1, fontWeight: FontWeight.w800, color: _turnWithHeading ? Colors.white : RS.err),
                  ),
                  Icon(Icons.navigation, size: 22, color: _turnWithHeading ? Colors.white : RS.err),
                ],
              ),
            ),
          ),
        ),
        btn(Icons.add, tr(context, 'map.zoom_in'), () => _zoom(1)),
        btn(Icons.remove, tr(context, 'map.zoom_out'), () => _zoom(-1)),
        btn(Icons.zoom_out_map, tr(context, 'map.fit'), _fitAll),
        if (here != null) btn(_follow ? Icons.my_location : Icons.location_searching, tr(context, 'record.center'), _centerOnMe, on: _follow),
      ],
    );
  }

  Widget _panel(BuildContext context) {
    final ele = _last?.altitude;
    final hours = _movingTime.inSeconds / 3600;
    final speed = hours > 0 ? _distanceM / 1000 / hours : 0.0;
    final status = _status == _Status.idle
        ? (_last == null ? tr(context, 'record.note') : tr(context, 'record.ready'))
        : _status == _Status.paused
        ? tr(context, 'record.paused', {'n': _points.length})
        : _last == null
        ? tr(context, 'record.waiting')
        : [
            tr(context, 'record.points', {'n': _points.length}),
            tr(context, 'record.accuracy', {'m': _last!.accuracy.round()}),
            if (_points.length > 1) tr(context, 'record.speed', {'v': fmtNum(context, speed, 1)}),
          ].join(' · ');
    return Material(
      color: RS.paper,
      child: Container(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: RS.line)),
        ),
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_restored) ...[
              Container(
                padding: const EdgeInsets.all(10),
                decoration: const BoxDecoration(
                  color: RS.warnBg,
                  border: Border(left: BorderSide(color: RS.warnLine, width: 4)),
                ),
                child: Text(tr(context, 'record.restored'), style: const TextStyle(color: RS.warnInk, fontSize: 13.5, height: 1.35)),
              ),
              const SizedBox(height: 8),
            ],
            if (_problem != null) ...[
              Row(
                children: [
                  const Icon(Icons.error_outline, color: RS.err, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(tr(context, _problem!), style: const TextStyle(color: Color(0xFF7F1D1D), fontSize: 14)),
                  ),
                  if (_problemForever) TextButton(onPressed: Geolocator.openAppSettings, child: Text(tr(context, 'record.settings'))),
                ],
              ),
              const SizedBox(height: 8),
            ],
            Row(
              children: [
                Expanded(
                  child: _Num(label: tr(context, 'record.time'), value: _elapsed()),
                ),
                Expanded(
                  child: _Num(label: tr(context, 'record.distance'), value: '${fmtNum(context, _distanceM / 1000, 2)} km'),
                ),
                Expanded(
                  child: _Num(label: tr(context, 'record.gain'), value: '${fmtNum(context, _gainM)} m'),
                ),
                Expanded(
                  child: _Num(label: tr(context, 'record.altitude'), value: ele == null || ele == 0 ? '-' : '${fmtNum(context, ele)} m'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(status, style: const TextStyle(fontSize: 12.5, color: RS.muted, height: 1.35)),
            if (_heading != null)
              Text(tr(context, 'record.facing', {'dir': _dir(_heading!), 'deg': _heading!.round()}), style: const TextStyle(fontSize: 12.5, color: RS.muted)),
            const SizedBox(height: 8),
            if (_status != _Status.idle && _last != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  style: TextButton.styleFrom(padding: EdgeInsets.zero),
                  onPressed: _mark,
                  icon: const Icon(Icons.add_location_alt_outlined),
                  label: Text('${tr(context, 'wpt.mark')}${_waypoints.isEmpty ? '' : ' (${_waypoints.length})'}'),
                ),
              ),
            switch (_status) {
              _Status.idle => SignButton(label: tr(context, 'record.start'), onPressed: _start),
              _Status.recording => Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(onPressed: _pause, icon: const Icon(Icons.pause), label: Text(tr(context, 'record.pause'))),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(onPressed: _finish, icon: const Icon(Icons.stop), label: Text(tr(context, 'record.stop'))),
                  ),
                ],
              ),
              _Status.paused => Row(
                children: [
                  Expanded(
                    child: SignButton(label: tr(context, 'record.resume'), onPressed: _start),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(onPressed: _finish, icon: const Icon(Icons.stop), label: Text(tr(context, 'record.stop'))),
                  ),
                ],
              ),
            },
            if (followRoute.value != null && _status == _Status.idle)
              TextButton(
                onPressed: () => followRoute.value = null,
                child: Text('${tr(context, 'chat.cancel')}: ${followRoute.value!.name}', maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
          ],
        ),
      ),
    );
  }
}

/// Blue position dot with a cone showing which way the phone faces.
class _HikerMarker extends StatelessWidget {
  const _HikerMarker({required this.heading});

  final double? heading;

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        if (heading != null)
          Transform.rotate(
            angle: heading! * math.pi / 180,
            child: CustomPaint(size: const Size(44, 44), painter: _ConePainter()),
          ),
        Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            color: const Color(0xFF1D4ED8),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 3),
          ),
        ),
      ],
    );
  }
}

class _ConePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final path = Path()
      ..moveTo(c.dx, 0)
      ..lineTo(c.dx + 9, c.dy - 4)
      ..lineTo(c.dx - 9, c.dy - 4)
      ..close();
    canvas.drawPath(path, Paint()..color = const Color(0xFF1D4ED8));
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(_ConePainter old) => false;
}

class _Num extends StatelessWidget {
  const _Num({required this.label, required this.value});

  final String label, value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, color: RS.muted),
        ),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            value,
            style: RS.head(24, color: RS.z9, weight: FontWeight.w700),
          ),
        ),
      ],
    );
  }
}
