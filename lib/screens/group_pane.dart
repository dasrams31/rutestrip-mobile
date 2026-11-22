import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' show LatLng;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../app_state.dart';
import '../i18n.dart';
import '../mesh/mesh_protocol.dart';
import '../mesh/mesh_service.dart';
import '../notify.dart';
import '../storage.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/trail_map.dart' show OsmAttribution;
import 'qr_scan_screen.dart';
import 'record_screen.dart' show mapFocus, liveTrack, waypointKinds;
import 'shell.dart';

/// "Rombongan": chat and positions between the phones of one hiking group, with no
/// internet (Bluetooth and Wi-Fi between phones, messages hop through teammates).
class GroupPane extends StatefulWidget {
  const GroupPane({super.key});

  @override
  State<GroupPane> createState() => _GroupPaneState();
}

class _GroupPaneState extends State<GroupPane> {
  final _input = TextEditingController();

  @override
  void initState() {
    super.initState();
    mesh.addListener(_changed);
  }

  @override
  void dispose() {
    mesh.removeListener(_changed);
    _input.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _create() async {
    final name = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr(context, 'grp.create')),
        content: TextField(
          controller: name,
          maxLength: 40,
          decoration: InputDecoration(labelText: tr(context, 'grp.name'), hintText: tr(context, 'grp.name.hint')),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr(context, 'chat.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr(context, 'grp.create'))),
        ],
      ),
    );
    if (ok == true) await mesh.create(name.text);
  }

  Future<void> _join() async {
    final code = TextEditingController(), name = TextEditingController();
    String? error;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Text(tr(context, 'grp.join')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: code,
                  textCapitalization: TextCapitalization.characters,
                  decoration: InputDecoration(labelText: tr(context, 'grp.code'), hintText: 'ABCDE-23456', errorText: error),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () async {
                      final invite = await Navigator.push<GroupInvite>(context, MaterialPageRoute(builder: (_) => const QrScanScreen()));
                      if (invite == null) return;
                      code.text = MeshProtocol.prettyCode(invite.code);
                      if (invite.name.isNotEmpty) name.text = invite.name;
                      setLocal(() => error = null);
                    },
                    icon: const Icon(Icons.qr_code_scanner),
                    label: Text(tr(context, 'grp.qr.scan')),
                  ),
                ),
                const SizedBox(height: 4),
                TextField(
                  controller: name,
                  maxLength: 40,
                  decoration: InputDecoration(labelText: tr(context, 'grp.name')),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr(context, 'chat.cancel'))),
            FilledButton(
              onPressed: () {
                if (MeshProtocol.normalizeCode(code.text) == null) {
                  setLocal(() => error = tr(context, 'grp.code.bad'));
                } else {
                  Navigator.pop(context, true);
                }
              },
              child: Text(tr(context, 'grp.join')),
            ),
          ],
        ),
      ),
    );
    if (ok == true) await mesh.join(code.text, name.text);
  }

  Future<void> _leave() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(tr(context, 'grp.leave.confirm')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr(context, 'chat.cancel'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: RS.err),
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr(context, 'grp.leave')),
          ),
        ],
      ),
    );
    if (ok == true) await mesh.leave();
  }

  Future<void> _showQr(MeshGroup g) async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(g.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 240,
              height: 240,
              child: QrImageView(data: GroupInvite(g.code, g.name).encode(), backgroundColor: Colors.white, padding: const EdgeInsets.all(12)),
            ),
            const SizedBox(height: 8),
            Text(
              MeshProtocol.prettyCode(g.code),
              style: const TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1.5, fontSize: 18, color: RS.z9),
            ),
            const SizedBox(height: 8),
            Text(
              tr(context, 'grp.qr.lead'),
              textAlign: TextAlign.center,
              style: const TextStyle(color: RS.muted, height: 1.4),
            ),
          ],
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(tr(context, 'grp.close')))],
      ),
    );
  }

  Future<void> _editPin() async {
    final text = TextEditingController(text: '${mesh.pinned?.body['text'] ?? ''}');
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr(context, 'grp.pin.set')),
        content: TextField(
          controller: text,
          maxLength: 200,
          minLines: 1,
          maxLines: 4,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(hintText: tr(context, 'grp.pin.hint')),
        ),
        actions: [
          if (mesh.pinned != null) TextButton(onPressed: () => Navigator.pop(context, ''), child: Text(tr(context, 'grp.pin.clear'))),
          TextButton(onPressed: () => Navigator.pop(context), child: Text(tr(context, 'chat.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(context, text.text), child: Text(tr(context, 'grp.pin.save'))),
        ],
      ),
    );
    if (result != null) await mesh.setPinned(result);
  }

  Future<void> _actions() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ListTile(
                leading: const Icon(Icons.my_location, color: RS.z7),
                title: Text(tr(context, 'grp.loc.send')),
                onTap: () => Navigator.pop(context, 'loc'),
              ),
              ListTile(
                leading: const Icon(Icons.timeline, color: RS.z7),
                title: Text(tr(context, 'grp.track.send')),
                onTap: () => Navigator.pop(context, 'track'),
              ),
              ListTile(
                leading: const Icon(Icons.push_pin_outlined, color: RS.z7),
                title: Text(tr(context, 'grp.pin.set')),
                onTap: () => Navigator.pop(context, 'pin'),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text(tr(context, 'grp.mark'), style: RS.head(20, color: RS.z9)),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(tr(context, 'grp.mark.lead'), style: const TextStyle(color: RS.muted, fontSize: 13)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final e in waypointKinds.entries)
                      if (e.key != 'other')
                        ActionChip(
                          avatar: Icon(e.value, size: 18, color: e.key == 'danger' || e.key == 'cliff' ? RS.err : RS.z7),
                          label: Text(tr(context, 'wpt.${e.key}')),
                          onPressed: () => Navigator.pop(context, 'mark:${e.key}'),
                        ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text(tr(context, 'grp.ping'), style: RS.head(20, color: RS.z9)),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(tr(context, 'grp.ping.lead'), style: const TextStyle(color: RS.muted, fontSize: 13)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final k in ['grp.ping.gather', 'grp.ping.wait', 'grp.ping.rest', 'grp.ping.go'])
                      ActionChip(
                        avatar: const Icon(Icons.campaign_outlined, size: 18, color: RS.z7),
                        label: Text(tr(context, k)),
                        onPressed: () => Navigator.pop(context, 'ping:${tr(context, k)}'),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'loc') {
      final ok = await mesh.shareLocation();
      if (!ok && mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr(context, 'grp.loc.none'))));
    } else if (choice.startsWith('mark:')) {
      final kind = choice.substring(5);
      final ok = await mesh.markHere(kind, tr(context, 'wpt.$kind'));
      if (!ok && mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr(context, 'grp.loc.none'))));
    } else if (choice == 'track') {
      await _sendTrack();
    } else if (choice == 'pin') {
      await _editPin();
    } else if (choice.startsWith('ping:')) {
      await mesh.sendPing(choice.substring(5));
    }
  }

  /// The track being recorded now, or a saved recording picked from a list.
  Future<void> _sendTrack() async {
    final live = liveTrack();
    if (live.length >= 2) {
      await mesh.shareTrack(tr(context, 'grp.track.live'), [
        for (final p in live) [p.latitude, p.longitude],
      ]);
      return;
    }
    final saved = await RecordingStore.all();
    if (!mounted) return;
    if (saved.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr(context, 'grp.track.none'))));
      return;
    }
    final pick = await showModalBottomSheet<Recording>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(tr(context, 'grp.track.pick'), style: RS.head(20, color: RS.z9)),
            ),
            for (final r in saved.take(20))
              ListTile(
                leading: const Icon(Icons.timeline, color: RS.z7),
                title: Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text('${fmtNum(context, r.distanceKm, 2)} km'),
                onTap: () => Navigator.pop(context, r),
              ),
          ],
        ),
      ),
    );
    if (pick == null) return;
    await mesh.shareTrack(pick.name, [
      for (final p in pick.points) [p.lat, p.lng],
    ]);
  }

  Future<void> _send() async {
    final t = _input.text.trim();
    if (t.isEmpty) return;
    _input.clear();
    await mesh.sendChat(t);
  }

  @override
  Widget build(BuildContext context) {
    if (!mesh.loaded) return const Center(child: LoadingView());
    return mesh.inGroup ? _inGroup(context) : _intro(context);
  }

  Widget _intro(BuildContext context) {
    return ListView(
      padding: pageGutter(context, top: 16, bottom: 24),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tr(context, 'grp.title').toUpperCase(), style: RS.head(28, color: RS.z9)),
                const SizedBox(height: 8),
                Text(tr(context, 'grp.lead'), style: const TextStyle(height: 1.45, fontSize: 15)),
                const SizedBox(height: 10),
                for (final k in ['grp.how.1', 'grp.how.2', 'grp.how.3'])
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Padding(
                          padding: EdgeInsets.only(top: 3),
                          child: Icon(Icons.change_history, size: 14, color: RS.z7),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(tr(context, k), style: const TextStyle(height: 1.4, color: RS.ink)),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        SignButton(label: tr(context, 'grp.create'), onPressed: _create),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: _join,
          style: OutlinedButton.styleFrom(backgroundColor: Colors.white),
          icon: const Icon(Icons.group_add_outlined),
          label: Text(tr(context, 'grp.join')),
        ),
        const SizedBox(height: 12),
        Text(tr(context, 'grp.limits'), style: const TextStyle(fontSize: 12.5, color: RS.muted, height: 1.4)),
      ],
    );
  }

  Widget _inGroup(BuildContext context) {
    final g = mesh.group!;
    final me = mesh.myId;
    final others = mesh.members.values.where((m) => m.id != me).toList()..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
    final msgs = mesh.chat.reversed.toList();
    return Column(
      children: [
        Material(
          color: Colors.white,
          child: Container(
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: RS.line)),
            ),
            padding: const EdgeInsets.fromLTRB(16, 10, 8, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            g.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: RS.head(24, color: RS.z9),
                          ),
                          Semantics(
                            button: true,
                            label: tr(context, 'grp.code.share'),
                            child: InkWell(
                              onTap: () => _shareCode(g),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(vertical: 4),
                                child: Text(
                                  '${tr(context, 'grp.code')}: ${MeshProtocol.prettyCode(g.code)}',
                                  style: const TextStyle(fontWeight: FontWeight.w700, letterSpacing: 1, color: RS.z7, decoration: TextDecoration.underline),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Switch(value: mesh.running, activeThumbColor: RS.z7, onChanged: mesh.starting ? null : (v) => v ? mesh.start() : mesh.stop()),
                    PopupMenuButton<String>(
                      tooltip: tr(context, 'grp.more'),
                      onSelected: (v) {
                        if (v == 'share') _shareCode(g);
                        if (v == 'qr') _showQr(g);
                        if (v == 'pin') _editPin();
                        if (v == 'leave') _leave();
                      },
                      itemBuilder: (context) => [
                        PopupMenuItem(value: 'qr', child: Text(tr(context, 'grp.qr'))),
                        PopupMenuItem(value: 'share', child: Text(tr(context, 'grp.code.share'))),
                        PopupMenuItem(value: 'pin', child: Text(tr(context, 'grp.pin.set'))),
                        PopupMenuItem(
                          value: 'leave',
                          child: Text(tr(context, 'grp.leave'), style: const TextStyle(color: RS.err)),
                        ),
                      ],
                    ),
                  ],
                ),
                Text(
                  mesh.starting
                      ? tr(context, 'grp.starting')
                      : !mesh.running
                      ? tr(context, 'grp.off')
                      : mesh.peers == 0
                      ? tr(context, 'grp.searching')
                      : tr(context, 'grp.connected', {'n': mesh.peers}),
                  style: TextStyle(fontSize: 13, color: mesh.running && mesh.peers > 0 ? RS.z7 : RS.muted, fontWeight: FontWeight.w600),
                ),
                if (mesh.problem != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(tr(context, mesh.problem!), style: const TextStyle(color: RS.err, fontSize: 13)),
                  ),
                if (others.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 40,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        for (final m in others)
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: _MemberChip(member: m),
                          ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (mesh.pinned != null)
          Material(
            color: const Color(0xFFECFDF5),
            child: InkWell(
              onTap: _editPin,
              child: Container(
                width: double.infinity,
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: RS.line)),
                ),
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 2),
                      child: Icon(Icons.push_pin, size: 16, color: RS.z7),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: '${tr(context, 'grp.pin')} · ${mesh.pinned!.name}: ',
                              style: const TextStyle(fontWeight: FontWeight.w700, color: RS.z7),
                            ),
                            TextSpan(text: '${mesh.pinned!.body['text'] ?? ''}'),
                          ],
                        ),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 14, height: 1.35, color: RS.ink),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        Expanded(
          child: msgs.isEmpty
              ? SingleChildScrollView(
                  child: MessageView(title: tr(context, 'grp.empty'), icon: Icons.forum_outlined),
                )
              : ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                  itemCount: msgs.length,
                  itemBuilder: (context, i) => _GroupBubble(message: msgs[i], mine: msgs[i].from == me),
                ),
        ),
        Material(
          color: Colors.white,
          child: Container(
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: RS.line)),
            ),
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _SosButton(active: mesh.mySos, enabled: mesh.running, onFire: () => mesh.setSos(!mesh.mySos)),
                SizedBox(
                  width: 48,
                  height: 52,
                  child: IconButton(
                    tooltip: tr(context, 'grp.actions'),
                    onPressed: mesh.running ? _actions : null,
                    icon: const Icon(Icons.add_circle_outline, color: RS.z7),
                  ),
                ),
                Expanded(
                  child: TextField(
                    controller: _input,
                    enabled: mesh.running,
                    minLines: 1,
                    maxLines: 4,
                    maxLength: MeshProtocol.maxTextLength,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(hintText: tr(context, mesh.running ? 'chat.input' : 'grp.off.short'), counterText: ''),
                  ),
                ),
                const SizedBox(width: 6),
                SizedBox(
                  width: 52,
                  height: 52,
                  child: IconButton.filled(
                    tooltip: tr(context, 'chat.send'),
                    style: IconButton.styleFrom(
                      backgroundColor: RS.z7,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    onPressed: mesh.running ? _send : null,
                    icon: const Icon(Icons.send),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _shareCode(MeshGroup g) async {
    await Clipboard.setData(ClipboardData(text: g.code));
    if (!mounted) return;
    await SharePlus.instance.share(ShareParams(text: tr(context, 'grp.code.message', {'name': g.name, 'code': MeshProtocol.prettyCode(g.code)})));
  }
}

class _MemberChip extends StatelessWidget {
  const _MemberChip({required this.member});

  final MeshMember member;

  @override
  Widget build(BuildContext context) {
    final d = mesh.distanceTo(member);
    final ago = DateTime.now().difference(member.lastSeen);
    final fresh = ago.inMinutes < 5;
    final sos = mesh.sos.containsKey(member.id);
    final text = [
      member.name,
      if (d != null) '${fmtNum(context, d)} m',
      if (!fresh) tr(context, 'grp.ago', {'m': ago.inMinutes}),
    ].join(' · ');
    final bat = member.battery;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: sos ? const Color(0xFFFEF2F2) : (fresh ? const Color(0xFFECFDF5) : RS.paper),
        border: Border.all(color: sos ? RS.err : (fresh ? RS.z7 : RS.line)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(sos ? Icons.sos : Icons.circle, size: sos ? 16 : 12, color: sos ? RS.err : (fresh ? mesh.colorOf(member.id) : RS.muted)),
          const SizedBox(width: 4),
          Text(text, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          if (bat != null) ...[
            const SizedBox(width: 6),
            Semantics(
              label: tr(context, 'grp.battery', {'n': bat}),
              excludeSemantics: true,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(bat <= 20 ? Icons.battery_alert : Icons.battery_std, size: 15, color: bat <= 20 ? RS.err : RS.muted),
                  Text(
                    '$bat%',
                    style: TextStyle(fontSize: 12.5, color: bat <= 20 ? RS.err : RS.muted, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _GroupBubble extends StatelessWidget {
  const _GroupBubble({required this.message, required this.mine});

  final MeshMessage message;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    final t = message.time;
    final clock = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    final via = message.hops > 0 ? ' · ${tr(context, 'grp.via', {'n': message.hops})}' : '';
    final text = '${message.body['text'] ?? ''}';
    if (message.type == MeshType.ping) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFFECFDF5),
              border: Border.all(color: RS.z7),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.campaign, size: 18, color: RS.z7),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    '${tr(context, 'grp.ping.in', {'name': message.name})}: $text · $clock',
                    style: const TextStyle(fontWeight: FontWeight.w700, color: RS.z9, height: 1.3),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    final rawLat = message.body['lat'], rawLng = message.body['lng'];
    final lat = rawLat is num ? rawLat.toDouble() : null, lng = rawLng is num ? rawLng.toDouble() : null;
    final place = lat != null && lng != null && lat.abs() <= 90 && lng.abs() <= 180 ? LatLng(lat, lng) : null;
    final kind = message.body['kind'] is String ? message.body['kind'] as String : null;
    final track = sharedTrack(message.body['track']);
    final warn = kind == 'danger' || kind == 'cliff';
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.8),
        margin: const EdgeInsets.only(top: 6),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
        decoration: BoxDecoration(
          color: mine ? RS.z7 : Colors.white,
          border: mine ? null : Border.all(color: RS.line),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(12),
            topRight: const Radius.circular(12),
            bottomLeft: Radius.circular(mine ? 12 : 4),
            bottomRight: Radius.circular(mine ? 4 : 12),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!mine)
              Text(
                message.name,
                style: const TextStyle(color: RS.z7, fontWeight: FontWeight.w700, fontSize: 13),
              ),
            if (place != null)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(waypointKinds[kind] ?? Icons.place, size: 18, color: mine ? Colors.white : (warn ? RS.err : RS.z7)),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      text.isNotEmpty ? text : tr(context, 'grp.loc.msg'),
                      style: TextStyle(color: mine ? Colors.white : RS.ink, fontSize: 15, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              )
            else if (track != null) ...[
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.timeline, size: 18, color: mine ? Colors.white : RS.z7),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      text.isNotEmpty ? text : tr(context, 'grp.track.msg'),
                      style: TextStyle(color: mine ? Colors.white : RS.ink, fontSize: 15, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(
                  width: 200,
                  height: 90,
                  child: TrackThumb(
                    track: [
                      for (final p in track) [p.latitude, p.longitude],
                    ],
                    height: 90,
                  ),
                ),
              ),
              TextButton.icon(
                style: TextButton.styleFrom(
                  foregroundColor: mine ? Colors.white : RS.z7,
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(0, 40),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => SharedTrackScreen(title: text.isNotEmpty ? text : tr(context, 'grp.track.msg'), from: message.name, track: track),
                  ),
                ),
                icon: const Icon(Icons.map_outlined, size: 18),
                label: Text(tr(context, 'grp.sos.show')),
              ),
            ] else
              Text(text, style: TextStyle(color: mine ? Colors.white : RS.ink, fontSize: 15, height: 1.35)),
            if (place != null)
              TextButton.icon(
                style: TextButton.styleFrom(
                  foregroundColor: mine ? Colors.white : RS.z7,
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(0, 40),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: () {
                  mapFocus.value = place;
                  Shell.globalKey.currentState?.open(Tabs.record);
                },
                icon: const Icon(Icons.map_outlined, size: 18),
                label: Text(tr(context, 'grp.sos.show')),
              ),
            Text('$clock$via', style: TextStyle(fontSize: 11.5, color: mine ? const Color(0xFFD1FAE5) : RS.muted)),
          ],
        ),
      ),
    );
  }
}

/// Valid points of a track sent by a teammate (at most a few hundred), or null.
List<LatLng>? sharedTrack(Object? raw) {
  if (raw is! List) return null;
  final out = <LatLng>[];
  for (final p in raw.take(400)) {
    if (p is List && p.length >= 2 && p[0] is num && p[1] is num) {
      final lat = (p[0] as num).toDouble(), lng = (p[1] as num).toDouble();
      if (lat.isFinite && lng.isFinite && lat.abs() <= 90 && lng.abs() <= 180) out.add(LatLng(lat, lng));
    }
  }
  return out.length >= 2 ? out : null;
}

/// A teammate's shared track on a full map.
class SharedTrackScreen extends StatelessWidget {
  const SharedTrackScreen({super.key, required this.title, required this.from, required this.track});

  final String title, from;
  final List<LatLng> track;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: RS.z9,
        foregroundColor: Colors.white,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: RS.head(22, color: Colors.white),
            ),
            Text(from, style: const TextStyle(fontSize: 12.5, color: RS.onDarkSoft)),
          ],
        ),
      ),
      body: FlutterMap(
        options: MapOptions(
          initialCameraFit: CameraFit.coordinates(coordinates: track, padding: const EdgeInsets.all(36), maxZoom: 17),
          interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
          backgroundColor: RS.mist,
        ),
        children: [
          TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'id.ai.rutestrip.app', maxZoom: 19),
          PolylineLayer(
            polylines: [
              Polyline(points: track, strokeWidth: 7, color: Colors.white),
              Polyline(points: track, strokeWidth: 4, color: mesh.colorOf('track:$from')),
            ],
          ),
          MarkerLayer(
            markers: [
              Marker(
                point: track.first,
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
              Marker(
                point: track.last,
                width: 22,
                height: 22,
                child: Container(
                  decoration: BoxDecoration(
                    color: RS.err,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 3),
                  ),
                ),
              ),
            ],
          ),
          const OsmAttribution(),
        ],
      ),
    );
  }
}

