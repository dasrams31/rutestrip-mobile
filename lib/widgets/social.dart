import 'dart:math' as math;

import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' show LatLng;
import 'package:material_ui/material_ui.dart';
import 'package:share_plus/share_plus.dart';

import '../api.dart';
import '../app_state.dart';
import '../i18n.dart';
import '../outbox.dart';
import '../screens/post_screen.dart';
import '../screens/profile_screen.dart';
import '../screens/route_detail_screen.dart';
import '../theme.dart';
import 'common.dart';
import 'trail_map.dart';

/// A cursor-paged list (20 per page from the server) that loads the next page on demand.
class CursorList<T> extends ChangeNotifier {
  CursorList(this.loader, {this.idOf});

  Future<SocialPage<T>> Function(String? cursor) loader;

  /// Drops items already in the list (an own comment added before its page loads).
  final int Function(T)? idOf;

  final items = <T>[];
  String? _cursor;
  bool done = false, loading = false, loaded = false;
  Object? error;
  int _gen = 0;
  bool _disposed = false;

  Future<void> reload() {
    _gen++;
    items.clear();
    _cursor = null;
    done = false;
    loaded = false;
    loading = false;
    error = null;
    return more();
  }

  Future<void> more() async {
    if (loading || done) return;
    final gen = _gen;
    loading = true;
    error = null;
    _notify();
    try {
      final page = await loader(_cursor);
      if (gen != _gen) return;
      final seen = idOf == null ? const <int>{} : items.map(idOf!).toSet();
      items.addAll(idOf == null ? page.items : page.items.where((e) => !seen.contains(idOf!(e))));
      _cursor = page.nextCursor;
      done = page.nextCursor == null;
      loaded = true;
    } catch (e) {
      if (gen == _gen) error = e;
    } finally {
      if (gen == _gen) {
        loading = false;
        _notify();
      }
    }
  }

  void changed() => _notify();

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// "5 mnt", "3 j", "2 h", then the date.
String timeAgo(BuildContext context, DateTime? t, {DateTime? now}) {
  if (t == null) return '';
  final d = (now ?? DateTime.now()).difference(t);
  if (d.inMinutes < 1) return tr(context, 'feed.ago.now');
  if (d.inHours < 1) return tr(context, 'feed.ago.m', {'n': d.inMinutes});
  if (d.inDays < 1) return tr(context, 'feed.ago.h', {'n': d.inHours});
  if (d.inDays < 7) return tr(context, 'feed.ago.d', {'n': d.inDays});
  return '${t.day}/${t.month}/${t.year}';
}

/// Initials in a circle: profile photos are not part of RuteStrip.
class UserAvatar extends StatelessWidget {
  const UserAvatar({super.key, required this.name, this.size = 40, this.ring = false});

  final String name;
  final double size;

  /// Emerald ring for a story that can be opened.
  final bool ring;

  static String initials(String name) {
    final words = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return '?';
    return (words.first.characters.first + (words.length > 1 ? words[1].characters.first : '')).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final inner = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: RS.mist,
        shape: BoxShape.circle,
        border: Border.all(color: RS.line),
      ),
      child: Text(initials(name), style: RS.head(size * 0.46, color: RS.z9)),
    );
    if (!ring) return ExcludeSemantics(child: inner);
    return ExcludeSemantics(
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: RS.z7, width: 2.5),
        ),
        child: inner,
      ),
    );
  }
}

