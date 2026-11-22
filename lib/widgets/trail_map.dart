import 'dart:async';

import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:material_ui/material_ui.dart';

import '../api.dart';
import '../i18n.dart';
import '../location_hub.dart';
import '../theme.dart';
import 'common.dart';

/// OpenStreetMap tiles with the GPX track, basecamp (circle) and summit (triangle).
/// Attribution follows the OSM tile usage policy.
class TrailMap extends StatelessWidget {
  const TrailMap({super.key, required this.route, this.interactive = false, this.controller, this.rotate = false, this.extra = const []});

  final RouteDetail route;
  final bool interactive;
  final MapController? controller;

  /// Two-finger turning (the full-screen map); the small one on the detail page stays north-up.
  final bool rotate;

  /// Layers on top of the trail (the full-screen map's position dot).
  final List<Widget> extra;

  @override
  Widget build(BuildContext context) {
    final points = route.coordinates.map((p) => LatLng(p[0], p[1])).toList();
    final b = route.basecampPoint, s = route.summitPoint;
    return FlutterMap(
      mapController: controller,
      options: MapOptions(
        initialCameraFit: CameraFit.coordinates(coordinates: points, padding: const EdgeInsets.fromLTRB(32, 32, 32, 56)),
        interactionOptions: InteractionOptions(
          flags: !interactive
              ? InteractiveFlag.none
              : rotate
              ? InteractiveFlag.all
              : InteractiveFlag.all & ~InteractiveFlag.rotate,
        ),
      ),
      children: [
        const BaseTiles(),
        PolylineLayer(
          polylines: [
            Polyline(points: points, strokeWidth: 6, color: Colors.white),
            Polyline(points: points, strokeWidth: 3.5, color: RS.z7),
          ],
        ),
        MarkerLayer(
          markers: [
            if (b != null)
              Marker(
                point: LatLng(b.lat, b.lng),
                width: 22,
                height: 22,
                child: Semantics(
                  label: b.name ?? tr(context, 'detail.basecamp'),
                  child: Container(
                    decoration: BoxDecoration(
                      color: RS.z9,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 3),
                    ),
                  ),
                ),
              ),
            if (s != null)
              Marker(
                point: LatLng(s.lat, s.lng),
                width: 26,
                height: 24,
                child: Semantics(
                  label: tr(context, 'detail.summit'),
                  child: CustomPaint(painter: _SummitPainter()),
                ),
              ),
          ],
        ),
        ...extra,
        // Always visible, as the OSM tile usage policy asks; tap opens the copyright page.
        const OsmAttribution(),
      ],
    );
  }
}

/// Summit marker: the triangle the website uses for peaks.
class _SummitPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(size.width / 2, 1)
      ..lineTo(size.width - 1, size.height - 1)
      ..lineTo(1, size.height - 1)
      ..close();
    // Yellow stays reserved for the main action, so the peak is dark emerald on white.
    canvas.drawPath(path, Paint()..color = RS.z9);
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeJoin = StrokeJoin.round
        ..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(_SummitPainter old) => false;
}

/// Full-screen trail map: your position, and the map can turn with the phone.
class MapScreen extends StatefulWidget {
  const MapScreen({super.key, required this.route});

