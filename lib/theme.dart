import 'package:material_ui/material_ui.dart';

/// Colors from DESIGN.md / the website's tokens (layouts/app.blade.php).
class RS {
  static const z9 = Color(0xFF053B30); // dark emerald: header bands
  static const z8 = Color(0xFF0B4A3C);
  static const z7 = Color(0xFF047857); // emerald: links, secondary buttons, track line
  static const paper = Color(0xFFF6F4EC); // map paper: page background
  static const line = Color(0xFFDCD8C9); // 1px card borders
  static const edge = Color(0xFF7C8C84); // form field borders (3.5:1 on white)
  static const sun = Color(0xFFFCD34D); // dawn yellow: only the single main action
  static const ink = Color(0xFF14231D);
  static const muted = Color(0xFF4B5D55);
  static const mist = Color(0xFFE7EFE9); // track thumbnail background
  static const onDarkSoft = Color(0xFFA7F3D0); // secondary text on z9 (10.9:1)
  static const err = Color(0xFFB91C1C);
  static const warnBg = Color(0xFFFFFBEB);
  static const warnLine = Color(0xFFD97706);
  static const warnInk = Color(0xFF451A03);

  static const display = 'BarlowCondensed';
  static const body = 'Inter';

  /// Barlow Condensed headings: signpost voice of the site.
  static TextStyle head(double size, {Color color = ink, FontWeight weight = FontWeight.w800}) =>
      TextStyle(fontFamily: display, fontSize: size, fontWeight: weight, height: 0.98, color: color, letterSpacing: 0.2);
}

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: RS.z7,
    primary: RS.z7,
    onPrimary: Colors.white,
    secondary: RS.z9,
    surface: Colors.white,
    onSurface: RS.ink,
    error: RS.err,
  );
  const radius = BorderRadius.all(Radius.circular(10));
  final base = ThemeData(useMaterial3: true, colorScheme: scheme, fontFamily: RS.body);

  return base.copyWith(
    scaffoldBackgroundColor: RS.paper,
    textTheme: base.textTheme.apply(bodyColor: RS.ink, displayColor: RS.ink),
    materialTapTargetSize: MaterialTapTargetSize.padded,
    visualDensity: VisualDensity.standard,
    inputDecorationTheme: const InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
        borderSide: BorderSide(color: RS.edge),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
        borderSide: BorderSide(color: RS.edge),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
        borderSide: BorderSide(color: RS.z7, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
        borderSide: BorderSide(color: RS.err),
      ),
      labelStyle: TextStyle(color: RS.muted),
      floatingLabelStyle: TextStyle(color: RS.z7, fontWeight: FontWeight.w600),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: RS.z7,
        foregroundColor: Colors.white,
        minimumSize: const Size(48, 48),
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(8))),
        textStyle: const TextStyle(fontFamily: RS.body, fontWeight: FontWeight.w700, fontSize: 16),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: RS.z9,
        minimumSize: const Size(48, 48),
        side: const BorderSide(color: RS.edge),
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(8))),
        textStyle: const TextStyle(fontFamily: RS.body, fontWeight: FontWeight.w600, fontSize: 15),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: RS.z7,
        minimumSize: const Size(48, 48),
        textStyle: const TextStyle(fontFamily: RS.body, fontWeight: FontWeight.w700, fontSize: 15, decoration: TextDecoration.underline),
      ),
    ),
    cardTheme: const CardThemeData(
      color: Colors.white,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: RS.line),
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(backgroundColor: RS.paper, showDragHandle: true),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating, backgroundColor: RS.z9),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: RS.z7),
  );
}

/// The one yellow action per screen: dawn yellow with a dark frame, like a trail sign.
class SignButton extends StatelessWidget {
  const SignButton({super.key, required this.label, required this.onPressed, this.busy = false, this.busyLabel});

  final String label;
  final String? busyLabel;
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: busy ? null : onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: RS.sun,
        foregroundColor: RS.z9,
        disabledBackgroundColor: RS.sun.withValues(alpha: 0.75),
        disabledForegroundColor: RS.z9,
        minimumSize: const Size(48, 52),
        padding: const EdgeInsets.symmetric(horizontal: 22),
        side: const BorderSide(color: RS.z9, width: 2),
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(8))),
        textStyle: const TextStyle(fontFamily: RS.body, fontWeight: FontWeight.w800, fontSize: 16),
      ),
      child: Text(busy ? (busyLabel ?? label) : label),
    );
  }
}