void _toast(BuildContext context, String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

/// One post: author, time, text, photo, track with numbers, place, trail, and the actions.
/// [detail]: the post page (full text, full photo, real map) instead of a feed card.
class PostCard extends StatefulWidget {
  const PostCard({super.key, required this.post, this.detail = false, this.onDeleted, this.onOpen});

  final Post post;
  final bool detail;
  final VoidCallback? onDeleted;

  /// Opens the post page; null on the post page itself.
  final VoidCallback? onOpen;

  @override
  State<PostCard> createState() => _PostCardState();
}

class _PostCardState extends State<PostCard> {
  Post get p => widget.post;

  Future<void> _like() async {
    final api = AppScope.read(context).api;
    final was = p.liked;
    setState(() {
      p.liked = !was;
      p.likesCount = math.max(0, p.likesCount + (was ? -1 : 1));
    });
    try {
      final (liked, count) = await api.setPostLike(p.id, !was);
      if (mounted) {
        setState(() {
          p.liked = liked;
          p.likesCount = count;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        p.liked = was;
        p.likesCount = math.max(0, p.likesCount + (was ? 1 : -1));
      });
      _toast(context, errorText(context, e));
    }
  }

  Future<void> _save() async {
    final api = AppScope.read(context).api;
    final was = p.saved;
    setState(() => p.saved = !was);
    try {
      final saved = await api.setPostSave(p.id, !was);
      if (!mounted) return;
      setState(() => p.saved = saved);
      _toast(context, tr(context, saved ? 'post.saved' : 'post.unsaved'));
    } catch (e) {
      if (!mounted) return;
      setState(() => p.saved = was);
      _toast(context, errorText(context, e));
    }
  }

  Future<void> _share() async {
    final url = p.shareUrl;
    if (url == null) return;
    await SharePlus.instance.share(ShareParams(text: url, subject: p.author.name));
  }

  Future<void> _report() async {
    final reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr(context, 'post.report.title')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr(context, 'post.report.lead'), style: const TextStyle(color: RS.muted, height: 1.4)),
            const SizedBox(height: 12),
            TextField(
              controller: reason,
              maxLength: 300,
              minLines: 1,
              maxLines: 3,
              decoration: InputDecoration(labelText: tr(context, 'post.report.reason')),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr(context, 'chat.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr(context, 'post.report.send'))),
        ],
      ),
    );
    final text = reason.text.trim();
    reason.dispose();
    if (ok != true || !mounted) return;
    try {
      await AppScope.read(context).api.reportPost(p.id, reason: text.isEmpty ? null : text);
      if (mounted) _toast(context, tr(context, 'post.report.done'));
    } catch (e) {
      if (mounted) _toast(context, errorText(context, e));
    }
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(tr(context, 'post.delete.confirm')),
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
      await AppScope.read(context).api.deletePost(p.id);
      if (!mounted) return;
      _toast(context, tr(context, 'post.deleted'));
      widget.onDeleted?.call();
    } catch (e) {
      if (mounted) _toast(context, errorText(context, e));
    }
  }

  void _openAuthor() => Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => ProfileScreen(userId: p.author.id, name: p.author.name),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final body = p.body?.trim() ?? '';
    final track = p.track ?? const <List<double>>[];
    final when = [timeAgo(context, p.createdAt), if (p.type == 'story') tr(context, 'story.label')].where((s) => s.isNotEmpty).join(' · ');
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: widget.onOpen,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 0, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Semantics(
                      button: true,
                      label: tr(context, 'prof.open', {'name': p.author.name}),
                      excludeSemantics: true,
                      child: InkWell(
                        onTap: _openAuthor,
                        borderRadius: BorderRadius.circular(8),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 48),
                          child: Row(
                            children: [
                              UserAvatar(name: p.author.name),
                              const SizedBox(width: 10),
                              Flexible(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      p.author.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                                    ),
                                    if (when.isNotEmpty) Text(when, style: const TextStyle(color: RS.muted, fontSize: 13)),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  PopupMenuButton<String>(
                    tooltip: tr(context, 'post.menu'),
                    icon: const Icon(Icons.more_vert, color: RS.muted),
                    onSelected: (v) => v == 'delete' ? _delete() : _report(),
                    itemBuilder: (context) => [
                      if (p.isMine)
                        PopupMenuItem(value: 'delete', child: Text(tr(context, 'post.delete')))
                      else
                        PopupMenuItem(value: 'report', child: Text(tr(context, 'post.report'))),
                    ],
                  ),
                ],
              ),
            ),
            if (body.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 2, 16, 10),
                child: Text(
                  body,
                  maxLines: widget.detail ? null : 8,
                  overflow: widget.detail ? null : TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 15.5, height: 1.45),
                ),
              ),
            if (p.photoUrl != null) PostPhoto(url: p.photoUrl!, full: widget.detail),
            if (track.length >= 2) ...[
              if (widget.detail) PostTrackMap(track: track, title: p.author.name) else TrackThumb(track: track, height: 150),
              if (p.stats != null) PostStatsRow(stats: p.stats!),
            ],
            if (p.place != null || p.routeId != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    if (p.place != null) PlaceChip(place: p.place!),
                    if (p.routeId != null)
                      TextButton.icon(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => RouteDetailScreen(id: p.routeId!, name: p.routeName ?? ''),
                          ),
                        ),
                        icon: const Icon(Icons.terrain_outlined, size: 20),
                        label: Text(p.routeName ?? tr(context, 'post.route'), maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
              child: Row(
                children: [
                  _Action(
                    icon: p.liked ? Icons.favorite : Icons.favorite_border,
                    color: p.liked ? RS.err : RS.muted,
                    count: p.likesCount,
                    label: tr(context, p.liked ? 'post.unlike' : 'post.like'),
                    selected: p.liked,
                    onTap: _like,
                  ),
                  _Action(icon: Icons.chat_bubble_outline, color: RS.muted, count: p.commentsCount, label: tr(context, 'post.comments'), onTap: widget.onOpen),
                  const Spacer(),
                  IconButton(
                    tooltip: tr(context, p.saved ? 'post.unsave' : 'post.save'),
                    isSelected: p.saved,
                    onPressed: _save,
                    icon: Icon(p.saved ? Icons.bookmark : Icons.bookmark_border, color: p.saved ? RS.z7 : RS.muted),
                  ),
                  if (p.shareUrl != null)
                    IconButton(
                      tooltip: tr(context, 'post.share'),
                      onPressed: _share,
                      icon: const Icon(Icons.share_outlined, color: RS.muted),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({required this.icon, required this.color, required this.count, required this.label, required this.onTap, this.selected = false});

  final IconData icon;
  final Color color;
  final int count;
  final String label;
  final VoidCallback? onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: '$label, $count',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48, minWidth: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: color, size: 22),
                const SizedBox(width: 6),
                Text(
                  fmtNum(context, count),
                  style: const TextStyle(fontWeight: FontWeight.w600, color: RS.ink, fontFeatures: [FontFeature.tabularFigures()]),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The photo of a post, decoded at screen width at most (light on memory).
class PostPhoto extends StatelessWidget {
  const PostPhoto({super.key, required this.url, this.full = false});

  final String url;
  final bool full;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final cacheWidth = math.min(1080, (mq.size.width * mq.devicePixelRatio).round());
    final image = Image.network(
      url,
      fit: full ? BoxFit.fitWidth : BoxFit.cover,
      cacheWidth: cacheWidth,
      semanticLabel: tr(context, 'post.photo'),
      loadingBuilder: (context, child, progress) => progress == null ? child : Container(color: RS.mist, height: full ? 240 : null),
      errorBuilder: (context, _, _) => Container(
        color: RS.mist,
        height: 160,
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.broken_image_outlined, color: RS.muted),
            const SizedBox(height: 4),
            Text(tr(context, 'post.photo.failed'), style: const TextStyle(color: RS.muted, fontSize: 13)),
          ],
        ),
      ),
    );
    return full ? image : AspectRatio(aspectRatio: 4 / 3, child: image);
  }
}

