import 'dart:io';

import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:permission_handler/permission_handler.dart';

import '../api.dart';
import '../i18n.dart';
import '../location_hub.dart';
import '../outbox.dart';
import '../storage.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/contour_header.dart';
import '../widgets/social.dart';

/// Opens the composer with a saved recording: the track (at most 600 points) and its numbers.
Future<bool?> shareRecordingToFeed(BuildContext context, Recording r) => Navigator.of(context).push<bool>(
  MaterialPageRoute(
    builder: (_) => ComposeScreen(
      body: r.name,
      track: thinTrack([
        for (final p in r.points) [p.lat, p.lng],
      ]),
      stats: PostStats(distanceKm: r.distanceKm, gainM: r.gainM.round(), movingS: r.imported ? 0 : r.movingSeconds),
    ),
  ),
);

/// Opens the composer with a photo, a place, or both (stamped photo, marked spot).
Future<bool?> shareToFeed(BuildContext context, {String? photoPath, Place? place}) => Navigator.of(context).push<bool>(
  MaterialPageRoute(
    builder: (_) => ComposeScreen(photoPath: photoPath, place: place),
  ),
);

/// Writes a post: text, a photo, an optional place, as a story or not. Without signal the
/// post goes to the outbox and is sent later. Pops true when it was sent or queued.
class ComposeScreen extends StatefulWidget {
  const ComposeScreen({super.key, this.story = false, this.body, this.photoPath, this.track, this.stats, this.place, this.routeId});

  final bool story;
  final String? body, photoPath;
  final List<List<double>>? track;
  final PostStats? stats;
  final Place? place;
  final int? routeId;

  @override
  State<ComposeScreen> createState() => _ComposeScreenState();
}

class _ComposeScreenState extends State<ComposeScreen> {
  late final _text = TextEditingController(text: widget.body ?? '');
  late final _placeLabel = TextEditingController(text: widget.place?.label ?? '');
  late String? _photo = widget.photoPath;
  late bool _story = widget.story;
  late Place? _place = widget.place;
  bool _locating = false, _sending = false;
  String? _error;

  static const maxPhotoBytes = 8 * 1024 * 1024;

  bool get _hasTrack => (widget.track?.length ?? 0) >= 2;

  String get _type => _hasTrack
      ? 'recording'
      : _story
      ? 'story'
      : _photo != null
      ? 'photo'
      : 'status';

  @override
  void dispose() {
    _text.dispose();
    _placeLabel.dispose();
    super.dispose();
  }

