import 'package:material_ui/material_ui.dart';

import '../i18n.dart';
import '../app_state.dart';
import '../mesh/mesh_service.dart';
import '../outbox.dart';
import '../storage.dart';
import 'group_pane.dart';
import '../theme.dart';
import 'account_screen.dart';
import 'chat_screen.dart';
import 'feed_screen.dart';
import 'home_screen.dart';
import 'record_screen.dart';

/// Tab indexes, used when another screen opens a tab. The trail list is a page opened from Cari.
class Tabs {
  static const search = 0, feed = 1, chat = 2, record = 3, me = 4;
}

/// Signed-in app: the bottom bar of the website's PWA (five items, active one marked
/// with a 3 px emerald line on top, the middle item in an emerald box). Tabs keep their
/// state; screens opened from a tab (route page, upload, map) cover the bar.
class Shell extends StatefulWidget {
  const Shell({super.key});

  static final globalKey = GlobalKey<ShellState>();

  @override
  State<Shell> createState() => ShellState();
}

class ShellState extends State<Shell> {
  int _index = Tabs.search;
  final _built = <int>{Tabs.search};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      mesh.load(AppScope.read(context).user?.name ?? 'Pendaki');
      syncMeshName(context);
      // Posts written without signal go out from here on.
      final state = AppScope.read(context);
      if (state.user != null) Outbox.instance.start(state.api, state.user!.id);
    });
    // A recording that was cut off (app closed, phone restarted) opens Rekam so it can be resumed.
    RecordingStore.loadDraft().then((d) {
      if (d != null && mounted) open(Tabs.record);
    });
  }

  @override
  void dispose() {
    Outbox.instance.stop();
    super.dispose();
  }

  /// Jump to a tab from anywhere (for example "Rekam" from a route page).
  void open(int index) => setState(() {
    _index = index;
    _built.add(index);
  });

  @override
  Widget build(BuildContext context) {
    // Tabs are built the first time they are opened, so start-up stays light.
    Widget lazy(int i, Widget Function() make) => _built.contains(i) ? make() : const SizedBox.shrink();
    return PopScope(
      // Back on another tab goes to Cari first, like leaving a page on the website.
      canPop: _index == Tabs.search,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) open(Tabs.search);
      },
      child: Scaffold(
        body: IndexedStack(
          index: _index,
          children: [
            lazy(Tabs.search, () => const HomeScreen()),
            lazy(Tabs.feed, () => FeedScreen(active: _index == Tabs.feed)),
            lazy(Tabs.chat, () => ChatScreen(active: _index == Tabs.chat)),
            lazy(Tabs.record, () => RecordScreen(active: _index == Tabs.record)),
            lazy(Tabs.me, () => AccountScreen(active: _index == Tabs.me)),
          ],
        ),
        bottomNavigationBar: _TabBar(index: _index, onTap: open),
      ),
    );
  }
}

class _TabBar extends StatelessWidget {
  const _TabBar({required this.index, required this.onTap});

  final int index;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final items = [
      (Icons.search, 'tab.search', false),
      (Icons.dynamic_feed_outlined, 'tab.feed', false),
      (Icons.chat_bubble_outline, 'tab.chat', true),
      (Icons.radio_button_checked, 'tab.record', false),
      (Icons.person_outline, 'tab.me', false),
    ];
    return Material(
      color: Colors.white,
      child: Container(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: RS.line)),
        ),
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 64,
            child: Row(
              children: [
                for (final (i, (icon, label, highlight)) in items.indexed)
                  Expanded(
                    child: Semantics(
                      button: true,
                      selected: i == index,
                      label: tr(context, label),
                      excludeSemantics: true,
                      child: InkWell(
                        onTap: () => onTap(i),
                        child: Stack(
                          children: [
                            if (i == index)
                              Positioned(
                                top: 0,
                                left: 16,
                                right: 16,
                                child: Container(
                                  height: 3,
                                  decoration: const BoxDecoration(
                                    color: RS.z7,
                                    borderRadius: BorderRadius.vertical(bottom: Radius.circular(2)),
                                  ),
                                ),
                              ),
                            Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (highlight)
                                    Container(
                                      width: 40,
                                      height: 28,
                                      decoration: BoxDecoration(color: RS.z7, borderRadius: BorderRadius.circular(6)),
                                      child: Icon(icon, color: Colors.white, size: 19),
                                    )
                                  else
                                    Icon(icon, size: 24, color: i == index ? RS.z9 : RS.muted),
                                  const SizedBox(height: 4),
                                  Text(
                                    tr(context, label),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: i == index ? RS.z9 : RS.muted),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