class PostStatsRow extends StatelessWidget {
  const PostStatsRow({super.key, required this.stats});

  final PostStats stats;

  @override
  Widget build(BuildContext context) {
    Widget stat(String label, String value) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 12.5, color: RS.muted)),
          Text(
            value,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: RS.ink, fontFeatures: [FontFeature.tabularFigures()]),
          ),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Row(
        children: [
          stat(tr(context, 'record.distance'), '${fmtNum(context, stats.distanceKm, 1)} km'),
          stat(tr(context, 'record.gain'), '${fmtNum(context, stats.gainM)} m'),
          if (stats.movingS > 0) stat(tr(context, 'rec.moving'), fmtHours(context, stats.movingS / 3600)),
        ],
      ),
    );
  }
}

/// The place of a post; opens OpenStreetMap at that spot.
class PlaceChip extends StatelessWidget {
  const PlaceChip({super.key, required this.place});

  final Place place;

  @override
  Widget build(BuildContext context) {
    final label = place.label.isEmpty ? '${place.lat.toStringAsFixed(5)}, ${place.lng.toStringAsFixed(5)}' : place.label;
    return Semantics(
      link: true,
      label: tr(context, 'post.place.open', {'place': label}),
      excludeSemantics: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => openExternal('https://www.openstreetmap.org/?mlat=${place.lat}&mlon=${place.lng}#map=15/${place.lat}/${place.lng}'),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: RS.edge),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.place_outlined, size: 18, color: RS.z7),
                    const SizedBox(width: 4),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 220),
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The track on the real map (post page only; feed cards draw the light line).
class PostTrackMap extends StatelessWidget {
  const PostTrackMap({super.key, required this.track, required this.title, this.interactive = false});

