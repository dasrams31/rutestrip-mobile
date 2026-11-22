import 'package:flutter_test/flutter_test.dart';
import 'package:rutestrip/gpx_import.dart';

void main() {
  test('reads track points in any attribute order, heights, waypoints and the name', () {
    const gpx = '''<?xml version="1.0"?>
<gpx version="1.1" creator="Garmin">
  <metadata><name>Merbabu via Selo &amp; Wekas</name></metadata>
  <wpt lat="-7.4450" lon="110.4300"><name>Pos 1</name></wpt>
  <trk><name>ignored track name</name><trkseg>
    <trkpt lon="110.4300" lat="-7.4500"><ele>1800</ele><time>2026-11-22T01:00:00Z</time></trkpt>
    <trkpt lat='-7.4490' lon='110.4300'><ele>1810.5</ele></trkpt>
    <trkpt lat="-7.4480" lon="110.4300"/>
    <trkpt lat="999" lon="110.43"><ele>1</ele></trkpt>
  </trkseg></trk>
</gpx>''';
    final g = GpxImport.parse(gpx);
    expect(g.name, 'Merbabu via Selo & Wekas');
    expect(g.points.length, 3);
    expect(g.points.first.lng, 110.43);
    expect(g.points[1].ele, 1810.5);
    expect(g.points.last.ele, isNull);
    expect(g.waypoints.single.lat, -7.445);
    final r = g.toRecording('x');
    expect(r.imported, isTrue);
    expect(r.distanceKm, closeTo(0.222, 0.01));
    expect(r.gainM, closeTo(10.5, 0.01));
  });

  test('route points are used when there is no track', () {
    final g = GpxImport.parse('<gpx><rte><rtept lat="1" lon="2"/><rtept lat="1.001" lon="2"/></rte></gpx>');
    expect(g.points.length, 2);
    expect(g.name, isNull);
  });

  test('rejects files that are not GPX or have too few points', () {
    expect(() => GpxImport.parse('<html></html>'), throwsFormatException);
    expect(() => GpxImport.parse('<gpx><trk><trkseg><trkpt lat="1" lon="2"/></trkseg></trk></gpx>'), throwsFormatException);
  });
}
