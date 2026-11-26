import 'package:material_ui/material_ui.dart';

import '../api.dart';
import '../app_state.dart';
import '../i18n.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/contour_header.dart';
import '../widgets/social.dart';
import 'profile_screen.dart';

/// One post with its comments (oldest first) and a field to add one.
/// Pops true when the post was deleted here.
class PostScreen extends StatefulWidget {
  const PostScreen({super.key, required this.post});

  final Post post;

  @override
  State<PostScreen> createState() => _PostScreenState();
}

class _PostScreenState extends State<PostScreen> {
  late Post _post = widget.post;
  late final CursorList<Comment> _comments = CursorList((c) => _api.comments(_post.id, cursor: c), idOf: (c) => c.id);
  final _input = TextEditingController();
  bool _sending = false, _gone = false;

  Api get _api => AppScope.read(context).api;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _comments.reload();
      _api
          .post(_post.id)
          .then(
            (p) {
              if (mounted) setState(() => _post = p);
            },
            onError: (Object e) {
              if (mounted && e is ApiException && e.kind == ApiError.notFound) setState(() => _gone = true);
            },
          );
    });
  }

  @override
  void dispose() {
    _comments.dispose();
    _input.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final c = await _api.addComment(_post.id, text);
      _input.clear();
      _comments.items.add(c);
      _post.commentsCount++;
      _comments.changed();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errorText(context, e))));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _delete(Comment c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(tr(context, 'post.comment.delete.confirm')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr(context, 'chat.cancel'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: RS.err),
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr(context, 'post.delete')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await _api.deleteComment(c.id);
      _comments.items.remove(c);
      if (_post.commentsCount > 0) _post.commentsCount--;
      _comments.changed();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errorText(context, e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          Expanded(
            child: ListenableBuilder(
              listenable: _comments,
              builder: (context, _) => CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: ContourHeader(
                      seed: 33,
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 18),
                      child: HeaderBar(title: tr(context, 'post.title')),
                    ),
                  ),
                  if (_gone)
                    SliverToBoxAdapter(
                      child: MessageView(title: tr(context, 'post.gone'), body: tr(context, 'post.gone.body')),
                    )
                  else ...[
                    SliverPadding(
                      padding: pageGutter(context, top: 14),
                      sliver: SliverToBoxAdapter(
                        child: PostCard(key: ValueKey(_post), post: _post, detail: true, onDeleted: () => Navigator.of(context).pop(true)),
                      ),
                    ),
                    SliverPadding(
                      padding: pageGutter(context, top: 22, bottom: 4, min: 20),
                      sliver: SliverToBoxAdapter(
                        child: Semantics(
                          header: true,
                          child: Text(tr(context, 'post.comments').toUpperCase(), style: RS.head(24, color: RS.z9)),
                        ),
                      ),
                    ),
                    ..._commentSlivers(context),
                  ],
                ],
              ),
            ),
          ),
          if (!_gone) _composer(context),
        ],
      ),
    );
  }

  List<Widget> _commentSlivers(BuildContext context) {
    final list = _comments;
    if (list.items.isEmpty && (list.loading || !list.loaded && list.error == null)) return const [SliverToBoxAdapter(child: LoadingView())];
    if (list.items.isEmpty && list.error != null) {
      return [
        SliverToBoxAdapter(
          child: ErrorView(error: list.error!, onRetry: list.reload),
        ),
      ];
    }
    if (list.items.isEmpty) {
      return [
        SliverPadding(
          padding: pageGutter(context, top: 4, bottom: 24, min: 20),
          sliver: SliverToBoxAdapter(
            child: Text(tr(context, 'post.comments.empty'), style: const TextStyle(color: RS.muted, fontSize: 14.5, height: 1.4)),
          ),
        ),
      ];
    }
    return [
      SliverPadding(
        padding: pageGutter(context),
        sliver: SliverList.builder(
          itemCount: list.items.length,
          itemBuilder: (context, i) {
            final c = list.items[i];
            return _CommentRow(comment: c, canDelete: c.isMine || _post.isMine, onDelete: () => _delete(c));
          },
        ),
      ),
      SliverToBoxAdapter(
        child: list.error != null
            ? ErrorView(error: list.error!, onRetry: list.more)
            : list.loading
            ? const LoadingView()
            : !list.done
            ? Padding(
                padding: pageGutter(context, min: 20),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(onPressed: list.more, child: Text(tr(context, 'post.comments.more'))),
                ),
              )
            : const SizedBox(height: 24),
      ),
    ];
  }

  Widget _composer(BuildContext context) {
    return Material(
      color: Colors.white,
      child: Container(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: RS.line)),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    minLines: 1,
                    maxLines: 4,
                    maxLength: 1000,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(hintText: tr(context, 'post.comment.hint'), counterText: '', isDense: true),
                  ),
                ),
                IconButton(
                  tooltip: tr(context, 'post.comment.send'),
                  onPressed: _sending ? null : _send,
                  icon: _sending
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5))
                      : const Icon(Icons.send, color: RS.z7),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CommentRow extends StatelessWidget {
  const _CommentRow({required this.comment, required this.canDelete, required this.onDelete});

  final Comment comment;
  final bool canDelete;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final c = comment;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            button: true,
            label: tr(context, 'prof.open', {'name': c.author.name}),
            excludeSemantics: true,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => ProfileScreen(userId: c.author.id, name: c.author.name),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: UserAvatar(name: c.author.name, size: 36),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: RS.line),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: c.author.name,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        TextSpan(
                          text: '  ${timeAgo(context, c.createdAt)}',
                          style: const TextStyle(color: RS.muted, fontSize: 12.5),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(c.body, style: const TextStyle(fontSize: 15, height: 1.4)),
                ],
              ),
            ),
          ),
          if (canDelete)
            IconButton(
              tooltip: tr(context, 'post.comment.delete'),
              onPressed: onDelete,
              icon: const Icon(Icons.delete_outline, color: RS.muted),
            ),
        ],
      ),
    );
  }
}