  final List<List<double>> track;
  final String title;
  final bool interactive;

  @override
  Widget build(BuildContext context) {
    final pts = track.map((p) => LatLng(p[0], p[1])).toList();
    final map = FlutterMap(
      options: MapOptions(
        initialCameraFit: CameraFit.coordinates(coordinates: pts, padding: const EdgeInsets.all(28), maxZoom: 16),
        interactionOptions: InteractionOptions(flags: interactive ? InteractiveFlag.all & ~InteractiveFlag.rotate : InteractiveFlag.none),
        backgroundColor: RS.mist,
      ),
      children: [
        const BaseTiles(),
        PolylineLayer(
          polylines: [
            Polyline(points: pts, strokeWidth: 6, color: Colors.white),
            Polyline(points: pts, strokeWidth: 3.5, color: RS.z7),
          ],
        ),
        MarkerLayer(
          markers: [
            Marker(
              point: pts.first,
              width: 20,
              height: 20,
              child: Container(
                decoration: BoxDecoration(
                  color: RS.z9,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 3),
                ),
              ),
            ),
          ],
        ),
        const OsmAttribution(),
      ],
    );
    if (interactive) return map;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(height: 240, child: IgnorePointer(child: map)),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => Scaffold(
                  appBar: AppBar(
                    backgroundColor: RS.z9,
                    foregroundColor: Colors.white,
                    title: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: RS.head(24, color: Colors.white),
                    ),
                  ),
                  body: PostTrackMap(track: track, title: title, interactive: true),
                ),
              ),
            ),
            icon: const Icon(Icons.fullscreen),
            label: Text(tr(context, 'detail.map.open')),
          ),
        ),
      ],
    );
  }
}

/// Posts waiting for signal, at the top of the feed, each with a way to cancel it.
class OutboxChips extends StatelessWidget {
  const OutboxChips({super.key});

