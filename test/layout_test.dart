import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:rutestrip/api.dart';
import 'package:rutestrip/app_state.dart';
import 'package:rutestrip/screens/home_screen.dart';
import 'package:rutestrip/screens/login_screen.dart';
import 'package:rutestrip/theme.dart';
import 'package:rutestrip/widgets/common.dart';

/// Screens must lay out on a small phone (320 x 640 dp) without overflow, in both languages.
void main() {
  // Real fonts, not the test font (every glyph a full square), so widths match the device.
  setUpAll(() async {
    for (final (family, files) in [
      ('BarlowCondensed', ['BarlowCondensed-700', 'BarlowCondensed-800']),
      ('Inter', ['Inter-400', 'Inter-500', 'Inter-600', 'Inter-700']),
    ]) {
      final loader = FontLoader(family);
      for (final f in files) {
        final bytes = File('assets/fonts/$f.ttf').readAsBytesSync();
        loader.addFont(Future.value(ByteData.sublistView(bytes)));
      }
      await loader.load();
    }
  });

  Future<void> pump(WidgetTester tester, Widget screen, {String lang = 'id'}) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState(Api())..lang = lang;
    await tester.pumpWidget(
      AppScope(
        state: state,
        child: MaterialApp(theme: buildTheme(), home: screen),
      ),
    );
    await tester.pump();
  }

  for (final lang in ['id', 'en']) {
    testWidgets('home lays out on a 320 dp phone ($lang)', (tester) async {
      await pump(tester, const HomeScreen(), lang: lang);
      expect(find.byType(SignButton), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('login and register lay out on a 320 dp phone ($lang)', (tester) async {
      await pump(tester, const LoginScreen(), lang: lang);
      expect(tester.takeException(), isNull);
      await pump(tester, LoginScreen(key: UniqueKey(), register: true), lang: lang);
      expect(find.byType(TextFormField), findsNWidgets(4));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('route card lays out with long names', (tester) async {
    final route = RouteSummary.fromJson({
      'id': 1,
      'name': 'Puncak Junghuhn ke Puncak Besar Malabar via Kampung Cinyiruan Pangalengan',
      'mountain': 'Puncak Junghuhn ke Puncak Besar Malabar',
      'basecamp': 'Basecamp Kampung Cinyiruan Pangalengan',
      'province': 'Jawa Barat',
      'distance_km': 12.34,
      'elevation_gain_m': 1424,
      'naismith_duration_hour': 5.9,
      'duration_label': 'Waktu ke puncak',
      'average_grade_pct': 12.8,
      'difficulty_level': 'Sangat Sulit',
      'difficulty_label': 'Sangat Sulit',
      'match_label': 'Lumayan cocok',
      'similarity_score': 42.0,
      'why': 'Kemiringan rata-rata 12,8%, total naik 1.424 m.',
      'track': [
        [-7.45, 110.43],
        [-7.44, 110.435],
        [-7.43, 110.44],
      ],
    });
    await pump(
      tester,
      Scaffold(
        body: ListView(children: [RouteCard(route: route, rank: 10)]),
      ),
    );
    expect(find.text('10'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
