import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:material_ui/material_ui.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

import '../api.dart';
import '../app_state.dart';
import '../i18n.dart';
import '../location_hub.dart';
import '../recording_math.dart';
import '../storage.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/contour_header.dart';
import '../widgets/gpx_actions.dart';
import '../widgets/trail_map.dart';
import '../mesh/mesh_service.dart';
import 'photo_stamp_screen.dart';
import 'live_share_sheet.dart';
import '../live_share.dart';

/// Route to follow while recording, set by "Rekam di jalur ini" on a route page.
final followRoute = ValueNotifier<RouteDetail?>(null);

/// A point to show on the Rekam map (for example a teammate's SOS).
final mapFocus = ValueNotifier<LatLng?>(null);

enum _Status { idle, recording, paused }

/// Waypoint kinds the hiker can mark, with their map icons.
const waypointKinds = <String, IconData>{
  'pos': Icons.flag_outlined,
  'water': Icons.water_drop_outlined,
  'camp': Icons.cabin_outlined,
  'summit': Icons.landscape_outlined,
  'junction': Icons.call_split,
  'cliff': Icons.terrain,
  'signal': Icons.signal_cellular_alt,
  'danger': Icons.warning_amber_rounded,
  'other': Icons.place_outlined,
};

/// The track being recorded now (empty when not recording), for sharing it in the group chat.
List<LatLng> Function() liveTrack = () => const [];

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
  static const _minStepM = 5.0; // smaller moves (or within the fix accuracy) are standing still
  static const _maxSpeedMs = 15.0; // 54 km/h: faster jumps are GPS errors
  static const _offRouteMinM = 40.0; // off the trail from here (or 1.5x the GPS accuracy)

  final _map = MapController();
  final _points = <TrackPoint>[];
  final _waypoints = <Waypoint>[];
  final _segStarts = <int>[0]; // first point of each part (new part after pause or restore)
  final _recordedLL = <LatLng>[]; // map copy of _points, kept in step (no remapping per frame)
  List<LatLng> _plannedLL = const [];
  StreamSubscription<Position>? _gps; // LocationHub positions while previewing or recording
  final _previewKey = Object(), _recordKey = Object();
  bool _previewOn = false, _recordOn = false;
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
  bool _problemForever = false, _restored = false, _starting = false, _newSegment = false;
  bool _appVisible = true;

  // Map camera: follow the hiker, and optionally turn the map with the hiker's heading.
  bool _follow = true, _turnWithHeading = false, _zoomedToHiker = false;
  double? _heading; // degrees from north, phone compass (GPS course as fallback)
  DateTime _headingAt = DateTime.fromMillisecondsSinceEpoch(0), _compassAt = DateTime.fromMillisecondsSinceEpoch(0);
  double _mapRotation = 0;
  bool _offRoute = false;
  RouteProgress? _progress;
  TrailProfile? _profile; // of the followed trail, for the climb to the next pos
  ({String name, double km, double hours})? _next; // next pos / water / camp / summit ahead

  Duration get _movingTime => _movingBefore + _moving.elapsed;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    followRoute.addListener(_onFollow);
    mapFocus.addListener(_onFocus);
    mesh.addListener(_onMesh);
    liveTrack = () => _status == _Status.idle ? const <LatLng>[] : List.of(_recordedLL);
    _onFocus(); // set before this tab was first opened ("Lihat di peta" from the group)
    _plannedLL = _toLL(followRoute.value);
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
    mapFocus.removeListener(_onFocus);
    mesh.removeListener(_onMesh);
    liveTrack = () => const [];
    _gps?.cancel();
    LocationHub.instance.release(_previewKey);
    LocationHub.instance.release(_recordKey);
    _compass?.cancel();
    _ticker?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final visible = state == AppLifecycleState.resumed;
    if (visible != _appVisible) {
      _appVisible = visible;
      _syncSensors(); // compass and preview only while someone can see them
    }
    // Leaving the app: write the draft now, the system may close the app later.
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) _saveDraft();
  }

  static List<LatLng> _toLL(RouteDetail? r) => r?.coordinates.map((p) => LatLng(p[0], p[1])).toList() ?? const [];

  void _setRecording(bool on) => AppScope.read(context).setRecording(on);

  // ---------------------------------------------------------------------------
  // Sensors: compass while the tab is on screen; a light position preview before recording.
  // The recording itself does not need either, so a hidden tab or a locked phone stops them.
  // ---------------------------------------------------------------------------

  Future<void> _syncSensors() async {
    final onScreen = widget.active && _appVisible;
    if (onScreen && _compass == null) {
      _compass = FlutterCompass.events?.listen(_onCompass, onError: (_) {});
    } else if (!onScreen && _compass != null) {
      await _compass?.cancel();
      _compass = null;
    }
    if (onScreen && _status == _Status.idle && !_previewOn) {
      final p = await Geolocator.checkPermission();
      if (!(p == LocationPermission.always || p == LocationPermission.whileInUse)) return;
      if (!await Geolocator.isLocationServiceEnabled()) return;
      // Things may have changed during the awaits: only start if still wanted and not started.
      if (!mounted || !widget.active || !_appVisible || _status != _Status.idle || _previewOn) return;
      _previewOn = true;
      _listen();
      LocationHub.instance.require(_previewKey, LocNeed.preview);
    } else if ((!onScreen || _status != _Status.idle) && _previewOn) {
      _previewOn = false;
      LocationHub.instance.release(_previewKey);
    }
  }

  /// One subscription to the app's GPS stream; what a fix means depends on the state.
  void _listen() {
    _gps ??= LocationHub.instance.positions.listen(
      (p) => _status == _Status.recording ? _onPosition(p) : _onPreview(p),
      onError: (Object e) {
        if (_status == _Status.recording) _onLocationError(e);
      },
    );
  }

  void _onCompass(CompassEvent e) {
    final h = e.heading;
    if (h == null || !mounted) return;
    final now = DateTime.now();
    _compassAt = now;
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
    _checkRoute(p);
  }

  // ---------------------------------------------------------------------------
  // Camera
  // ---------------------------------------------------------------------------

  void _onFollow() {
    if (!mounted) return;
    setState(() {
      _plannedLL = _toLL(followRoute.value);
      _progress = null;
      _profile = null;
      _next = null;
      _offRoute = false;
    });
    if (followRoute.value != null) WidgetsBinding.instance.addPostFrameCallback((_) => _fitAll());
  }

  void _onMesh() {
    if (mounted && widget.active) setState(() {});
  }

  void _onFocus() {
    final p = mapFocus.value;
    if (p == null) return;
    mapFocus.value = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _follow = false);
      try {
        _map.move(p, 17);
      } catch (_) {}
    });
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
    final pts = <LatLng>[..._plannedLL, ..._recordedLL, if (_last != null) LatLng(_last!.latitude, _last!.longitude)];
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
    // "Approximate location" (Android 12+) is 1-3 km: every fix would be thrown away.
    if (await Geolocator.getLocationAccuracy() == LocationAccuracyStatus.reduced) {
      setState(() {
        _problem = 'record.precise';
        _problemForever = true;
      });
      return false;
    }
    // Android 13+: the "recording" notification needs this; the recording works without it.
    try {
      await ph.Permission.notification.request();
    } catch (_) {}
    return true;
  }

  Future<void> _start() async {
    if (_starting || _recordOn) return; // a second tap while starting must not start twice
    _starting = true;
    try {
      if (!await _ready() || !mounted) return;
      if (!mounted) return;
      _previewOn = false;
      LocationHub.instance.release(_previewKey);
      _startedAt ??= DateTime.now();
      _restored = false;
      if (_points.isNotEmpty) _newSegment = true; // resuming: the gap is not walked distance
      _moving.start();
      _recordOn = true;
      _listen();
      LocationHub.instance
        ..lang = AppScope.read(context).lang
        ..require(_recordKey, LocNeed.record);
      _ticker?.cancel();
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
      setState(() => _status = _Status.recording);
      _setRecording(true);
      _saveDraft();
    } finally {
      _starting = false;
    }
  }

  void _stopStream() {
    _recordOn = false;
    LocationHub.instance.release(_recordKey);
    _ticker?.cancel();
    _ticker = null;
    _moving.stop();
  }

  /// The stream failed: stop cleanly and say why instead of looking like it still records.
  void _onLocationError(Object e) {
    if (kDebugMode) debugPrint('RuteStrip location error: $e');
    _stopStream();
    if (!mounted) return;
    setState(() {
      _problem = switch (e) {
        PermissionDeniedException() => 'record.permission',
        LocationServiceDisabledException() => 'record.service_off',
        _ => 'record.gps_error',
      };
      _status = _points.isEmpty ? _Status.idle : _Status.paused;
    });
    _setRecording(false);
    _saveDraft();
    _syncSensors();
  }

  void _onPosition(Position p) {
    if (!mounted) return;
    setState(() {
      _last = p;
      // No compass reading for a few seconds (no sensor, or it stopped): the GPS course is the heading while walking.
      if (DateTime.now().difference(_compassAt).inSeconds > 3 && p.speed > 0.6 && p.heading >= 0) _heading = p.heading;
    });
    _autoCamera(p);
    _checkRoute(p);
    if (_status != _Status.recording || p.accuracy > _maxAccuracyM) return;

    final point = TrackPoint(p.latitude, p.longitude, p.altitude == 0 ? null : p.altitude, p.timestamp.toUtc());
    if (_points.isNotEmpty) {
      final prev = _points.last;
      // GPS time only moves forward; an older fix is a stale one. (The phone clock is never used.)
      if (!point.time.isAfter(prev.time)) return;
      final step = Geolocator.distanceBetween(prev.lat, prev.lng, point.lat, point.lng);
      final seconds = point.time.difference(prev.time).inMilliseconds / 1000;
      if (_newSegment) {
        // First fix after a pause or restore: start a new part, the gap is not counted.
        _newSegment = false;
        _jumps = 0;
        _segStarts.add(_points.length);
      } else if (step / seconds > _maxSpeedMs) {
        // Three jumps in a row from a lone first point: that first point was the bad one.
        if (++_jumps >= 3 && _points.length == 1) {
          _points.clear();
          _recordedLL.clear();
          _jumps = 0;
        } else {
          return;
        }
      } else if (step < math.max(_minStepM, p.accuracy)) {
        return; // standing still: GPS wobble is not distance
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
    _recordedLL.add(LatLng(point.lat, point.lng));
    // Draft every 5 points or 10 seconds: a killed app loses at most a few seconds of walking.
    if (++_sinceDraft >= 5 || DateTime.now().difference(_draftAt).inSeconds >= 10) _saveDraft();
  }

  /// Off-route warning (with a buzz when it starts) and progress along a followed trail.
  void _checkRoute(Position p) {
    final route = followRoute.value?.coordinates ?? const <List<double>>[];
    final prog = routeProgress(route, p.latitude, p.longitude);
    if (prog == null) {
      if (_progress != null) setState(() => _progress = null);
      return;
    }
    final limit = math.max(_offRouteMinM, p.accuracy * 1.5);
    final off = _offRoute ? prog.offRouteM > limit * 0.7 : prog.offRouteM > limit;
    if (off && !_offRoute && _status == _Status.recording) HapticFeedback.heavyImpact();
    final next = off ? null : _nextStop(route, prog);
    setState(() {
      _progress = prog;
      _offRoute = off;
      _next = next;
    });
  }

  static const _stopKinds = {'pos', 'water', 'camp', 'summit'};

  /// The nearest marked stop ahead on the followed trail (your own marks, the group's
  /// marks, and the trail's summit), with distance and walking time to it.
  ({String name, double km, double hours})? _nextStop(List<List<double>> route, RouteProgress prog) {
    final stops = <(String, double, double)>[
      for (final w in _waypoints)
        if (_stopKinds.contains(w.kind)) (tr(context, 'wpt.${w.kind}'), w.lat, w.lng),
      for (final c in mesh.chat)
        if (_stopKinds.contains(c.body['kind']) && c.body['lat'] is num && c.body['lng'] is num)
          ('${c.body['text'] ?? tr(context, 'wpt.${c.body['kind']}')}', (c.body['lat'] as num).toDouble(), (c.body['lng'] as num).toDouble()),
    ];
    final top = TrailProfile.summitOf(route);
    if (top != null) stops.add((tr(context, 'detail.summit'), top[0], top[1]));
    ({String name, double at})? best;
    for (final (name, lat, lng) in stops) {
      final at = routeProgress(route, lat, lng);
      if (at == null || at.offRouteM > 120) continue; // not on this trail
      if (at.doneM <= prog.doneM + 30) continue; // already passed (or right here)
      if (best == null || at.doneM < best.at) best = (name: name, at: at.doneM);
    }
    if (best == null) return null;
    final distM = best.at - prog.doneM;
    final climb = (_profile ??= TrailProfile(route)).climbBetween(prog.doneM, best.at);
    final hours = _movingTime.inSeconds / 3600;
    final own = hours > 0.1 && _points.length > 10 ? _distanceM / 1000 / hours : 0.0;
    return (name: best.name, km: distM / 1000, hours: walkHours(distM, climb, kmh: own >= 1 && own <= 8 ? own : 5));
  }

  /// [release]: let a pending sign-out happen. Finishing keeps it back until the
  /// recording is saved or discarded, so the save dialog is never pulled away.
  void _pause({bool release = true}) {
    _stopStream();
    setState(() => _status = _Status.paused);
    if (release) _setRecording(false);
    _saveDraft();
    _syncSensors();
  }

  Future<void> _mark() async {
    final p = _last;
    if (p == null) return;
    final kind = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
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
      ),
    );
    if (kind == null || !mounted) return;
    setState(
      () => _waypoints.add(Waypoint(lat: p.latitude, lng: p.longitude, ele: p.altitude == 0 ? null : p.altitude, time: DateTime.now().toUtc(), kind: kind)),
    );
    _saveDraft();
    final label = tr(context, 'wpt.$kind');
    if (mesh.running) mesh.shareSpot(label, p.latitude, p.longitude, kind: kind); // the group sees it too
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr(context, 'wpt.added', {'name': label}))));
  }

  /// A photo with the hike info drawn on it (place, height, time, distance so far).
  Future<void> _photo() async {
    final p = _last;
    await takeStampedPhoto(
      context,
      StampInfo(
        title: followRoute.value?.name ?? tr(context, 'record.title'),
        lat: p?.latitude,
        lng: p?.longitude,
        ele: p?.altitude,
        distanceKm: _distanceM / 1000,
        gainM: _gainM,
      ),
    );
  }

  /// Saves what is recorded so far as its own recording and carries on with a new one
  /// from this spot (day 1 and day 2, or the way up and the way down).
  Future<void> _cut() async {
    if (_points.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr(context, 'record.too_short'))));
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr(context, 'record.cut')),
        content: Text(tr(context, 'record.cut.confirm')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr(context, 'chat.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr(context, 'record.cut'))),
        ],
      ),
    );
    if (ok != true || !mounted || _points.length < 2 || _startedAt == null) return;
    final name = _defaultName();
    await RecordingStore.save(
      Recording(
        id: _startedAt!.millisecondsSinceEpoch.toString(),
        name: name,
        startedAt: _startedAt!,
        points: List.of(_points),
        distanceKm: _distanceM / 1000,
        gainM: _gainM,
        movingSeconds: _movingTime.inSeconds,
        waypoints: List.of(_waypoints),
        segmentStarts: List.of(_segStarts),
      ),
    );
    if (!mounted) return;
    final last = _points.last;
    setState(() {
      // The new recording starts where the saved one ended.
      _points
        ..clear()
        ..add(last);
      _recordedLL
        ..clear()
        ..add(LatLng(last.lat, last.lng));
      _waypoints.clear();
      _segStarts
        ..clear()
        ..add(0);
      _distanceM = 0;
      _gainM = 0;
      _jumps = 0;
      _startedAt = DateTime.now();
      _moving.reset(); // keeps running while recording
      _movingBefore = Duration.zero;
    });
    await _saveDraft();
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr(context, 'record.cut.done', {'name': name}))));
  }

  Future<void> _finish() async {
    _pause(release: false);
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
          TextButton(
            style: TextButton.styleFrom(foregroundColor: RS.err), // throwing the recording away: red, like the confirm
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr(context, 'record.discard')),
          ),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr(context, 'record.save'))),
        ],
      ),
    );
    if (!mounted) return;
    if (keep == null) {
      _setRecording(false); // dialog closed without a choice: keep the draft, nothing is lost
      return;
    }
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
          segmentStarts: List.of(_segStarts),
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
      if (sure == true) {
        await _reset();
      } else {
        _setRecording(false);
      }
    }
  }

  Future<void> _reset() async {
    await RecordingStore.clearDraft(); // queued after any pending draft write
    if (!mounted) return;
    setState(() {
      _points.clear();
      _recordedLL.clear();
      _waypoints.clear();
      _segStarts
        ..clear()
        ..add(0);
      _distanceM = 0;
      _gainM = 0;
      _refEle = null;
      _jumps = 0;
      _newSegment = false;
      _startedAt = null;
      _moving.reset();
      _movingBefore = Duration.zero;
      _restored = false;
      _offRoute = false;
      _status = _Status.idle;
    });
    _setRecording(false);
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
      'segments': List.of(_segStarts),
      'distance_m': _distanceM,
      'gain_m': _gainM,
      'ref_ele': _refEle,
      'moving_ms': _movingTime.inMilliseconds,
      if (f != null) 'follow': {'id': f.id, 'name': f.name, 'coordinates': f.coordinates},
    });
  }

  Future<void> _restoreDraft() async {
    final d = await RecordingStore.loadDraft();
    if (d == null || !mounted || _status != _Status.idle) return;
    try {
      final points = (d['points'] as List).map((p) => TrackPoint.fromJson(p as List)).toList();
      setState(() {
        _startedAt = DateTime.parse('${d['started_at']}');
        _points
          ..clear()
          ..addAll(points);
        _recordedLL
          ..clear()
          ..addAll(points.map((p) => LatLng(p.lat, p.lng)));
        _waypoints
          ..clear()
          ..addAll((d['waypoints'] as List? ?? const []).map((w) => Waypoint.fromJson(w as Map)));
        _segStarts
          ..clear()
          ..addAll((d['segments'] as List? ?? const [0]).map((e) => (e as num).toInt()));
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
      _syncSensors();
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

  /// Time to the end of the trail: the hiker's own average once there is enough of it,
  /// otherwise the flat part of Naismith's rule (5 km/h). Climbs make it longer; said in the label.
  String _timeLeft(BuildContext context, double leftM) {
    final hours = _movingTime.inSeconds / 3600;
    final own = hours > 0.1 && _points.length > 10 ? _distanceM / 1000 / hours : 0.0;
    final mine = own >= 1 && own <= 8;
    final kmh = mine ? own : 5.0;
    return tr(context, mine ? 'guide.eta.mine' : 'guide.eta.flat', {'t': fmtHours(context, leftM / 1000 / kmh)});
  }

  String _dir(double degrees) => tr(context, 'dir.${compassIndex(degrees)}');

  /// Recorded parts as separate lines (no straight line across a pause).
  List<List<LatLng>> get _parts {
    final out = <List<LatLng>>[];
    for (var i = 0; i < _segStarts.length; i++) {
      final a = _segStarts[i], b = i + 1 < _segStarts.length ? _segStarts[i + 1] : _recordedLL.length;
      if (a < b && b <= _recordedLL.length && b - a >= 2) out.add(_recordedLL.sublist(a, b));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final follow = followRoute.value;
    final planned = _plannedLL;
    final here = _last == null ? null : LatLng(_last!.latitude, _last!.longitude);
    final expired = AppScope.of(context).sessionExpired;

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
          if (expired)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              color: RS.warnBg,
              child: Text(tr(context, 'record.session'), style: const TextStyle(color: RS.warnInk, fontSize: 13.5, height: 1.35)),
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
                    const BaseTiles(),
                    if (planned.length >= 2)
                      PolylineLayer(
                        polylines: [Polyline(points: planned, strokeWidth: 5, color: RS.z9.withValues(alpha: 0.45))],
                      ),
                    PolylineLayer(
                      polylines: [
                        for (final part in _parts) ...[
                          Polyline(points: part, strokeWidth: 7, color: Colors.white),
                          Polyline(points: part, strokeWidth: 4.5, color: RS.z7),
                        ],
                      ],
                    ),
                    // Teammates' GPS accuracy, like the halo around a position.
                    CircleLayer(
                      circles: [
                        for (final m in mesh.members.values)
                          if (m.id != mesh.myId && m.hasPosition && (m.accuracy ?? 0) > 8)
                            CircleMarker(
                              point: LatLng(m.lat!, m.lng!),
                              radius: m.accuracy!.clamp(8, 150),
                              useRadiusInMeter: true,
                              color: (mesh.sos.containsKey(m.id) ? RS.err : mesh.colorOf(m.id)).withValues(alpha: 0.12),
                              borderColor: (mesh.sos.containsKey(m.id) ? RS.err : mesh.colorOf(m.id)).withValues(alpha: 0.35),
                              borderStrokeWidth: 1,
                            ),
                      ],
                    ),
                    // Teammates' last positions as dotted trails.
                    PolylineLayer(
                      polylines: [
                        for (final m in mesh.members.values)
                          if (m.id != mesh.myId && m.trail.length >= 2)
                            Polyline(
                              points: [for (final t in m.trail) LatLng(t[0], t[1])],
                              strokeWidth: 3,
                              color: mesh.sos.containsKey(m.id) ? RS.err : mesh.colorOf(m.id),
                              pattern: const StrokePattern.dotted(),
                            ),
                      ],
                    ),
                    MarkerLayer(
                      markers: [
                        if (planned.length >= 2) ...[
                          Marker(point: planned.first, width: 30, height: 30, rotate: true, child: const _Flag(finish: false)),
                          Marker(point: planned.last, width: 30, height: 30, rotate: true, child: const _Flag(finish: true)),
                        ],
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
                        // Spots teammates marked in the group chat (water, cliff, danger...).
                        for (final c in mesh.chat.reversed.where((c) => c.body['kind'] is String && c.body['lat'] is num && c.body['lng'] is num).take(40))
                          Marker(
                            point: LatLng((c.body['lat'] as num).toDouble(), (c.body['lng'] as num).toDouble()),
                            width: 30,
                            height: 30,
                            rotate: true,
                            child: Semantics(
                              label: '${c.body['text'] ?? ''}, ${c.name}',
                              child: Container(
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  shape: BoxShape.circle,
                                  border: Border.all(color: c.from == mesh.myId ? RS.z9 : mesh.colorOf(c.from), width: 2.5),
                                ),
                                child: Icon(
                                  waypointKinds[c.body['kind']] ?? Icons.place_outlined,
                                  size: 16,
                                  color: c.body['kind'] == 'danger' || c.body['kind'] == 'cliff' ? RS.err : RS.z9,
                                ),
                              ),
                            ),
                          ),
                        for (final m in mesh.members.values)
                          if (m.hasPosition && m.id != mesh.myId)
                            Marker(
                              point: LatLng(m.lat!, m.lng!),
                              width: 120,
                              height: 64,
                              rotate: true, // label stays upright; the arrow adds the map turn
                              child: _TeamMarker(member: m, sos: mesh.sos.containsKey(m.id), color: mesh.colorOf(m.id), mapRotation: _mapRotation),
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
                if (follow != null && here != null && _progress != null) Positioned(left: 12, right: 72, top: 12, child: _guidance(context, here, _progress!)),
                // Bottom stays clear of the map credits; the column scrolls on short screens.
                Positioned(right: 12, top: 12, bottom: 30, child: SingleChildScrollView(child: _controls(context, here))),
              ],
            ),
          ),
          _panel(context),
        ],
      ),
    );
  }

  Widget _guidance(BuildContext context, LatLng here, RouteProgress prog) {
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
            else ...[
              Text(
                tr(context, 'guide.left', {'km': fmtNum(context, prog.leftM / 1000, 1), 'pct': (prog.fraction * 100).round()}),
                style: const TextStyle(color: RS.ink, fontWeight: FontWeight.w700, fontSize: 14),
              ),
              Text(_timeLeft(context, prog.leftM), style: const TextStyle(color: RS.muted, fontSize: 12.5)),
              if (_next != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    tr(context, 'guide.next', {'name': _next!.name, 'km': fmtNum(context, _next!.km, 1), 't': fmtHours(context, _next!.hours)}),
                    style: const TextStyle(color: RS.z9, fontWeight: FontWeight.w700, fontSize: 13),
                  ),
                ),
            ],
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
      padding: const EdgeInsets.only(bottom: 6),
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
              width: 46,
              height: 46,
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
        // "Show the trail and you" only means something with a trail or a recording.
        if (_plannedLL.length >= 2 || _recordedLL.length >= 2) btn(Icons.zoom_out_map, tr(context, 'map.fit'), _fitAll),
        btn(Icons.terrain, tr(context, topoMap.value ? 'map.topo.off' : 'map.topo'), () => setState(() => topoMap.value = !topoMap.value), on: topoMap.value),
        if (here != null) btn(_follow ? Icons.my_location : Icons.location_searching, tr(context, 'record.center'), _centerOnMe, on: _follow),
        btn(
          Icons.sos,
          tr(context, 'sos.title'),
          () => showEmergency(context, lat: _last?.latitude, lng: _last?.longitude, accuracy: _last?.accuracy),
          child: const Icon(Icons.sos, color: RS.err),
        ),
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
        // Large text sizes: the panel scrolls instead of pushing the buttons off screen.
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.5),
        child: SingleChildScrollView(
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
              for (final m in mesh.members.values)
                if (m.id != mesh.myId && (mesh.distanceTo(m) ?? 0) > MeshService.separatedM)
                  Text(
                    tr(context, 'grp.far', {'name': m.name, 'm': fmtNum(context, mesh.distanceTo(m))}),
                    style: const TextStyle(fontSize: 13, color: RS.warnInk, fontWeight: FontWeight.w700),
                  ),
              if (_heading != null)
                Text(
                  tr(context, 'record.facing', {'dir': _dir(_heading!), 'deg': _heading!.round() % 360}),
                  style: const TextStyle(fontSize: 12.5, color: RS.muted),
                ),
              const SizedBox(height: 8),
              if (_last != null)
                Wrap(
                  spacing: 16,
                  children: [
                    if (_status != _Status.idle)
                      TextButton.icon(
                        style: TextButton.styleFrom(padding: EdgeInsets.zero),
                        onPressed: _mark,
                        icon: const Icon(Icons.add_location_alt_outlined),
                        label: Text('${tr(context, 'wpt.mark')}${_waypoints.isEmpty ? '' : ' (${_waypoints.length})'}'),
                      ),
                    ListenableBuilder(
                      listenable: LiveShare.instance,
                      builder: (context, _) => TextButton.icon(
                        style: TextButton.styleFrom(padding: EdgeInsets.zero),
                        onPressed: () => showLiveShareSheet(context),
                        icon: Icon(LiveShare.instance.active ? Icons.share_location : Icons.share_location_outlined),
                        label: Text(tr(context, LiveShare.instance.active ? 'live.on' : 'live.button')),
                      ),
                    ),
                    TextButton.icon(
                      style: TextButton.styleFrom(padding: EdgeInsets.zero),
                      onPressed: _photo,
                      icon: const Icon(Icons.photo_camera_outlined),
                      label: Text(tr(context, 'stamp.button')),
                    ),
                    if (_status != _Status.idle)
                      TextButton.icon(
                        style: TextButton.styleFrom(padding: EdgeInsets.zero),
                        onPressed: _cut,
                        icon: const Icon(Icons.content_cut),
                        label: Text(tr(context, 'record.cut')),
                      ),
                  ],
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
              if (_status == _Status.idle)
                TextButton.icon(
                  onPressed: () async {
                    final r = await importGpx(context);
                    if (r != null && context.mounted) followInRecord(context, r);
                  },
                  icon: const Icon(Icons.file_open_outlined),
                  label: Text(tr(context, 'gpx.import.follow')),
                ),
              if (followRoute.value != null && _status == _Status.idle)
                TextButton(
                  onPressed: () => followRoute.value = null,
                  child: Text('${tr(context, 'chat.cancel')}: ${followRoute.value!.name}', maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Start (dark circle with a flag) and finish (checkered) of the followed trail.
class _Flag extends StatelessWidget {
  const _Flag({required this.finish});

  final bool finish;

  @override
  Widget build(BuildContext context) => Semantics(
    label: tr(context, finish ? 'map.finish' : 'map.start'),
    child: Container(
      decoration: BoxDecoration(
        color: finish ? Colors.white : RS.z9,
        shape: BoxShape.circle,
        border: Border.all(color: finish ? RS.z9 : Colors.white, width: 2),
      ),
      child: Icon(finish ? Icons.sports_score : Icons.flag, size: 16, color: finish ? RS.z9 : Colors.white),
    ),
  );
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

/// A teammate from the offline group: initial in a circle, first name under it.
class _TeamMarker extends StatelessWidget {
  const _TeamMarker({required this.member, required this.sos, required this.color, required this.mapRotation});

  final MeshMember member;
  final bool sos;
  final Color color;
  final double mapRotation;

  @override
  Widget build(BuildContext context) {
    final first = member.name.trim().split(' ').first;
    final stale = DateTime.now().difference(member.posTime ?? member.lastSeen).inMinutes >= 10;
    final c = sos ? RS.err : (stale ? RS.muted : color);
    final heading = member.heading;
    return Semantics(
      label: '${member.name}${sos ? ', SOS' : ''}',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Same look as your own position: a dot with a white ring, and an arrow for
          // the walking direction (turned with the map).
          SizedBox(
            width: 40,
            height: 40,
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (heading != null && !stale)
                  Transform.rotate(
                    angle: (heading + mapRotation) * math.pi / 180,
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: CustomPaint(size: const Size(14, 10), painter: _ArrowPainter(c)),
                    ),
                  ),
                Container(
                  width: 26,
                  height: 26,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: c,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 3),
                    boxShadow: const [BoxShadow(color: Color(0x40000000), blurRadius: 3)],
                  ),
                  child: Text(
                    first.isEmpty ? '?' : first[0].toUpperCase(),
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          Container(
            margin: const EdgeInsets.only(top: 2),
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.9), borderRadius: BorderRadius.circular(3)),
            child: Text(
              first,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: c),
            ),
          ),
        ],
      ),
    );
  }
}

class _ArrowPainter extends CustomPainter {
  _ArrowPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(size.width / 2, 0)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(_ArrowPainter old) => old.color != color;
}