  final RouteDetail route;

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final _map = MapController();
  final _hubKey = Object();
  StreamSubscription<Position>? _gps;
  StreamSubscription<CompassEvent>? _compass;
  LatLng? _me;
  double? _heading;
  double _rotation = 0;
  bool _turn = false;
  DateTime _turnedAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _startGps();
  }

  @override
  void dispose() {
    _gps?.cancel();
    _compass?.cancel();
    LocationHub.instance.release(_hubKey);
    super.dispose();
  }

  /// Only when location is already allowed: opening a map never pops a permission prompt.
  Future<void> _startGps() async {
    final p = await Geolocator.checkPermission();
    if (!(p == LocationPermission.always || p == LocationPermission.whileInUse)) return;
    if (!mounted) return;
    _gps = LocationHub.instance.positions.listen((pos) {
      if (mounted) setState(() => _me = LatLng(pos.latitude, pos.longitude));
    }, onError: (_) {});
    LocationHub.instance.require(_hubKey, LocNeed.preview);
    Geolocator.getLastKnownPosition()
        .then((pos) {
          if (pos != null && mounted && _me == null) setState(() => _me = LatLng(pos.latitude, pos.longitude));
        })
        .catchError((_) => null);
  }

  void _toggleTurn() {
    if (_turn) {
      _compass?.cancel();
      _compass = null;
      setState(() => _turn = false);
      _map.rotate(0);
      return;
    }
    final events = FlutterCompass.events;
    if (events == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr(context, 'record.no_compass'))));
      return;
    }
    setState(() => _turn = true);
    _compass = events.listen((e) {
      final h = e.heading;
      if (h == null || !mounted) return;
      final now = DateTime.now();
      // About 10 turns a second at most, and only for a visible change.
      if (_heading != null && (((h - _heading! + 540) % 360) - 180).abs() < 2) return;
      if (now.difference(_turnedAt).inMilliseconds < 100) return;
      _turnedAt = now;
      _heading = (h + 360) % 360;
      _map.rotate(-_heading!);
    }, onError: (_) {});
  }

  void _north() {
    if (_turn) _toggleTurn();
    _map.rotate(0);
  }

  @override
  Widget build(BuildContext context) {
    final me = _me;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: RS.z9,
        foregroundColor: Colors.white,
        title: Text(
          widget.route.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: RS.head(24, color: Colors.white),
        ),
      ),
      body: Stack(
        children: [
          TrailMap(
            route: widget.route,
            interactive: true,
            rotate: true,
            controller: _map,
            extra: [
              if (me != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: me,
                      width: 24,
                      height: 24,
                      child: Semantics(
                        label: tr(context, 'record.you'),
                        child: Container(
                          decoration: BoxDecoration(
                            color: const Color(0xFF1D4ED8),
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 3),
                            boxShadow: const [BoxShadow(color: Color(0x55000000), blurRadius: 4)],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              // Keeps the north arrow in step with two-finger turns too.
              _RotationWatch(
                onRotation: (r) {
                  if (!_turn && (r - _rotation).abs() > 1) setState(() => _rotation = r); // while turning, the compass button is enough
                },
              ),
            ],
          ),
          Positioned(
            right: 12,
            top: 12,
            child: Column(
              children: [
                _MapButton(
                  tooltip: tr(context, _turn ? 'map.north' : 'map.turn'),
                  selected: _turn,
                  onPressed: _toggleTurn,
                  child: Icon(_turn ? Icons.explore : Icons.explore_outlined, color: _turn ? Colors.white : RS.z9),
                ),
                if (_rotation.abs() > 1 && !_turn) ...[
                  const SizedBox(height: 8),
                  _MapButton(
                    tooltip: tr(context, 'map.north'),
                    onPressed: _north,
                    child: Transform.rotate(
                      angle: _rotation * 3.141592653589793 / 180,
                      child: Text(tr(context, 'map.n'), style: RS.head(20, color: RS.err)),
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                ValueListenableBuilder<bool>(
                  valueListenable: topoMap,
                  builder: (context, topo, _) => _MapButton(
                    tooltip: tr(context, topo ? 'map.topo.off' : 'map.topo'),
                    selected: topo,
                    onPressed: () => topoMap.value = !topo,
                    child: Icon(Icons.terrain, color: topo ? Colors.white : RS.z9),
                  ),
                ),
                if (me != null) ...[
                  const SizedBox(height: 8),
                  _MapButton(
                    tooltip: tr(context, 'record.center'),
                    onPressed: () => _map.move(me, _map.camera.zoom < 15 ? 15 : _map.camera.zoom),
                    child: const Icon(Icons.my_location, color: RS.z9),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Reports the map's rotation from inside the map (no rebuild of the tiles).
class _RotationWatch extends StatelessWidget {
  const _RotationWatch({required this.onRotation});

  final void Function(double) onRotation;

  @override
  Widget build(BuildContext context) {
    final r = MapCamera.of(context).rotation;
    WidgetsBinding.instance.addPostFrameCallback((_) => onRotation(r));
    return const SizedBox.shrink();
  }
}

class _MapButton extends StatelessWidget {
  const _MapButton({required this.tooltip, required this.onPressed, required this.child, this.selected = false});

  final String tooltip;
  final VoidCallback onPressed;
  final Widget child;
  final bool selected;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Material(
      color: selected ? RS.z7 : Colors.white,
      elevation: 2,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onPressed,
        child: SizedBox(width: 48, height: 48, child: Center(child: child)),
      ),
    ),
  );
}

const _tiles = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

/// Small fixed map of one track for result cards: real OSM tiles like the website's
/// result maps. Not interactive (the card is the tap target); RepaintBoundary keeps
/// scrolling cheap on standard phones.
class MiniMap extends StatelessWidget {
  const MiniMap({super.key, required this.track, this.height = 150});

  final List<List<double>> track;
  final double height;

  @override
  Widget build(BuildContext context) {
    if (track.length < 2) return TrackThumb(track: track, height: height);
    final pts = track.map((p) => LatLng(p[0], p[1])).toList();
    return RepaintBoundary(
      child: SizedBox(
        height: height,
        child: Stack(
          children: [
            IgnorePointer(
              child: FlutterMap(
                options: MapOptions(
                  initialCameraFit: CameraFit.coordinates(coordinates: pts, padding: const EdgeInsets.all(22), maxZoom: 15),
                  interactionOptions: const InteractionOptions(flags: InteractiveFlag.none),
                  backgroundColor: RS.mist,
                ),
                children: [
                  TileLayer(urlTemplate: _tiles, userAgentPackageName: 'id.ai.rutestrip.app', maxZoom: 19, panBuffer: 0),
                  PolylineLayer(
                    polylines: [
                      Polyline(points: pts, strokeWidth: 5, color: Colors.white),
                      Polyline(points: pts, strokeWidth: 3, color: RS.z7),
                    ],
                  ),
                ],
              ),
            ),
            const Positioned(right: 4, bottom: 3, child: _OsmNote()),
          ],
        ),
      ),
    );
  }
}

class _OsmNote extends StatelessWidget {
  const _OsmNote();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
    decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.85), borderRadius: BorderRadius.circular(3)),
    child: const Text('© OpenStreetMap', style: TextStyle(fontSize: 10, color: RS.ink)),
  );
}

/// Every search result on one map with its rank at the trailhead; tapping a number opens the trail.
class ResultsMap extends StatelessWidget {
  const ResultsMap({super.key, required this.routes, required this.onOpen, this.interactive = false});

  final List<RouteSummary> routes;
  final void Function(RouteSummary) onOpen;
  final bool interactive;

  @override
  Widget build(BuildContext context) {
    final withTrack = [
      for (var i = 0; i < routes.length; i++)
        if (routes[i].track.length >= 2) (i + 1, routes[i]),
    ];
    final all = [for (final (_, r) in withTrack) ...r.track.map((p) => LatLng(p[0], p[1]))];
    if (all.length < 2) return const SizedBox.shrink();
    // The small overview must not take the page's scroll gestures; the full-screen one is interactive.
    return IgnorePointer(
      ignoring: !interactive,
      child: FlutterMap(
        options: MapOptions(
          initialCameraFit: CameraFit.coordinates(coordinates: all, padding: const EdgeInsets.all(36), maxZoom: 14),
          interactionOptions: InteractionOptions(flags: interactive ? InteractiveFlag.all & ~InteractiveFlag.rotate : InteractiveFlag.none),
          backgroundColor: RS.mist,
        ),
        children: [
          TileLayer(urlTemplate: _tiles, userAgentPackageName: 'id.ai.rutestrip.app', maxZoom: 19),
          PolylineLayer(
            polylines: [for (final (_, r) in withTrack) Polyline(points: r.track.map((p) => LatLng(p[0], p[1])).toList(), strokeWidth: 3.5, color: RS.z7)],
          ),
          MarkerLayer(
            markers: [
              for (final (rank, r) in withTrack.reversed)
                Marker(
                  point: LatLng(r.track.first[0], r.track.first[1]),
                  width: 34,
                  height: 34,
                  child: Semantics(
                    button: true,
                    label: '${tr(context, 'results.rank')} $rank, ${r.name}',
                    child: GestureDetector(
                      onTap: () => onOpen(r),
                      child: Container(
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          border: Border.all(color: RS.z9, width: 2),
                          borderRadius: BorderRadius.circular(7),
                        ),
                        child: Text('$rank', style: RS.head(18, color: RS.z9)),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const OsmAttribution(),
        ],
      ),
    );
  }
}

/// Topographic map (contour lines and hill shading from OpenTopoMap) instead of the
/// standard OpenStreetMap style, on the Rekam map and the trail maps.
final topoMap = ValueNotifier<bool>(false);

/// The map background: OpenStreetMap, or OpenTopoMap when [topoMap] is on.
class BaseTiles extends StatelessWidget {
  const BaseTiles({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: topoMap,
    builder: (context, topo, _) => TileLayer(
      key: ValueKey(topo),
      urlTemplate: topo ? 'https://tile.opentopomap.org/{z}/{x}/{y}.png' : 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
      userAgentPackageName: 'id.ai.rutestrip.app',
      maxZoom: 19,
      // OpenTopoMap draws up to zoom 17; closer than that the tiles are enlarged.
      maxNativeZoom: topo ? 17 : 19,
    ),
  );
}

/// Map credits in the corner, always visible (tile usage policies); tapping opens the
/// copyright page.
class OsmAttribution extends StatelessWidget {
  const OsmAttribution({super.key});

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.bottomRight,
    child: ValueListenableBuilder<bool>(
      valueListenable: topoMap,
      builder: (context, topo, _) => Semantics(
        link: true,
        child: GestureDetector(
          onTap: () => openExternal(topo ? 'https://opentopomap.org/about' : 'https://www.openstreetmap.org/copyright'),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            color: Colors.white.withValues(alpha: 0.88),
            child: Text(
              topo ? '© OpenStreetMap contributors, SRTM · © OpenTopoMap (CC-BY-SA)' : '© OpenStreetMap contributors',
              style: const TextStyle(fontSize: 11.5, color: RS.ink),
            ),
          ),
        ),
      ),
    ),
  );
}