  Future<void> _cancel(BuildContext context, PostDraft d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(tr(context, 'outbox.cancel.confirm')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr(context, 'outbox.keep'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: RS.err),
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr(context, 'outbox.cancel')),
          ),
        ],
      ),
    );
    if (ok == true) await Outbox.instance.cancel(d.clientId);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Outbox.instance,
      builder: (context, _) {
        final items = Outbox.instance.items;
        if (items.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: pageGutter(context, top: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final d in items)
                Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.only(left: 12),
                  decoration: BoxDecoration(
                    color: RS.warnBg,
                    border: Border.all(color: RS.warnLine),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(d.error == null ? Icons.cloud_upload_outlined : Icons.error_outline, color: RS.warnInk, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              tr(context, d.error == null ? 'outbox.waiting' : 'outbox.refused'),
                              style: const TextStyle(fontWeight: FontWeight.w700, color: RS.warnInk, fontSize: 14),
                            ),
                            Text(
                              _summary(context, d),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: RS.warnInk, fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: tr(context, 'outbox.cancel'),
                        onPressed: () => _cancel(context, d),
                        icon: const Icon(Icons.close, color: RS.warnInk),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  static String _summary(BuildContext context, PostDraft d) {
    if (d.error != null && d.error!.isNotEmpty) return d.error!;
    final body = d.body?.trim().replaceAll(RegExp(r'\s+'), ' ') ?? '';
    if (body.isNotEmpty) return body;
    return tr(context, 'outbox.type.${d.type}');
  }
}

/// Follow or stop following; [big] is the profile page's main action.
class FollowButton extends StatefulWidget {
  const FollowButton({super.key, required this.user, this.big = false, this.onChanged});

  final UserBrief user;
  final bool big;
  final void Function(bool following, int? followers)? onChanged;

  @override
  State<FollowButton> createState() => _FollowButtonState();
}

class _FollowButtonState extends State<FollowButton> {
  bool _busy = false;

  Future<void> _toggle() async {
    final u = widget.user;
    final was = u.isFollowing;
    setState(() {
      _busy = true;
      u.isFollowing = !was;
    });
    widget.onChanged?.call(!was, null);
    try {
      final (following, followers) = await AppScope.read(context).api.setFollow(u.id, !was);
      u.isFollowing = following;
      widget.onChanged?.call(following, followers);
    } catch (e) {
      u.isFollowing = was;
      widget.onChanged?.call(was, null);
      if (mounted) _toast(context, errorText(context, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final on = widget.user.isFollowing;
    if (widget.big && !on) return SignButton(label: tr(context, 'prof.follow'), onPressed: _busy ? null : _toggle);
    if (on) {
      return OutlinedButton(
        onPressed: _busy ? null : _toggle,
        style: widget.big
            ? OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: Colors.white70),
              )
            : null,
        child: Text(tr(context, 'prof.following.btn')),
      );
    }
    return FilledButton(onPressed: _busy ? null : _toggle, child: Text(tr(context, 'prof.follow')));
  }
}

/// A user in a list: initials, name, bio, and the follow button (not for yourself).
class UserRow extends StatelessWidget {
  const UserRow({super.key, required this.user});

  final UserBrief user;

  @override
  Widget build(BuildContext context) {
    final me = AppScope.of(context).user?.id == user.id;
    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ProfileScreen(userId: user.id, name: user.name),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            UserAvatar(name: user.name, size: 44),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    user.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                  ),
                  if ((user.bio ?? '').trim().isNotEmpty)
                    Text(
                      user.bio!.trim(),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: RS.muted, fontSize: 13.5, height: 1.35),
                    ),
                ],
              ),
            ),
            if (!me) ...[const SizedBox(width: 8), FollowButton(user: user)],
          ],
        ),
      ),
    );
  }
}

/// Slivers for a paged list of posts: first load, error, empty, the cards, and the footer.
List<Widget> postSlivers(BuildContext context, CursorList<Post> list, {required Widget empty}) {
  if (list.items.isEmpty && (list.loading || !list.loaded && list.error == null)) return const [SliverToBoxAdapter(child: LoadingView())];
  if (list.items.isEmpty && list.error != null) {
    return [
      SliverToBoxAdapter(
        child: ErrorView(error: list.error!, onRetry: list.reload),
      ),
    ];
  }
  if (list.items.isEmpty) return [SliverToBoxAdapter(child: empty)];
  return [
    SliverPadding(
      padding: pageGutter(context, top: 14, bottom: 8),
      sliver: SliverList.separated(
        itemCount: list.items.length,
        separatorBuilder: (_, _) => const SizedBox(height: 12),
        itemBuilder: (context, i) {
          final post = list.items[i];
          return PostCard(
            key: ValueKey(post.id),
            post: post,
            onOpen: () async {
              final gone = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => PostScreen(post: post)));
              if (gone == true) {
                list.items.remove(post);
                list.changed();
              } else {
                list.changed(); // counts changed on the post page
              }
            },
            onDeleted: () {
              list.items.remove(post);
              list.changed();
            },
          );
        },
      ),
    ),
    SliverToBoxAdapter(
      child: list.error != null
          ? ErrorView(error: list.error!, onRetry: list.more)
          : list.loading
          ? LoadingView(label: tr(context, 'feed.more'))
          : const SizedBox(height: 32),
    ),
  ];
}
