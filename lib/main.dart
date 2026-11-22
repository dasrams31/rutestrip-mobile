import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart' show LatLng;
import 'package:material_ui/material_ui.dart';

import 'api.dart';
import 'app_state.dart';
import 'location_hub.dart';
import 'notify.dart';
import 'screens/chat_screen.dart';
import 'screens/login_screen.dart';
import 'screens/onboarding_screen.dart';
import 'mesh/mesh_service.dart';
import 'screens/group_pane.dart';
import 'screens/record_screen.dart';
import 'screens/shell.dart';
import 'theme.dart';

/// Root navigator: lets a sign-out close pages opened above the tabs.
final rootNavigator = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Api.checkBaseUrl();
  final state = AppState(Api())
    ..onSignedOut = () {
      rootNavigator.currentState?.popUntil((r) => r.isFirst);
      mesh.leave(); // the next account on this phone must not read this group's chat
    };
  runApp(RuteStripApp(state: state));
  await state.load();
  _syncLang(state);
  state.addListener(() => _syncLang(state));
  Notify.instance
    ..onTap = (payload) {
      rootNavigator.currentState?.popUntil((r) => r.isFirst);
      chatPane.value = 2; // the group pane
      Shell.globalKey.currentState?.open(Tabs.chat);
    }
    ..init();
}

/// Notification texts follow the app language.
void _syncLang(AppState state) {
  Notify.instance.lang = state.lang;
  final hub = LocationHub.instance;
  if (hub.lang != state.lang) {
    hub.lang = state.lang;
    hub.refresh();
  }
}

class RuteStripApp extends StatelessWidget {
  const RuteStripApp({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: state,
      child: ListenableBuilder(
        listenable: state,
        builder: (context, _) => MaterialApp(
          navigatorKey: rootNavigator,
          title: 'RuteStrip',
          debugShowCheckedModeBanner: false,
          theme: buildTheme(),
          locale: Locale(state.lang),
          supportedLocales: const [Locale('id'), Locale('en')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
            // Header bands are dark emerald: light status bar icons.
            value: SystemUiOverlayStyle.light.copyWith(statusBarColor: Colors.transparent),
            // A fixed dark strip under the status bar: scrolled content never sits behind the light icons.
            child: Stack(
              children: [
                state.signedIn ? _WithSosBanner(child: child!) : child!,
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: MediaQuery.paddingOf(context).top,
                  child: const ColoredBox(color: RS.z9),
                ),
              ],
            ),
          ),
          // Every feature needs an account (owner's choice): signed out = the login screen.
          home: !state.ready
              ? const _Splash()
              : !state.onboarded
              ? const OnboardingScreen()
              : state.signedIn
              ? Shell(key: Shell.globalKey)
              : const LoginScreen(gate: true),
        ),
      ),
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: RS.z9,
      body: Center(
        child: Text('RuteStrip', style: RS.head(48, color: Colors.white)),
      ),
    );
  }
}

/// A teammate's SOS sits above every screen; the screen below loses its top inset meanwhile.
class _WithSosBanner extends StatelessWidget {
  const _WithSosBanner({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: mesh,
      builder: (context, _) {
        if (mesh.sos.isEmpty) return child;
        return Column(
          children: [
            SosBanner(
              onShow: (m) {
                rootNavigator.currentState?.popUntil((r) => r.isFirst);
                mapFocus.value = LatLng(m.lat!, m.lng!);
                Shell.globalKey.currentState?.open(Tabs.record);
              },
            ),
            Expanded(
              child: MediaQuery.removePadding(context: context, removeTop: true, child: child),
            ),
          ],
        );
      },
    );
  }
}
