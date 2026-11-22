import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../i18n.dart';
import '../theme.dart';

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
        SimpleAttributionWidget(
          source: const Text('OpenStreetMap contributors'),
          onTap: () => launchUrl(Uri.parse('https://www.openstreetmap.org/copyright'), mode: LaunchMode.externalApplication),
        ),
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
