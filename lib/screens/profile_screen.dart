import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../api.dart';
import '../app_state.dart';
import '../i18n.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/contour_header.dart';
import '../widgets/social.dart';

/// A hiker's page: bio, counts, follow button and their posts. Without [userId]: your own.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key, this.userId, this.name});

  final int? userId;
  final String? name;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late final int _id = widget.userId ?? AppScope.read(context).user!.id;
  late final CursorList<Post> _posts = CursorList((c) => _api.userPosts(_id, cursor: c));
  final _scroll = ScrollController();
  Profile? _profile;
  Object? _error;

  Api get _api => AppScope.read(context).api;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 800) _posts.more();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  @override
  void dispose() {
    _posts.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    final posts = _posts.reload();
    try {
      final p = await _api.profile(_id);
      if (mounted) setState(() => _profile = p);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
    await posts;
  }

  Future<void> _editBio() async {
    final p = _profile!;
    final input = TextEditingController(text: p.bio ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr(context, 'prof.bio.edit')),
        content: TextField(
          controller: input,
          maxLength: 300,
          minLines: 3,
          maxLines: 6,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(labelText: tr(context, 'prof.bio'), hintText: tr(context, 'prof.bio.hint')),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr(context, 'chat.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr(context, 'set.save'))),
        ],
      ),
    );
    final text = input.text;
    input.dispose();
    if (ok != true || !mounted) return;
    final state = AppScope.read(context);
    try {
      final bio = await state.api.updateBio(state.user!, text);
      if (!mounted) return;
      setState(() => p.bio = bio);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr(context, 'prof.bio.saved'))));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errorText(context, e))));
    }
  }

  void _openList(String which) {
    final p = _profile!;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => UserListScreen(
          title: tr(context, which == 'followers' ? 'prof.followers.of' : 'prof.following.of', {'name': p.name}),
          loader: (api, cursor) => api.follows(p.id, which, cursor: cursor),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = _profile;
    final name = p?.name ?? widget.name ?? '';
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListenableBuilder(
          listenable: _posts,
          builder: (context, _) => CustomScrollView(
            controller: _scroll,
            slivers: [
              SliverToBoxAdapter(
                child: ContourHeader(
                  seed: 27,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      HeaderBar(title: tr(context, 'prof.title')),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          UserAvatar(name: name, size: 60),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Semantics(
                              header: true,
                              child: Text(name.toUpperCase(), style: RS.head(34, color: Colors.white)),
                            ),
                          ),
                        ],
                      ),
                      if (p != null) ..._details(context, p),
                    ],
                  ),
                ),
              ),
              if (p == null && _error != null)
                SliverToBoxAdapter(
                  child: ErrorView(error: _error!, onRetry: _load),
                )
              else
                ...postSlivers(
                  context,
                  _posts,
                  empty: MessageView(title: tr(context, p?.isMe == true ? 'prof.posts.empty.me' : 'prof.posts.empty'), icon: Icons.dynamic_feed_outlined),
                ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _details(BuildContext context, Profile p) {
    final bio = (p.bio ?? '').trim();
    Widget count(int n, String key, VoidCallback? onTap) => Expanded(
      child: Semantics(
        button: onTap != null,
        label: '${tr(context, key)}: $n',
        excludeSemantics: true,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 52),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  fmtNum(context, n),
                  style: RS.head(26, color: Colors.white, weight: FontWeight.w700),
                ),
                Text(
                  tr(context, key),
                  style: TextStyle(
                    color: RS.onDarkSoft,
                    fontSize: 13,
                    decoration: onTap == null ? null : TextDecoration.underline,
                    decorationColor: RS.onDarkSoft,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return [
      const SizedBox(height: 12),
      if (bio.isNotEmpty)
        Text(bio, style: const TextStyle(color: Color(0xFFD1FAE5), fontSize: 15, height: 1.45))
      else if (p.isMe)
        Text(tr(context, 'prof.bio.none'), style: const TextStyle(color: RS.onDarkSoft, fontSize: 14.5)),
      if (p.followsMe && !p.isMe) ...[
        const SizedBox(height: 6),
        Text(tr(context, 'prof.follows_you'), style: const TextStyle(color: RS.onDarkSoft, fontSize: 13.5)),
      ],
      const SizedBox(height: 12),
      Row(
        children: [
          count(p.postsCount, 'prof.posts', null),
          count(p.followersCount, 'prof.followers', () => _openList('followers')),
          count(p.followingCount, 'prof.following', () => _openList('following')),
        ],
      ),
      const SizedBox(height: 12),
      if (p.isMe)
        OutlinedButton.icon(
          onPressed: _editBio,
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.white,
            side: const BorderSide(color: Colors.white70),
          ),
          icon: const Icon(Icons.edit_outlined),
          label: Text(tr(context, 'prof.bio.edit')),
        )
      else
        SizedBox(
          width: double.infinity,
          child: FollowButton(
            big: true,
            user: UserBrief(id: p.id, name: p.name, bio: p.bio, isFollowing: p.isFollowing),
            onChanged: (following, followers) {
              if (!mounted) return;
              setState(() {
                if (followers != null) {
                  p.followersCount = followers;
                } else if (following != p.isFollowing) {
                  p.followersCount += following ? 1 : -1;
                }
                p.isFollowing = following;
              });
            },
          ),
        ),
    ];
  }
}

/// Followers or following of one hiker, 20 at a time.
class UserListScreen extends StatefulWidget {
  const UserListScreen({super.key, required this.title, required this.loader});

  final String title;
  final Future<SocialPage<UserBrief>> Function(Api api, String? cursor) loader;

  @override
  State<UserListScreen> createState() => _UserListScreenState();
}

class _UserListScreenState extends State<UserListScreen> {
  late final CursorList<UserBrief> _list = CursorList((c) => widget.loader(AppScope.read(context).api, c));
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 600) _list.more();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _list.reload();
    });
  }

  @override
  void dispose() {
    _list.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListenableBuilder(
        listenable: _list,
        builder: (context, _) => CustomScrollView(
          controller: _scroll,
          slivers: [
            SliverToBoxAdapter(child: _PageHeader(title: widget.title)),
            if (_list.items.isEmpty && (_list.loading || !_list.loaded && _list.error == null))
              const SliverToBoxAdapter(child: LoadingView())
            else if (_list.items.isEmpty && _list.error != null)
              SliverToBoxAdapter(
                child: ErrorView(error: _list.error!, onRetry: _list.reload),
              )
            else if (_list.items.isEmpty)
              SliverToBoxAdapter(
                child: MessageView(title: tr(context, 'prof.list.empty'), icon: Icons.group_outlined),
              )
            else ...[
              SliverPadding(
                padding: pageGutter(context, top: 8),
                sliver: SliverList.builder(
                  itemCount: _list.items.length,
                  itemBuilder: (context, i) => UserRow(user: _list.items[i]),
                ),
              ),
              SliverToBoxAdapter(
                child: _list.error != null
                    ? ErrorView(error: _list.error!, onRetry: _list.more)
                    : _list.loading
                    ? const LoadingView()
                    : const SizedBox(height: 32),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PageHeader extends StatelessWidget {
  const _PageHeader({required this.title, this.child});

  final String title;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return ContourHeader(
      seed: 29,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const HeaderBar(),
          const SizedBox(height: 10),
          Semantics(
            header: true,
            child: Text(title.toUpperCase(), style: RS.head(34, color: Colors.white)),
          ),
          if (child != null) ...[const SizedBox(height: 14), child!],
        ],
      ),
    );
  }
}

/// Find hikers by name (at least 2 letters, 20 results).
class UserSearchScreen extends StatefulWidget {
  const UserSearchScreen({super.key});

  @override
  State<UserSearchScreen> createState() => _UserSearchScreenState();
}

class _UserSearchScreenState extends State<UserSearchScreen> {
  final _input = TextEditingController();
  Timer? _debounce;
  List<UserBrief>? _results;
  Object? _error;
  bool _loading = false;
  int _gen = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    _input.dispose();
    super.dispose();
  }

  void _changed(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () => _search(q));
  }

  Future<void> _search(String q) async {
    final gen = ++_gen;
    if (q.trim().length < 2) {
      setState(() {
        _results = null;
        _error = null;
        _loading = false;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await AppScope.read(context).api.searchUsers(q);
      if (mounted && gen == _gen) setState(() => _results = r);
    } catch (e) {
      if (mounted && gen == _gen) setState(() => _error = e);
    } finally {
      if (mounted && gen == _gen) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = _results;
    return Scaffold(
      body: ListView(
        padding: EdgeInsets.zero,
        children: [
          _PageHeader(
            title: tr(context, 'prof.search.title'),
            child: TextField(
              controller: _input,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onChanged: _changed,
              onSubmitted: _search,
              maxLength: 60,
              decoration: InputDecoration(
                labelText: tr(context, 'prof.search.label'),
                prefixIcon: const Icon(Icons.person_search, color: RS.muted),
                counterText: '',
              ),
            ),
          ),
          if (_loading)
            const LoadingView()
          else if (_error != null)
            ErrorView(error: _error!, onRetry: () => _search(_input.text))
          else if (r == null)
            Padding(
              padding: pageGutter(context, top: 18, min: 20),
              child: Text(tr(context, 'prof.search.hint'), style: const TextStyle(color: RS.muted, fontSize: 14.5, height: 1.4)),
            )
          else if (r.isEmpty)
            MessageView(title: tr(context, 'prof.search.none'), icon: Icons.person_off_outlined)
          else
            Padding(
              padding: pageGutter(context, top: 8, bottom: 32),
              child: Column(children: [for (final u in r) UserRow(user: u)]),
            ),
        ],
      ),
    );
  }
}

/// Posts you saved (only you see this list).
class SavedScreen extends StatefulWidget {
  const SavedScreen({super.key});

  @override
  State<SavedScreen> createState() => _SavedScreenState();
}

class _SavedScreenState extends State<SavedScreen> {
  late final CursorList<Post> _list = CursorList((c) => AppScope.read(context).api.saved(cursor: c));
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 800) _list.more();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _list.reload();
    });
  }

  @override
  void dispose() {
    _list.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: _list.reload,
        child: ListenableBuilder(
          listenable: _list,
          builder: (context, _) => CustomScrollView(
            controller: _scroll,
            slivers: [
              SliverToBoxAdapter(child: _PageHeader(title: tr(context, 'feed.saved'))),
              ...postSlivers(
                context,
                _list,
                empty: MessageView(title: tr(context, 'feed.saved.empty'), body: tr(context, 'feed.saved.empty.body'), icon: Icons.bookmark_border),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
