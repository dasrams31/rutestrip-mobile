import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:rutestrip/api.dart';
import 'package:rutestrip/app_state.dart';
import 'package:rutestrip/mesh/mesh_protocol.dart';
import 'package:rutestrip/mesh/mesh_service.dart';
import 'package:rutestrip/screens/chat_screen.dart';
import 'package:rutestrip/screens/group_pane.dart';
import 'package:rutestrip/screens/onboarding_screen.dart';
import 'package:rutestrip/screens/settings_screen.dart';
import 'package:rutestrip/screens/shell.dart';
import 'package:rutestrip/screens/upload_screen.dart';
import 'package:rutestrip/storage.dart';
import 'package:rutestrip/theme.dart';

/// The signed-in tabs and the upload screen lay out on a 320 x 640 dp phone in both
/// languages. Network calls fail in tests, so data views show their error states.
void main() {
  setUpAll(() async {
    for (final (family, files) in [
      ('BarlowCondensed', ['BarlowCondensed-700', 'BarlowCondensed-800']),
      ('Inter', ['Inter-400', 'Inter-500', 'Inter-600', 'Inter-700']),
    ]) {
      final loader = FontLoader(family);
      for (final f in files) {
        loader.addFont(Future.value(ByteData.sublistView(File('assets/fonts/$f.ttf').readAsBytesSync())));
      }
      await loader.load();
    }
  });

  Future<void> pump(WidgetTester tester, Widget screen, String lang) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState(Api())
      ..lang = lang
      ..user = AppUser.fromJson({'id': 1, 'name': 'Pendaki Uji', 'email': 'uji@example.com'});
    await tester.pumpWidget(
      AppScope(
        state: state,
        child: MaterialApp(theme: buildTheme(), home: screen),
      ),
    );
    await tester.pump();
  }

  for (final lang in ['id', 'en']) {
    testWidgets('shell with bottom tabs ($lang)', (tester) async {
      await pump(tester, Shell(key: GlobalKey()), lang);
      final labels = lang == 'en' ? ['Trails', 'Chat', 'Record', 'Me'] : ['Jalur', 'Chat', 'Rekam', 'Saya'];
      for (final label in labels) {
        await tester.tap(find.text(label).last);
        await tester.pump();
        expect(tester.takeException(), isNull, reason: label);
      }
    });

    testWidgets('onboarding slides ($lang)', (tester) async {
      await pump(tester, const OnboardingScreen(), lang);
      for (var i = 0; i < 4; i++) {
        await tester.tap(find.text(lang == 'en' ? 'Next' : 'Lanjut'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'slide ${i + 2}');
      }
      expect(find.text(lang == 'en' ? 'Start' : 'Mulai'), findsOneWidget);
    });

    testWidgets('settings, history and about ($lang)', (tester) async {
      for (final screen in [const SettingsScreen(), const AboutScreen(), const BatchUploadScreen()]) {
        await pump(tester, screen, lang);
        expect(tester.takeException(), isNull, reason: '$screen');
      }
    });

    testWidgets('assistant pane ($lang)', (tester) async {
      await pump(tester, const ChatScreen(active: false), lang);
      await tester.tap(find.text(lang == 'en' ? 'Assistant' : 'Asisten'));
      await tester.pump();
      expect(find.byType(TextField), findsOneWidget); // the hidden community pane is offstage
      expect(tester.takeException(), isNull);
    });

    testWidgets('group pane intro ($lang)', (tester) async {
      mesh.loaded = true;
      await pump(tester, const Scaffold(body: GroupPane()), lang);
      expect(find.byType(OutlinedButton), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a teammate SOS shows the red banner with a way to the map ($lang)', (tester) async {
      final m = MeshMember('n1', 'Budi')
        ..lat = -7.45
        ..lng = 110.43;
      mesh.members['n1'] = m;
      mesh.sos['n1'] = MeshMessage(
        id: 's1',
        from: 'n1',
        name: 'Budi',
        time: DateTime.now(),
        type: MeshType.sos,
        body: {'active': true, 'lat': -7.45, 'lng': 110.43},
      );
      MeshMember? shown;
      await pump(tester, Scaffold(body: SosBanner(onShow: (x) => shown = x)), lang);
      expect(find.textContaining('Budi'), findsOneWidget);
      await tester.tap(find.text(lang == 'en' ? 'Show on map' : 'Lihat di peta'));
      expect(shown?.id, 'n1');
      mesh.dismissSos('n1');
      await tester.pump();
      expect(find.textContaining('Budi'), findsNothing);
      mesh.members.clear();
    });

    testWidgets('upload form ($lang)', (tester) async {
      await pump(tester, const UploadScreen(), lang);
      expect(tester.takeException(), isNull);
    });
  }

  test('a recording becomes a GPX track with elevation and time', () {
    final r = Recording(
      id: '1',
      name: 'Uji & coba',
      startedAt: DateTime.utc(2026, 11, 22, 1),
      points: [TrackPoint(-7.45, 110.43, 1811, DateTime.utc(2026, 11, 22, 1)), TrackPoint(-7.44, 110.435, null, DateTime.utc(2026, 11, 22, 1, 5))],
      distanceKm: 1.2,
      gainM: 40,
      movingSeconds: 300,
    );
    final gpx = r.toGpx();
    expect(gpx, contains('<name>Uji &amp; coba</name>'));
    expect(gpx, contains('<trkpt lat="-7.4500000" lon="110.4300000"><ele>1811.0</ele><time>2026-11-22T01:00:00.000Z</time></trkpt>'));
    expect(gpx, contains('<trkpt lat="-7.4400000" lon="110.4350000"><time>'));
    expect(Recording.fromJson(r.toJson()).points.length, 2);
  });
}
