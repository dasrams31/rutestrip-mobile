import 'package:flutter_test/flutter_test.dart';
import 'package:rutestrip/recording_math.dart';
import 'package:rutestrip/storage.dart';

void main() {
  // A straight trail about 1.1 km due north.
  final trail = [
    [-7.4500, 110.4300],
    [-7.4450, 110.4300],
    [-7.4400, 110.4300],
  ];

  test('distance and bearing', () {
    expect(distanceM(-7.45, 110.43, -7.44, 110.43), closeTo(1112, 3));
    expect(bearingDeg(-7.45, 110.43, -7.44, 110.43), closeTo(0, 0.5));
    expect(bearingDeg(-7.45, 110.43, -7.45, 110.44), closeTo(90, 0.5));
    expect(compassIndex(0), 0);
    expect(compassIndex(44), 1);
    expect(compassIndex(181), 4);
    expect(compassIndex(350), 0);
  });

  test('on the trail halfway', () {
    final p = routeProgress(trail, -7.4450, 110.4300)!;
    expect(p.offRouteM, closeTo(0, 1));
    expect(p.fraction, closeTo(0.5, 0.01));
    expect(p.leftM, closeTo(556, 5));
  });

  test('beside the trail', () {
    // About 110 m east of the middle point.
    final p = routeProgress(trail, -7.4450, 110.4310)!;
    expect(p.offRouteM, closeTo(110, 5));
    expect(p.nearestLng, closeTo(110.43, 1e-6));
  });

  test('profile from recorded points skips missing heights', () {
    final pts = [(lat: -7.45, lng: 110.43, ele: 1800.0), (lat: -7.449, lng: 110.43, ele: null), (lat: -7.448, lng: 110.43, ele: 1850.0)];
    final prof = recordingProfile(pts);
    expect(prof.length, 2);
    expect(prof.last[0], closeTo(0.222, 0.01));
    expect(prof.last[1], 1850);
  });

  test('marked spots go into the GPX as waypoints and survive a save', () {
    final t = DateTime.utc(2026, 11, 22, 2);
    final r = Recording(
      id: '9',
      name: 'Uji',
      startedAt: t,
      points: [TrackPoint(-7.45, 110.43, 1800, t), TrackPoint(-7.449, 110.43, 1810, t.add(const Duration(minutes: 2)))],
      distanceKm: 0.11,
      gainM: 10,
      movingSeconds: 120,
      waypoints: [Waypoint(lat: -7.4495, lng: 110.43, ele: 1805, time: t, kind: 'water')],
    );
    final gpx = r.toGpx();
    expect(gpx, contains('<wpt lat="-7.4495000" lon="110.4300000"><ele>1805.0</ele>'));
    expect(gpx, contains('<name>Sumber air</name><type>water</type></wpt>'));
    expect(gpx.indexOf('<wpt'), lessThan(gpx.indexOf('<trk>')));
    expect(Recording.fromJson(r.toJson()).waypoints.single.kind, 'water');
    expect(r.speedKmh, closeTo(3.3, 0.01));
  });

  test('a pause starts a new track segment in the GPX', () {
    final t = DateTime.utc(2026, 11, 22, 2);
    final pts = [for (var i = 0; i < 4; i++) TrackPoint(-7.45 + i * 0.001, 110.43, null, t.add(Duration(minutes: i)))];
    final r = Recording(id: '1', name: 'S', startedAt: t, points: pts, distanceKm: 0.2, gainM: 0, movingSeconds: 60, segmentStarts: [0, 2]);
    final gpx = r.toGpx();
    expect('<trkseg>'.allMatches(gpx).length, 2);
    expect(Recording.fromJson(r.toJson()).segmentStarts, [0, 2]);
  });

  test('climb between two points on a trail, and Naismith time to the next stop', () {
    // About 1.1 km north, climbing 100 m then dipping 2 m (noise) then 50 m more.
    final route = [
      [-7.4500, 110.43, 1800.0],
      [-7.4450, 110.43, 1900.0],
      [-7.4440, 110.43, 1898.0],
      [-7.4400, 110.43, 1950.0],
    ];
    final p = TrailProfile(route);
    expect(p.hasElevation, isTrue);
    expect(p.climbBetween(0, 2000), closeTo(150, 0.5));
    expect(p.climbBetween(600, 2000), closeTo(52, 0.5)); // starts after the first climb, from the dip
    expect(TrailProfile.summitOf(route), route.last);
    expect(
      TrailProfile.summitOf([
        [1.0, 2.0],
        [1.1, 2.0],
      ]),
      isNull,
    );
    expect(walkHours(5000, 600), closeTo(2, 1e-9)); // 1 h walking + 1 h for 600 m up
  });
}
