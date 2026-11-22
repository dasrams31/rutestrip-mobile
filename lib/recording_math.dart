import 'dart:math' as math;

/// Where a hiker is relative to a planned trail (list of [lat, lng]).
class RouteProgress {
  const RouteProgress({required this.offRouteM, required this.doneM, required this.totalM, required this.nearestLat, required this.nearestLng});

  /// Distance from the hiker to the closest point of the trail line.
  final double offRouteM;

  /// Trail distance from the start to that closest point, and the whole trail length.
  final double doneM, totalM;

  final double nearestLat, nearestLng;

  double get leftM => math.max(0, totalM - doneM);
  double get fraction => totalM <= 0 ? 0 : (doneM / totalM).clamp(0, 1).toDouble();
}

const _earthM = 6371000.0;

double distanceM(double lat1, double lng1, double lat2, double lng2) {
  final p1 = lat1 * math.pi / 180, p2 = lat2 * math.pi / 180;
  final dp = p2 - p1, dl = (lng2 - lng1) * math.pi / 180;
  final h = math.sin(dp / 2) * math.sin(dp / 2) + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) * math.sin(dl / 2);
  return 2 * _earthM * math.asin(math.min(1, math.sqrt(h)));
}

/// Initial bearing from point 1 to point 2, 0-360 degrees (0 = north).
double bearingDeg(double lat1, double lng1, double lat2, double lng2) {
  final p1 = lat1 * math.pi / 180, p2 = lat2 * math.pi / 180, dl = (lng2 - lng1) * math.pi / 180;
  final y = math.sin(dl) * math.cos(p2);
  final x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl);
  return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
}

/// Eight compass points, index 0 = north, clockwise (same order as the website's weather wind).
int compassIndex(double degrees) => ((((degrees % 360) + 360) % 360 + 22.5) ~/ 45) % 8;

/// Closest point on the trail to (lat, lng), measured in a local flat projection
/// (fine for one mountain), with the distance along the trail up to it.
RouteProgress? routeProgress(List<List<double>> route, double lat, double lng) {
  if (route.length < 2) return null;
  final k = math.cos(lat * math.pi / 180);
  const m = 111320.0;
  double x(double lo) => (lo - lng) * m * k;
  double y(double la) => (la - lat) * m;

  var best = double.infinity, bestDone = 0.0, bestLat = route.first[0], bestLng = route.first[1];
  var done = 0.0;
  for (var i = 0; i < route.length - 1; i++) {
    final ax = x(route[i][1]), ay = y(route[i][0]), bx = x(route[i + 1][1]), by = y(route[i + 1][0]);
    final dx = bx - ax, dy = by - ay;
    final len2 = dx * dx + dy * dy;
    final t = len2 == 0 ? 0.0 : ((-ax * dx - ay * dy) / len2).clamp(0.0, 1.0);
    final px = ax + t * dx, py = ay + t * dy;
    final d = math.sqrt(px * px + py * py);
    final seg = math.sqrt(len2);
    if (d < best) {
      best = d;
      bestDone = done + t * seg;
      bestLat = route[i][0] + t * (route[i + 1][0] - route[i][0]);
      bestLng = route[i][1] + t * (route[i + 1][1] - route[i][1]);
    }
    done += seg;
  }
  return RouteProgress(offRouteM: best, doneM: bestDone, totalM: done, nearestLat: bestLat, nearestLng: bestLng);
}

/// Elevation profile [[km, m], ...] of recorded points, at most [max] entries.
List<List<double>> recordingProfile(List<({double lat, double lng, double? ele})> points, {int max = 150}) {
  final out = <List<double>>[];
  if (points.length < 2) return out;
  final step = math.max(1, (points.length / max).ceil());
  var km = 0.0;
  for (var i = 0; i < points.length; i++) {
    if (i > 0) km += distanceM(points[i - 1].lat, points[i - 1].lng, points[i].lat, points[i].lng) / 1000;
    final e = points[i].ele;
    if (e != null && (i % step == 0 || i == points.length - 1)) out.add([km, e]);
  }
  return out.length >= 2 ? out : const [];
}
