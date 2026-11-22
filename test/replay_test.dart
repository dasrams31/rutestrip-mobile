import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rutestrip/screens/replay_screen.dart';
import 'package:rutestrip/storage.dart';

Recording _rec(int n, {bool withEle = true, bool withTime = true, List<Waypoint> waypoints = const [], double gainM = 0, double distanceKm = 0}) {
  final t0 = withTime ? DateTime.utc(2026, 11, 1, 1) : DateTime.utc(2000);
  return Recording(
    id: 'r',
    name: 'Uji "replay" </script>',
    startedAt: t0,
    points: [
      for (var i = 0; i < n; i++)
        TrackPoint(-7.45 + i * 0.0001, 110.43, withEle ? 1500.0 + i * 0.5 : null, t0.add(Duration(seconds: withTime ? i * 10 : i + 1))),
    ],
    distanceKm: distanceKm,
    gainM: gainM,
    movingSeconds: 0,
    waypoints: waypoints,
  );
}

Map<String, Object?> _payload(Recording r) => replayPayload(r, lang: 'id', labels: const {'time': 'Waktu'}, waypointName: (k) => 'W $k');

void main() {
  test('long tracks are cut to at most 1500 points, keeping both ends', () {
    final r = _rec(10007);
    final pts = _payload(r)['pts'] as List;
    expect(pts.length, lessThanOrEqualTo(1500));
    expect(pts.length, greaterThan(1000));
    expect((pts.first as List)[1], closeTo(-7.45, 1e-6));
    expect((pts.last as List)[1], closeTo(r.points.last.lat, 1e-6));
    // Distance along the track only grows.
    final d = pts.map((p) => (p as List)[4] as double).toList();
    for (var i = 1; i < d.length; i++) {
      expect(d[i], greaterThanOrEqualTo(d[i - 1]));
    }
  });

  test('short tracks are sent whole, totals match the recording', () {
    final pts = _payload(_rec(50, distanceKm: 1, gainM: 20))['pts'] as List;
    expect(pts.length, 50);
    expect((pts.last as List)[4], closeTo(1000, 0.2));
    expect((pts.last as List)[5], closeTo(20, 0.2));
    expect((pts.last as List)[3], 490);
  });

  test('no elevation still plays with zero climb', () {
    final p = _payload(_rec(20, withEle: false));
    final pts = p['pts'] as List;
    expect(pts.every((e) => (e as List)[2] == null && e[5] == 0), isTrue);
  });

  test('imported files without timestamps hide the time', () {
    final p = _payload(_rec(20, withTime: false));
    expect(p['hasTime'], isFalse);
    expect((p['pts'] as List).every((e) => (e as List)[3] == null), isTrue);
  });

  test('waypoints get a name, a place along the track and a clock time', () {
    final r = _rec(
      100,
      waypoints: [
        Waypoint(lat: -7.445, lng: 110.4301, ele: null, time: DateTime.utc(2026, 11, 1, 2), kind: 'summit'),
        Waypoint(lat: -7.449, lng: 110.43, ele: 1490, time: DateTime.utc(2000, 1, 1, 0, 0, 3), kind: 'pos'),
      ],
    );
    final w = _payload(r)['wpts'] as List;
    expect(w.length, 2);
    expect((w.first as Map)['name'], 'W pos');
    expect((w.first as Map)['clock'], isNull);
    expect((w.last as Map)['name'], 'W summit');
    expect((w.last as Map)['clock'], isNotNull);
    expect((w.last as Map)['ele'], 1525);
    expect((w.last as Map)['d'] as double, greaterThan((w.first as Map)['d'] as double));
  });

  test('waypoint names with quotes stay data after double JSON encoding', () {
    final r = _rec(
      5,
      waypoints: [Waypoint(lat: -7.45, lng: 110.43, ele: null, time: DateTime.utc(2026), kind: 'other')],
    );
    final p = replayPayload(r, lang: 'en', labels: const {}, waypointName: (_) => 'a"); alert(1); ("</script>');
    final text = jsonEncode(jsonEncode(p));
    final back = jsonDecode(jsonDecode(text) as String) as Map;
    expect(((back['wpts'] as List).first as Map)['name'], 'a"); alert(1); ("</script>');
  });
}
