import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'api.dart';
import 'app_state.dart';
import 'screens/login_screen.dart';
import 'screens/onboarding_screen.dart';
import 'screens/shell.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final state = AppState(Api());
  runApp(RuteStripApp(state: state));
  await state.load();
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
                child!,
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