  void _toast(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _pick(ImageSource source) async {
    if (source == ImageSource.camera) {
      final status = await Permission.camera.request();
      if (!mounted) return;
      if (!status.isGranted) return _toast(tr(context, 'stamp.camera'));
    }
    try {
      final x = await ImagePicker().pickImage(source: source, maxWidth: 1600, maxHeight: 1600, imageQuality: 85);
      if (x != null && mounted) setState(() => _photo = x.path);
    } catch (_) {
      if (mounted) _toast(tr(context, 'post.photo.pick_failed'));
    }
  }

  /// The phone's last known position when it is recent, otherwise one fresh fix.
  Future<void> _locate() async {
    setState(() => _locating = true);
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        if (mounted) _toast(tr(context, 'post.place.denied'));
        return;
      }
      var p = await Geolocator.getLastKnownPosition();
      if (p == null || DateTime.now().difference(p.timestamp) > const Duration(minutes: 10)) {
        p = await Geolocator.getCurrentPosition(locationSettings: LocationHub.instance.oneShot(timeLimit: const Duration(seconds: 12)));
      }
      if (mounted) setState(() => _place = Place(lat: p!.latitude, lng: p.longitude, label: ''));
    } catch (_) {
      if (mounted) _toast(tr(context, 'post.place.failed'));
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<void> _send() async {
    final body = _text.text.trim();
    final place = _place == null
        ? null
        : Place(
            lat: _place!.lat,
            lng: _place!.lng,
            label: _placeLabel.text.trim().isEmpty ? '${_place!.lat.toStringAsFixed(5)}, ${_place!.lng.toStringAsFixed(5)}' : _placeLabel.text.trim(),
          );
    final type = _type;
    final problem = switch (type) {
      'status' when body.isEmpty && place == null => 'post.need.status',
      'story' when body.isEmpty && _photo == null => 'post.need.story',
      _ => null,
    };
    if (problem != null) return setState(() => _error = tr(context, problem));
    if (_photo != null) {
      final f = File(_photo!);
      if (!await f.exists()) return setState(() => _error = tr(context, 'post.photo.pick_failed'));
      if (await f.length() > maxPhotoBytes) return setState(() => _error = tr(context, 'post.photo.too_big'));
    }
    setState(() {
      _error = null;
      _sending = true;
    });
    final draft = PostDraft(
      clientId: newClientId(),
      type: type,
      body: body.isEmpty ? null : body,
      photoPath: _photo,
      track: _hasTrack ? widget.track : null,
      stats: _hasTrack ? widget.stats : null,
      place: place,
      routeId: widget.routeId,
    );
    try {
      final post = await Outbox.instance.submit(draft);
      if (!mounted) return;
      _toast(tr(context, post == null ? 'outbox.queued' : (type == 'story' ? 'post.sent.story' : 'post.sent')));
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.fieldErrors.values.firstOrNull ?? errorText(context, e));
    } catch (e) {
      if (mounted) setState(() => _error = errorText(context, e));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListView(
        padding: EdgeInsets.zero,
        children: [
          ContourHeader(
            seed: 17,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const HeaderBar(),
                const SizedBox(height: 10),
                Semantics(
                  header: true,
                  child: Text(tr(context, _story ? 'story.new' : 'post.new').toUpperCase(), style: RS.head(36, color: Colors.white)),
                ),
              ],
            ),
          ),
          Padding(
            padding: pageGutter(context, top: 16, bottom: 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _text,
                  minLines: 3,
                  maxLines: 8,
                  maxLength: 2000,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(labelText: tr(context, 'post.body'), hintText: tr(context, 'post.body.hint'), alignLabelWithHint: true),
                ),
                if (_hasTrack) ...[
                  const SizedBox(height: 8),
                  Card(
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TrackThumb(track: widget.track!, height: 140),
                        if (widget.stats != null) PostStatsRow(stats: widget.stats!),
                        const SizedBox(height: 8),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                _photoBlock(context),
                const SizedBox(height: 12),
                _placeBlock(context),
                if (!_hasTrack) ...[
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _story,
                    onChanged: (v) => setState(() => _story = v),
                    title: Text(tr(context, 'story.toggle'), style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(tr(context, 'story.toggle.note'), style: const TextStyle(color: RS.muted, height: 1.35)),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _error!,
                    style: const TextStyle(color: RS.err, fontWeight: FontWeight.w600, height: 1.4),
                  ),
                ],
                const SizedBox(height: 16),
                SignButton(label: tr(context, 'post.send'), busyLabel: tr(context, 'post.sending'), busy: _sending, onPressed: _send),
                const SizedBox(height: 10),
                Text(tr(context, 'outbox.note'), style: const TextStyle(color: RS.muted, fontSize: 13.5, height: 1.4)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _photoBlock(BuildContext context) {
    if (_photo == null) {
      return Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          OutlinedButton.icon(
            onPressed: () => _pick(ImageSource.camera),
            style: OutlinedButton.styleFrom(backgroundColor: Colors.white),
            icon: const Icon(Icons.photo_camera_outlined, color: RS.z7),
            label: Text(tr(context, 'post.photo.camera')),
          ),
          OutlinedButton.icon(
            onPressed: () => _pick(ImageSource.gallery),
            style: OutlinedButton.styleFrom(backgroundColor: Colors.white),
            icon: const Icon(Icons.photo_library_outlined, color: RS.z7),
            label: Text(tr(context, 'post.photo.gallery')),
          ),
        ],
      );
    }
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 320),
            child: Image.file(
              File(_photo!),
              fit: BoxFit.contain,
              cacheWidth: 720,
              semanticLabel: tr(context, 'post.photo'),
              errorBuilder: (context, _, _) =>
                  Container(height: 120, color: RS.mist, alignment: Alignment.center, child: const Icon(Icons.broken_image_outlined)),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => setState(() => _photo = null),
              style: TextButton.styleFrom(foregroundColor: RS.err),
              icon: const Icon(Icons.close),
              label: Text(tr(context, 'post.photo.remove')),
            ),
          ),
        ],
      ),
    );
  }

  Widget _placeBlock(BuildContext context) {
    final p = _place;
    if (p == null) {
      return Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          onPressed: _locating ? null : _locate,
          style: OutlinedButton.styleFrom(backgroundColor: Colors.white),
          icon: _locating
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.5))
              : const Icon(Icons.place_outlined, color: RS.z7),
          label: Text(tr(context, _locating ? 'post.place.finding' : 'post.place.add')),
        ),
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 4, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.place_outlined, color: RS.z7),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${p.lat.toStringAsFixed(5)}, ${p.lng.toStringAsFixed(5)}',
                    style: const TextStyle(fontWeight: FontWeight.w600, fontFeatures: [FontFeature.tabularFigures()]),
                  ),
                ),
                IconButton(
                  tooltip: tr(context, 'post.place.remove'),
                  onPressed: () => setState(() => _place = null),
                  icon: const Icon(Icons.close, color: RS.muted),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(right: 10, top: 4),
              child: TextField(
                controller: _placeLabel,
                maxLength: 80,
                decoration: InputDecoration(labelText: tr(context, 'post.place.label'), hintText: tr(context, 'post.place.hint')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
