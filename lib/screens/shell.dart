import 'package:material_ui/material_ui.dart';

import '../i18n.dart';
import '../theme.dart';
import 'account_screen.dart';
import 'chat_screen.dart';
import 'home_screen.dart';
import 'record_screen.dart';
import 'routes_screen.dart';

/// Signed-in app: five tabs at the bottom. Tabs keep their state (IndexedStack);
/// screens opened from a tab (route page, upload, map) cover the bar.
class Shell extends StatefulWidget {
  const Shell({super.key});

  static final globalKey = GlobalKey<ShellState>();

  @override
  State<Shell> createState() => ShellState();
}

class ShellState extends State<Shell> {
  int _index = 0;

  /// Jump to a tab from anywhere (for example "Rekam" from a route page).
  void open(int index) => setState(() => _index = index);

  @override
  Widget build(BuildContext context) {
    final tabs = [
      (Icons.search, Icons.search, 'tab.search'),
      (Icons.terrain_outlined, Icons.terrain, 'tab.routes'),
      (Icons.radio_button_checked, Icons.radio_button_checked, 'tab.record'),
      (Icons.chat_bubble_outline, Icons.chat_bubble, 'tab.chat'),
      (Icons.person_outline, Icons.person, 'tab.me'),
    ];
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          const HomeScreen(),
          const RoutesScreen(),
          RecordScreen(active: _index == 2),
          ChatScreen(active: _index == 3),
          AccountScreen(active: _index == 4),
        ],
      ),
      bottomNavigationBar: NavigationBarTheme(
        data: NavigationBarThemeData(
          backgroundColor: Colors.white,
          indicatorColor: const Color(0xFFD1FAE5),
          height: 68,
          labelTextStyle: WidgetStateProperty.resolveWith(
            (s) => TextStyle(fontSize: 12.5, fontWeight: s.contains(WidgetState.selected) ? FontWeight.w700 : FontWeight.w500, color: RS.ink),
          ),
          iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(color: s.contains(WidgetState.selected) ? RS.z9 : RS.muted)),
        ),
        child: DecoratedBox(
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: RS.line)),
          ),
          child: NavigationBar(
            selectedIndex: _index,
            onDestinationSelected: open,
            destinations: [
              for (final (icon, selected, key) in tabs) NavigationDestination(icon: Icon(icon), selectedIcon: Icon(selected), label: tr(context, key)),
            ],
          ),
        ),
      ),
    );
  }
}
