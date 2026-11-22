import 'dart:async';

import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../app_state.dart';
import '../i18n.dart';
import '../storage.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/contour_header.dart';

/// Route to follow while recording, set by "Rekam di jalur ini" on a route page.
final followRoute = ValueNotifier<RouteDetail?>(null);

enum _Status { idle, recording, paused }

/// GPS recording: a foreground service keeps it going with the screen off.
class RecordScreen extends StatefulWidget {
  const RecordScreen({super.key, required this.active});

  final bool active;

  @override
  State<RecordScreen> createState() => _RecordScreenState();
}

class _RecordScreenState extends State<RecordScreen> {
  static const _maxAccuracyM = 30.0; // fixes worse than this are skipped
  static const _gainStepM = 3.0; // altitude changes smaller than this are GPS noise

  final _map = MapController();
  final _points = <TrackPoint>[];
  StreamSubscription<Position>? _sub;
  Timer? _ticker;
  _Status _status = _Status.idle;
  Position? _last;
  DateTime? _startedAt;
  final _moving = Stopwatch();
  double _distanceM = 0, _gainM = 0;
  double? _refEle;
  String? _problem;
  bool _problemForever = false;
  bool _follow = true;

  @override
  void initState() {
    super.initState();
    followRoute.addListener(_onFollow);
  }

  @override
  void dispose() {
    followRoute.removeListener(_onFollow);
    _sub?.cancel();
    _ticker?.cancel();
    super.dispose();
  }

  void _onFollow() {
    if (!mounted) return;
    setState(() {});
    final r = followRoute.value;
    if (r != null && r.coordinates.length >= 2 && _last == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        try {
          _map.fitCamera(CameraFit.coordinates(coordinates: r.coordinates.map((p) => LatLng(p[0], p[1])).toList(), padding: const EdgeInsets.all(40)));
        } catch (_) {}
      });
    }
  }

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
    _startedAt ??= DateTime.now();
    _moving.start();
    _sub = Geolocator.getPositionStream(
      locationSettings: AndroidSettings(
        accuracy: LocationAccuracy.best,
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
    ).listen(_onPosition, onError: (_) => setState(() => _problem = 'record.permission'));
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
    setState(() => _status = _Status.recording);
  }

  void _onPosition(Position p) {
    if (!mounted) return;
    setState(() => _last = p);
    if (_status != _Status.recording || p.accuracy > _maxAccuracyM) return;

    final point = TrackPoint(p.latitude, p.longitude, p.altitude == 0 ? null : p.altitude, p.timestamp.toUtc());
    if (_points.isNotEmpty) {
      final prev = _points.last;
      _distanceM += Geolocator.distanceBetween(prev.lat, prev.lng, point.lat, point.lng);
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
    if (_follow) {
      try {
        _map.move(LatLng(p.latitude, p.longitude), _map.camera.zoom < 14 ? 16 : _map.camera.zoom);
      } catch (_) {}
    }
  }

  void _pause() {
    _sub?.cancel();
    _sub = null;
    _ticker?.cancel();
    _moving.stop();
    setState(() => _status = _Status.paused);
  }

  Future<void> _finish() async {
    _pause();
    if (_points.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr(context, 'record.too_short'))));
      _reset();
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
          movingSeconds: _moving.elapsed.inSeconds,
        ),
      );
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr(context, 'record.saved'))));
      _reset();
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
      if (sure == true) _reset();
    }
  }

  void _reset() {
    setState(() {
      _points.clear();
      _distanceM = 0;
      _gainM = 0;
      _refEle = null;
      _startedAt = null;
      _moving.reset();
      _status = _Status.idle;
    });
  }

  String _defaultName() {
    final t = _startedAt ?? DateTime.now();
    final follow = followRoute.value?.name;
    final stamp = '${t.day}/${t.month}/${t.year} ${t.hour.toString().padLeft(2, '0')}.${t.minute.toString().padLeft(2, '0')}';
    return follow != null ? '$follow ($stamp)' : '${tr(context, 'record.title')} $stamp';
  }

  String _elapsed() {
    final s = _moving.elapsed.inSeconds;
    final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
    return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}' : '${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }

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
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const HeaderBar(),
                Text(tr(context, 'record.title').toUpperCase(), style: RS.head(34, color: Colors.white)),
                const SizedBox(height: 4),
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
                    initialCameraFit: planned.length >= 2 ? CameraFit.coordinates(coordinates: planned, padding: const EdgeInsets.all(40)) : null,
                    interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
                    onPositionChanged: (_, hasGesture) {
                      if (hasGesture && _follow) setState(() => _follow = false);
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
                    if (here != null)
                      MarkerLayer(
                        markers: [
                          Marker(
                            point: here,
                            width: 24,
                            height: 24,
                            child: Container(
                              decoration: BoxDecoration(
                                color: const Color(0xFF1D4ED8),
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.white, width: 3),
                              ),
                            ),
                          ),
                        ],
                      ),
                    SimpleAttributionWidget(
                      source: const Text('OpenStreetMap contributors'),
                      onTap: () => launchUrl(Uri.parse('https://www.openstreetmap.org/copyright'), mode: LaunchMode.externalApplication),
                    ),
                  ],
                ),
                if (here != null && !_follow)
                  Positioned(
                    right: 12,
                    top: 12,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: RS.z9,
                        side: const BorderSide(color: RS.edge),
                      ),
                      onPressed: () {
                        setState(() => _follow = true);
                        _map.move(here, _map.camera.zoom < 14 ? 16 : _map.camera.zoom);
                      },
                      icon: const Icon(Icons.my_location),
                      label: Text(tr(context, 'record.center')),
                    ),
                  ),
              ],
            ),
          ),
          _panel(context),
        ],
      ),
    );
  }

  Widget _panel(BuildContext context) {
    final ele = _last?.altitude;
    return Material(
      color: RS.paper,
      child: Container(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: RS.line)),
        ),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
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
            const SizedBox(height: 6),
            Text(
              _status == _Status.idle
                  ? tr(context, 'record.note')
                  : _last == null
                  ? tr(context, 'record.waiting')
                  : '${tr(context, 'record.points', {'n': _points.length})} · ${tr(context, 'record.accuracy', {'m': _last!.accuracy.round()})}',
              style: const TextStyle(fontSize: 12.5, color: RS.muted, height: 1.35),
            ),
            const SizedBox(height: 10),
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
