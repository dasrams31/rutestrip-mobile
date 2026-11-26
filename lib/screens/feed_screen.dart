import 'package:material_ui/material_ui.dart';

import '../api.dart';
import '../app_state.dart';
import '../i18n.dart';
import '../outbox.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/contour_header.dart';
import '../widgets/social.dart';
import 'compose_screen.dart';
import 'profile_screen.dart';

/// Linimasa tab: stories, Mengikuti / Semua, posts 20 at a time, queued posts on top.
class FeedScreen extends StatefulWidget {
  const FeedScreen({super.key, required this.active});

  final bool active;

  @override
  State<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends State<FeedScreen> {
  String _scope = 'following';
  late final CursorList<Post> _list = CursorList((c) => _api.feed(scope: _scope, cursor: c));
  final _scroll = ScrollController();
  Future<List<StoryGroup>>? _stories;
  DateTime _loadedAt = DateTime.fromMillisecondsSinceEpoch(0);
  int _sentSeen = Outbox.instance.sentCount;
  String? _lang;

  Api get _api => AppScope.read(context).api;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 800) _list.more();
    });
    Outbox.instance.addListener(_onOutbox);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final lang = AppScope.of(context).lang;
    if (_lang != lang) {
      _lang = lang;
      _refresh();
    }
  }

  @override
  void didUpdateWidget(covariant FeedScreen old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) {
      Outbox.instance.flush();
      if (DateTime.now().difference(_loadedAt) > const Duration(minutes: 2)) _refresh();
    }
  }

  @override
  void dispose() {
    Outbox.instance.removeListener(_onOutbox);
    _list.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// A queued post went out: show it.
  void _onOutbox() {
    if (Outbox.instance.sentCount != _sentSeen && mounted) {
      _sentSeen = Outbox.instance.sentCount;
      _refresh();
    }
  }

  Future<void> _refresh() {
    _loadedAt = DateTime.now();
    final stories = _api.stories()..ignore();
    setState(() {
      _stories = stories;
    });
    return _list.reload();
  }

  void _setScope(String scope) {
    if (scope == _scope) return;
    setState(() => _scope = scope);
    _list.reload();
  }

  Future<void> _compose({bool story = false}) async {
    final done = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => ComposeScreen(story: story)));
    if (done == true && mounted) _refresh();
  }

  void _findPeople() => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const UserSearchScreen()));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: () async {
          await Outbox.instance.flush();
          await _refresh();
        },
        child: ListenableBuilder(
          listenable: _list,
          builder: (context, _) => CustomScrollView(
            controller: _scroll,
            slivers: [
              SliverToBoxAdapter(child: _header(context)),
              SliverToBoxAdapter(
                child: _StoryBar(future: _stories, onAdd: () => _compose(story: true)),
              ),
              const SliverToBoxAdapter(child: OutboxChips()),
              ...postSlivers(
                context,
                _list,
                empty: MessageView(
                  title: tr(context, 'feed.empty'),
                  body: tr(context, _scope == 'following' ? 'feed.empty.following' : 'feed.empty.all'),
                  icon: Icons.dynamic_feed_outlined,
                  action: OutlinedButton.icon(onPressed: _findPeople, icon: const Icon(Icons.person_search), label: Text(tr(context, 'feed.find'))),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    Widget tab(String scope, String key) {
      final on = _scope == scope;
      return Expanded(
        child: Semantics(
          button: true,
          selected: on,
          child: OutlinedButton(
            onPressed: () => _setScope(scope),
            style: OutlinedButton.styleFrom(
              backgroundColor: on ? Colors.white : Colors.transparent,
              foregroundColor: on ? RS.z9 : Colors.white,
              side: BorderSide(color: on ? Colors.white : Colors.white70),
              textStyle: const TextStyle(fontFamily: RS.body, fontWeight: FontWeight.w700, fontSize: 15),
            ),
            child: Text(tr(context, key), maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ),
      );
    }

    return ContourHeader(
      seed: 14,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const HeaderBar(),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(tr(context, 'feed.title').toUpperCase(), style: RS.head(42, color: Colors.white)),
                ),
              ),
              IconButton(
                tooltip: tr(context, 'feed.find'),
                onPressed: _findPeople,
                icon: const Icon(Icons.person_search, color: Colors.white),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(children: [tab('following', 'feed.following'), const SizedBox(width: 8), tab('all', 'feed.all')]),
          const SizedBox(height: 12),
          SignButton(label: tr(context, 'feed.write'), onPressed: _compose),
        ],
      ),
    );
  }
}

/// Circles with initials for active stories (yours first), and one to add a story.
class _StoryBar extends StatelessWidget {
  const _StoryBar({required this.future, required this.onAdd});

  final Future<List<StoryGroup>>? future;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<StoryGroup>>(
      future: future,
      builder: (context, snap) {
        final groups = (snap.data ?? const <StoryGroup>[]).where((g) => g.items.isNotEmpty).toList();
        return SizedBox(
          height: 112,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            children: [
              _StoryCircle(
                label: tr(context, 'story.add'),
                semantic: tr(context, 'story.add'),
                onTap: onAdd,
                child: Container(
                  width: 62,
                  height: 62,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                    border: Border.all(color: RS.edge),
                  ),
                  child: const Icon(Icons.add, color: RS.z7, size: 30),
                ),
              ),
              for (final (i, g) in groups.indexed)
                _StoryCircle(
                  label: g.author.name,
                  semantic: tr(context, 'story.open', {'name': g.author.name}),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      fullscreenDialog: true,
                      builder: (_) => StoryViewer(groups: groups, start: i),
                    ),
                  ),
                  child: UserAvatar(name: g.author.name, size: 56, ring: true),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _StoryCircle extends StatelessWidget {
  const _StoryCircle({required this.label, required this.semantic, required this.onTap, required this.child});

  final String label, semantic;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semantic,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: 76,
          child: Column(
            children: [
              child,
              const SizedBox(height: 4),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: RS.ink),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Full-screen stories: a bar per item fills in 6 s, tap the right side for the next,
/// the left side for the previous; after the last item of a hiker the next hiker starts.
class StoryViewer extends StatefulWidget {
  const StoryViewer({super.key, required this.groups, this.start = 0});

  final List<StoryGroup> groups;
  final int start;

  @override
  State<StoryViewer> createState() => _StoryViewerState();
}

class _StoryViewerState extends State<StoryViewer> with SingleTickerProviderStateMixin {
  late int _group = widget.start;
  int _item = 0;
  late final AnimationController _clock = AnimationController(vsync: this, duration: const Duration(seconds: 6))
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed) _next();
    });

  StoryGroup get _g => widget.groups[_group];
  Post get _post => _g.items[_item];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_clock.isAnimating && _clock.value == 0) _show();
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  ImageProvider _image(String url) => ResizeImage(NetworkImage(url), width: 1080, policy: ResizeImagePolicy.fit);

  /// Waits for the photo before the bar starts, so a slow connection does not skip it.
  Future<void> _show() async {
    _clock
      ..stop()
      ..value = 0;
    final url = _post.photoUrl;
    final post = _post;
    if (url != null) await precacheImage(_image(url), context, onError: (_, _) {});
    if (mounted && identical(post, _post)) _clock.forward();
  }

  void _next() {
    if (_item < _g.items.length - 1) {
      setState(() => _item++);
    } else if (_group < widget.groups.length - 1) {
      setState(() {
        _group++;
        _item = 0;
      });
    } else {
      Navigator.of(context).maybePop();
      return;
    }
    _show();
  }

  void _previous() {
    if (_item > 0) {
      setState(() => _item--);
    } else if (_group > 0) {
      setState(() {
        _group--;
        _item = widget.groups[_group].items.length - 1;
      });
    }
    _show();
  }

  @override
  Widget build(BuildContext context) {
    final p = _post;
    final body = p.body?.trim() ?? '';
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (p.photoUrl != null)
            Image(
              image: _image(p.photoUrl!),
              fit: BoxFit.contain,
              semanticLabel: tr(context, 'post.photo'),
              errorBuilder: (context, _, _) => Center(
                child: Text(tr(context, 'post.photo.failed'), style: const TextStyle(color: Colors.white)),
              ),
            )
          else
            ContourBackground(
              seed: p.id,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Text(
                    body,
                    textAlign: TextAlign.center,
                    style: RS.head(34, color: Colors.white, weight: FontWeight.w700),
                  ),
                ),
              ),
            ),
          if (p.photoUrl != null && body.isNotEmpty)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                color: const Color(0xCC053B30),
                padding: EdgeInsets.fromLTRB(20, 14, 20, 14 + MediaQuery.paddingOf(context).bottom),
                child: Text(body, style: const TextStyle(color: Colors.white, fontSize: 16, height: 1.4)),
              ),
            ),
          // Tap zones: left third back, the rest forward.
          Row(
            children: [
              Expanded(
                child: Semantics(
                  button: true,
                  label: tr(context, 'story.previous'),
                  child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: _previous),
                ),
              ),
              Expanded(
                flex: 2,
                child: Semantics(
                  button: true,
                  label: tr(context, 'story.next'),
                  child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: _next),
                ),
              ),
            ],
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 4, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AnimatedBuilder(
                    animation: _clock,
                    builder: (context, _) => Row(
                      children: [
                        for (var i = 0; i < _g.items.length; i++)
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 2),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(2),
                                child: LinearProgressIndicator(
                                  value: i < _item ? 1 : (i == _item ? _clock.value : 0),
                                  minHeight: 3,
                                  color: Colors.white,
                                  backgroundColor: Colors.white.withValues(alpha: 0.35),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      UserAvatar(name: _g.author.name, size: 36),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _g.author.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15),
                            ),
                            Text(timeAgo(context, p.createdAt), style: const TextStyle(color: RS.onDarkSoft, fontSize: 13)),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                        onPressed: () => Navigator.of(context).maybePop(),
                        icon: const Icon(Icons.close, color: Colors.white),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