/// SOS needs a 2-second hold, so it is not sent by a bump in a pocket. Tap again to end it.
class _SosButton extends StatefulWidget {
  const _SosButton({required this.active, required this.enabled, required this.onFire});

  final bool active, enabled;
  final VoidCallback onFire;

  @override
  State<_SosButton> createState() => _SosButtonState();
}

class _SosButtonState extends State<_SosButton> with SingleTickerProviderStateMixin {
  late final AnimationController _hold = AnimationController(vsync: this, duration: const Duration(seconds: 2))
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed) {
        HapticFeedback.heavyImpact();
        widget.onFire();
        _hold.reset();
      }
    });

  @override
  void dispose() {
    _hold.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final label = tr(context, widget.active ? 'grp.sos.stop' : 'grp.sos.hold');
    return Semantics(
      button: true,
      label: label,
      child: Tooltip(
        message: label,
        child: Listener(
          // Raw touches: a held finger is never turned into a scroll or a cancelled tap.
          onPointerDown: (_) {
            if (!widget.enabled) return;
            if (widget.active) {
              widget.onFire(); // ending an SOS is one tap
            } else {
              _hold.forward();
            }
          },
          onPointerUp: (_) => _hold.reverse(),
          onPointerCancel: (_) => _hold.reverse(),
          child: AnimatedBuilder(
            animation: _hold,
            builder: (context, _) => Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: widget.active ? RS.err : Colors.white,
                border: Border.all(color: widget.enabled ? RS.err : RS.line, width: 2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  if (_hold.value > 0)
                    SizedBox(
                      width: 40,
                      height: 40,
                      child: CircularProgressIndicator(value: _hold.value, strokeWidth: 3, color: RS.err),
                    ),
                  Text(
                    'SOS',
                    style: TextStyle(fontWeight: FontWeight.w900, fontSize: 14, color: widget.active ? Colors.white : (widget.enabled ? RS.err : RS.muted)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Red banner over every screen while a teammate's SOS is active.
class SosBanner extends StatelessWidget {
  const SosBanner({super.key, required this.onShow});

  final void Function(MeshMember member) onShow;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: mesh,
      builder: (context, _) {
        if (mesh.sos.isEmpty) return const SizedBox.shrink();
        final entry = mesh.sos.entries.first;
        final member = mesh.members[entry.key];
        final d = member == null ? null : mesh.distanceTo(member);
        return Material(
          color: RS.err,
          child: SafeArea(
            bottom: false,
            child: Semantics(
              liveRegion: true,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                child: Row(
                  children: [
                    const Icon(Icons.sos, color: Colors.white),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        tr(context, 'grp.sos.in', {'name': entry.value.name, 'd': d == null ? '' : ' (${fmtNum(context, d)} m)'}),
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, height: 1.3),
                      ),
                    ),
                    if (member != null && member.hasPosition)
                      TextButton(
                        style: TextButton.styleFrom(foregroundColor: Colors.white),
                        onPressed: () => onShow(member),
                        child: Text(tr(context, 'grp.sos.show')),
                      ),
                    IconButton(
                      tooltip: tr(context, 'grp.siren.off'),
                      onPressed: Notify.instance.stopSiren,
                      icon: const Icon(Icons.volume_off, color: Colors.white),
                    ),
                    IconButton(
                      tooltip: tr(context, 'grp.sos.dismiss'),
                      onPressed: () => mesh.dismissSos(entry.key),
                      icon: const Icon(Icons.close, color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Keeps the mesh name in step with the account (called from the app shell).
void syncMeshName(BuildContext context) {
  final user = AppScope.read(context).user;
  if (user != null) mesh.setName(user.name);
}
