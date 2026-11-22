import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:material_ui/material_ui.dart';

import '../api.dart';
import '../i18n.dart';
import '../theme.dart';
import 'common.dart';

/// OpenStreetMap tiles with the GPX track, basecamp (circle) and summit (triangle).
/// Attribution follows the OSM tile usage policy.
class TrailMap extends StatelessWidget {
  const TrailMap({super.key, required this.route, this.interactive = false});

  final RouteDetail route;
  final bool interactive;

  @override
  Widget build(BuildContext context) {
    final points = route.coordinates.map((p) => LatLng(p[0], p[1])).toList();
    final b = route.basecampPoint, s = route.summitPoint;
    return FlutterMap(
      options: MapOptions(
        initialCameraFit: CameraFit.coordinates(coordinates: points, padding: const EdgeInsets.fromLTRB(32, 32, 32, 56)),
        interactionOptions: InteractionOptions(flags: interactive ? InteractiveFlag.all & ~InteractiveFlag.rotate : InteractiveFlag.none),
      ),
      children: [
        TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'id.ai.rutestrip.app', maxZoom: 19),
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

class MapScreen extends StatelessWidget {
  const MapScreen({super.key, required this.route});

  final RouteDetail route;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: RS.z9,
        foregroundColor: Colors.white,
        title: Text(
          route.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: RS.head(24, color: Colors.white),
        ),
      ),
      body: TrailMap(route: route, interactive: true),
    );
  }
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

/// "© OpenStreetMap contributors" in the map corner, always visible (OSM tile usage
/// policy); tapping it opens the copyright page.
class OsmAttribution extends StatelessWidget {
  const OsmAttribution({super.key});

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.bottomRight,
    child: Semantics(
      link: true,
      child: GestureDetector(
        onTap: () => openExternal('https://www.openstreetmap.org/copyright'),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          color: Colors.white.withValues(alpha: 0.88),
          child: const Text('© OpenStreetMap contributors', style: TextStyle(fontSize: 11.5, color: RS.ink)),
        ),
      ),
    ),
  );
}
