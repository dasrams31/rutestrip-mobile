import 'recording_math.dart';
import 'storage.dart';

/// Reads a GPX file on the phone (no network): track or route points, waypoints and
/// the name. Attributes may come in any order; files from Garmin, Strava, OsmAnd and
/// the RuteStrip website all use this shape.
class GpxImport {
  GpxImport({required this.name, required this.points, required this.waypoints});

  final String? name;
  final List<TrackPoint> points;
  final List<Waypoint> waypoints;

  static final _pt = RegExp(r'<(trkpt|rtept|wpt)\b([^>]*?)(/>|>([\s\S]*?)</\1>)', caseSensitive: false);
  static final _lat = RegExp(r'''\blat\s*=\s*["']([-+0-9.eE]+)["']''');
  static final _lon = RegExp(r'''\blon\s*=\s*["']([-+0-9.eE]+)["']''');
  static final _ele = RegExp(r'<ele>\s*([-+0-9.eE]+)\s*</ele>', caseSensitive: false);
  static final _time = RegExp(r'<time>\s*([^<]+?)\s*</time>', caseSensitive: false);
  static final _name = RegExp(r'<name>\s*(?:<!\[CDATA\[)?([\s\S]*?)(?:\]\]>)?\s*</name>', caseSensitive: false);

  /// Throws [FormatException] when the text is not a GPX file with at least two points.
  static GpxImport parse(String xml) {
    if (!RegExp(r'<gpx\b', caseSensitive: false).hasMatch(xml)) throw const FormatException('not gpx');
    final track = <TrackPoint>[], route = <TrackPoint>[], wpts = <Waypoint>[];
    var fallbackTime = DateTime.utc(2000);
    for (final m in _pt.allMatches(xml)) {
      final attrs = m.group(2) ?? '', body = m.group(4) ?? '';
      final lat = double.tryParse(_lat.firstMatch(attrs)?.group(1) ?? '');
      final lng = double.tryParse(_lon.firstMatch(attrs)?.group(1) ?? '');
      if (lat == null || lng == null || lat.abs() > 90 || lng.abs() > 180) continue;
      final ele = double.tryParse(_ele.firstMatch(body)?.group(1) ?? '');
      final time = DateTime.tryParse(_time.firstMatch(body)?.group(1) ?? '')?.toUtc() ?? (fallbackTime = fallbackTime.add(const Duration(seconds: 1)));
      switch (m.group(1)!.toLowerCase()) {
        case 'trkpt':
          track.add(TrackPoint(lat, lng, ele, time));
        case 'rtept':
          route.add(TrackPoint(lat, lng, ele, time));
        default:
          wpts.add(Waypoint(lat: lat, lng: lng, ele: ele, time: time, kind: 'other'));
      }
    }
    final points = track.length >= 2 ? track : route;
    if (points.length < 2) throw const FormatException('too few points');

    // The first <name> outside a point is the file or track name.
    final stripped = xml.replaceAll(_pt, '');
    final name = _name.firstMatch(stripped)?.group(1)?.trim();
    return GpxImport(name: name == null || name.isEmpty ? null : _unescape(name), points: points, waypoints: wpts);
  }

  static String _unescape(String s) =>
      s.replaceAll('&lt;', '<').replaceAll('&gt;', '>').replaceAll('&quot;', '"').replaceAll('&apos;', "'").replaceAll('&amp;', '&');

  /// Kept like a recording (distance and climb measured here), marked as imported.
  Recording toRecording(String fallbackName) {
    var dist = 0.0, gain = 0.0;
    double? ref;
    for (var i = 0; i < points.length; i++) {
      final p = points[i];
      if (i > 0) dist += distanceM(points[i - 1].lat, points[i - 1].lng, p.lat, p.lng);
      final e = p.ele;
      if (e == null) continue;
      if (ref == null) {
        ref = e;
      } else if (e - ref >= 3) {
        gain += e - ref;
        ref = e;
      } else if (ref - e >= 3) {
        ref = e;
      }
    }
    final now = DateTime.now();
    return Recording(
      id: 'gpx${now.millisecondsSinceEpoch}',
      name: name ?? fallbackName,
      startedAt: now,
      points: points,
      distanceKm: dist / 1000,
      gainM: gain,
      movingSeconds: 0,
      waypoints: waypoints,
      imported: true,
    );
  }
}
