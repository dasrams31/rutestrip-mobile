import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';

import 'package:battery_plus/battery_plus.dart';

import '../i18n.dart';
import '../location_hub.dart';
import '../notify.dart';
import '../recording_math.dart';
import 'mesh_node.dart';
import 'mesh_protocol.dart';
import 'nearby_transport.dart';

/// A group member as last heard.
class MeshMember {
  MeshMember(this.id, this.name);

  final String id;
  String name;
  DateTime lastSeen = DateTime.fromMillisecondsSinceEpoch(0);
  double? lat, lng, accuracy;
  DateTime? posTime;
  int hops = 0;

  /// Phone battery in percent, as last reported with a position.
  int? battery;

  /// Walking direction in degrees from north (only while moving).
  double? heading;

  /// The last few positions, oldest first (drawn as a dotted trail on the map).
  final trail = <List<double>>[];
  static const trailMax = 10;

  bool get hasPosition => lat != null && lng != null;
}

/// The "Rombongan" feature for the whole app: one group at a time, its radios,
/// members, chat history, positions and SOS. Lives outside the screens so it keeps
/// working while the hiker switches tabs or records.
class MeshService extends ChangeNotifier {
  MeshService({MeshTransport Function()? transport, FlutterSecureStorage? storage})
    : _transportFactory = transport ?? NearbyTransport.new,
      _secure = storage ?? const FlutterSecureStorage();

  final MeshTransport Function() _transportFactory;
  final FlutterSecureStorage _secure;

  static const _chatKeep = 200;
  static const posEvery = Duration(seconds: 30);
  static const posMinMove = 25.0; // metres

  /// A teammate further than this is shown as separated on the Rekam map.
  static const separatedM = 300.0;

  MeshGroup? group;
  MeshIdentity? identity;
  MeshNode? _node;
  StreamSubscription<MeshMessage>? _msgSub;
  StreamSubscription<(String, bool)>? _peerSub;
  StreamSubscription<Position>? _posSub;
  String _name = 'Pendaki';
  bool loaded = false, running = false, starting = false;
  String? problem; // i18n key
  final members = <String, MeshMember>{};
  final chat = <MeshMessage>[];
  int peers = 0;

  /// Teammates with an active SOS (latest per member).
  final sos = <String, MeshMessage>{};
  bool mySos = false;

  /// The group's pinned note (latest), shown above the chat.
  MeshMessage? pinned;

  final _pingAt = <String, DateTime>{};

  static double? _num(Object? v) => v is num && v.isFinite ? v.toDouble() : null;

  /// One colour per teammate, in the order they were first seen (stable while the
  /// group runs). Red stays for SOS and blue for "you" on the map.
  static const teamPalette = [
    Color(0xFF7C3AED), // violet
    Color(0xFFC2410C), // orange
    Color(0xFF0E7490), // cyan
    Color(0xFFBE185D), // pink
    Color(0xFF4D7C0F), // olive
    Color(0xFF92400E), // brown
    Color(0xFF4338CA), // indigo
    Color(0xFF0F766E), // teal
    Color(0xFFA16207), // amber
    Color(0xFF334155), // slate
  ];

  final _colorIndex = <String, int>{};

  Color colorOf(String memberId) {
    final i = _colorIndex.putIfAbsent(memberId, () => _colorIndex.length);
    return teamPalette[i % teamPalette.length];
  }

  Position? myPosition;
  DateTime _posSentAt = DateTime.fromMillisecondsSinceEpoch(0);
  Position? _posSent;

  bool get inGroup => group != null;
  String? get myId => identity?.nodeId;

  /// Loads the identity and the last group (radios stay off until the hiker turns them on,
  /// unless they were on when the app closed).
  Future<void> load(String displayName) async {
    if (loaded) return;
    _name = displayName;
    try {
      var seed = await _secure.read(key: 'mesh_seed');
      if (seed == null) {
        seed = base64.encode(MeshIdentity.newSeed());
        await _secure.write(key: 'mesh_seed', value: seed);
      }
      identity = await MeshIdentity.fromSeed(base64.decode(seed));
      final saved = await _secure.read(key: 'mesh_group');
      if (saved != null) {
        final j = jsonDecode(saved) as Map;
        group = await MeshGroup.open('${j['code']}', '${j['name']}');
        await _loadChat();
        loaded = true;
        notifyListeners();
        if (j['on'] == true) await start();
        return;
      }
    } catch (_) {
      // Unreadable storage: start without a group.
    }
    loaded = true;
    notifyListeners();
  }

  void setName(String name) {
    _name = name;
    _node?.name = name;
  }

  Future<String> create(String name) async {
    final code = MeshProtocol.newCode();
    await _join(code, name.trim().isEmpty ? 'Rombongan' : name.trim());
    return code;
  }

  /// False when the code is not valid.
  Future<bool> join(String code, String name) async {
    final c = MeshProtocol.normalizeCode(code);
    if (c == null) return false;
    await _join(c, name.trim().isEmpty ? 'Rombongan' : name.trim());
    return true;
  }

  Future<void> _join(String code, String name) async {
    await stop();
    group = await MeshGroup.open(code, name);
    members.clear();
    chat.clear();
    sos.clear();
    mySos = false;
    await _loadChat();
    await _saveGroup(on: false);
    notifyListeners();
    await start();
  }

  Future<void> leave() async {
    await stop();
    final g = group;
    group = null;
    members.clear();
    chat.clear();
    sos.clear();
    pinned = null;
    mySos = false;
    await Notify.instance.stopSiren();
    await _secure.delete(key: 'mesh_group');
    if (g != null) {
      final f = await _chatFile(g);
      if (await f.exists()) await f.delete();
    }
    notifyListeners();
  }

  /// Turns the radios on: Bluetooth/Wi-Fi to find the group, and position sharing.
  Future<void> start() async {
    final g = group, id = identity;
    if (g == null || id == null || running || starting) return;
    starting = true;
    problem = null;
    notifyListeners();
    try {
      if (!await NearbyTransport.ensurePermissions()) {
        problem = 'grp.permission';
        return;
      }
      final t = _transportFactory();
      final node = MeshNode(codec: MeshCodec(g, id), transport: t, name: _name);
      _msgSub = node.messages.listen(_onMessage);
      _peerSub = t.peers.listen((_) {
        peers = t.connected.length;
        notifyListeners();
      });
      await node.start();
      _node = node;
      running = true;
      await _saveGroup(on: true);
      await node.send(MeshType.hello, {});
      _startPositions();
    } catch (e) {
      if (kDebugMode) debugPrint('RuteStrip mesh start failed: $e');
      problem = 'grp.radio';
      await _teardown();
    } finally {
      starting = false;
      notifyListeners();
    }
  }

  /// Turns the radios off (the group and its chat stay on the phone).
  Future<void> stop() async {
    await _teardown();
    if (group != null) await _saveGroup(on: false);
    notifyListeners();
  }

  Future<void> _teardown() async {
    await _posSub?.cancel();
    _posSub = null;
    LocationHub.instance.release(this);
    await _msgSub?.cancel();
    _msgSub = null;
    await _peerSub?.cancel();
    _peerSub = null;
    await _node?.stop();
    _node = null;
    running = false;
    peers = 0;
  }

  Future<void> sendChat(String text) async {
    final t = text.trim();
    if (t.isEmpty || _node == null) return;
    final m = await _node!.send(MeshType.chat, {'text': t.length > MeshProtocol.maxTextLength ? t.substring(0, MeshProtocol.maxTextLength) : t});
    _addChat(m);
    notifyListeners();
  }

  /// Sends where this phone is now into the chat (with a "show on map" button).
  Future<bool> shareLocation({String? label}) async {
    if (_node == null) return false;
    final p = myPosition ?? await _currentPosition();
    if (p == null) return false;
    final m = await _node!.send(MeshType.chat, {'text': label ?? '', 'lat': p.latitude, 'lng': p.longitude, 'acc': p.accuracy});
    _addChat(m);
    notifyListeners();
    return true;
  }

  /// A marked spot from Rekam (water, pos, camp...) shared with the group.
  Future<void> shareSpot(String label, double lat, double lng, {String? kind}) async {
    if (_node == null) return;
    final m = await _node!.send(MeshType.chat, {'text': label, 'lat': lat, 'lng': lng, 'kind': ?kind});
    _addChat(m);
    notifyListeners();
  }

  /// Marks where this phone is now as a kind of spot (pos, water, cliff, danger...).
  Future<bool> markHere(String kind, String label) async {
    if (_node == null) return false;
    final p = myPosition ?? await _currentPosition();
    if (p == null) return false;
    await shareSpot(label, p.latitude, p.longitude, kind: kind);
    return true;
  }

  /// Most points a shared track keeps (a packet must stay well under 8 KB).
  static const trackMax = 120;

  /// Sends a recorded track (thinned to [trackMax] points) into the group chat.
  Future<bool> shareTrack(String name, List<List<double>> points) async {
    if (_node == null || points.length < 2) return false;
    final step = (points.length / trackMax).ceil().clamp(1, 1 << 20);
    final thin = [
      for (var i = 0; i < points.length; i += step) [_round5(points[i][0]), _round5(points[i][1])],
    ];
    if (thin.last[0] != _round5(points.last[0]) || thin.last[1] != _round5(points.last[1])) thin.add([_round5(points.last[0]), _round5(points.last[1])]);
    final m = await _node!.send(MeshType.chat, {'text': name.length > 80 ? name.substring(0, 80) : name, 'track': thin});
    _addChat(m);
    notifyListeners();
    return true;
  }

  static double _round5(double v) => (v * 100000).roundToDouble() / 100000;

  /// Team call: buzz and a short siren on every phone ("Kumpul!", "Tunggu!").
  Future<void> sendPing(String text) async {
    if (_node == null) return;
    final m = await _node!.send(MeshType.ping, {'text': text.trim().length > 120 ? text.trim().substring(0, 120) : text.trim()});
    _addChat(m);
    notifyListeners();
  }

  /// Pins a note for everyone (empty text removes it).
  Future<void> setPinned(String text) async {
    if (_node == null) return;
    final t = text.trim();
    final m = await _node!.send(MeshType.pin, {'text': t.length > 200 ? t.substring(0, 200) : t});
    pinned = t.isEmpty ? null : m;
    notifyListeners();
  }

  /// Starts or ends this phone's SOS; the position goes with it.
  Future<void> setSos(bool active) async {
    if (_node == null) return;
    final p = myPosition ?? await _currentPosition();
    await _node!.send(MeshType.sos, {'active': active, 'lat': ?p?.latitude, 'lng': ?p?.longitude, 'acc': ?p?.accuracy});
    mySos = active;
    notifyListeners();
  }

  void dismissSos(String memberId) {
    sos.remove(memberId);
    if (sos.isEmpty) Notify.instance.stopSiren();
    notifyListeners();
  }

  // ---------------------------------------------------------------------------

  void _onMessage(MeshMessage m) {
    final member = members.putIfAbsent(m.from, () => MeshMember(m.from, m.name));
    member
      ..name = m.name
      ..hops = m.hops;
    if (m.time.isAfter(member.lastSeen)) member.lastSeen = m.time;
    final lang = Notify.instance.lang;
    final text = '${m.body['text'] ?? ''}';
    // Messages carried for a while by other phones arrive late: no sound for old news.
    final recent = DateTime.now().difference(m.time) < const Duration(minutes: 10);
    switch (m.type) {
      case MeshType.chat:
        _addChat(m);
        if (recent) Notify.instance.groupMessage('${m.name} · ${group?.name ?? ''}', text.isNotEmpty ? text : trLang(lang, 'grp.loc.msg'));
      case MeshType.pos:
        _takePosition(member, m);
      case MeshType.sos:
        _takePosition(member, m);
        if (m.body['active'] == true) {
          final isNew = !sos.containsKey(m.from);
          sos[m.from] = m;
          if (isNew) {
            _alarm();
            Notify.instance.sos(trLang(lang, 'grp.sos.in', {'name': m.name, 'd': ''}), trLang(lang, 'notif.sos.body'));
          }
        } else {
          sos.remove(m.from);
          if (sos.isEmpty) Notify.instance.stopSiren();
        }
      case MeshType.ping:
        _addChat(m);
        // At most one buzz and siren per teammate every 30 seconds.
        final last = _pingAt[m.from];
        if (recent && (last == null || DateTime.now().difference(last) > const Duration(seconds: 30))) {
          _pingAt[m.from] = DateTime.now();
          _alarm();
          Notify.instance.ping(trLang(lang, 'grp.ping.in', {'name': m.name}), text);
        }
      case MeshType.pin:
        if (pinned == null || !m.time.isBefore(pinned!.time)) pinned = text.isEmpty ? null : m;
      case MeshType.hello:
        break;
    }
    notifyListeners();
  }

  void _takePosition(MeshMember member, MeshMessage m) {
    final lat = _num(m.body['lat']), lng = _num(m.body['lng']);
    if (lat == null || lng == null || lat.abs() > 90 || lng.abs() > 180) return;
    if (member.posTime != null && !m.time.isAfter(member.posTime!)) return; // an older position relayed late
    member
      ..lat = lat
      ..lng = lng
      ..accuracy = _num(m.body['acc'])
      ..battery = _num(m.body['bat'])?.round().clamp(0, 100) ?? member.battery
      ..heading = _num(m.body['hdg'])
      ..posTime = m.time;
    member.trail.add([lat, lng]);
    if (member.trail.length > MeshMember.trailMax) member.trail.removeAt(0);
  }

  Future<void> _alarm() async {
    for (var i = 0; i < 6; i++) {
      await HapticFeedback.vibrate();
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
  }

  void _addChat(MeshMessage m) {
    if (chat.any((x) => x.id == m.id)) return;
    chat
      ..add(m)
      ..sort((a, b) => a.time.compareTo(b.time));
    if (chat.length > _chatKeep) chat.removeRange(0, chat.length - _chatKeep);
    _saveChat();
  }

  Future<Position?> _currentPosition() async {
    try {
      return await Geolocator.getLastKnownPosition(forceAndroidLocationManager: true);
    } catch (_) {
      return null;
    }
  }

  void _startPositions() {
    _posSub?.cancel();
    // The app's one GPS stream; the group need keeps a foreground service ("Rombongan aktif")
    // so messages and SOS still arrive with the screen off.
    LocationHub.instance
      ..groupName = group?.name ?? ''
      ..require(this, LocNeed.group);
    _posSub = LocationHub.instance.positions.listen((p) {
      myPosition = p;
      notifyListeners();
      final prev = _posSent;
      final moved = prev == null ? double.infinity : distanceM(prev.latitude, prev.longitude, p.latitude, p.longitude);
      final since = DateTime.now().difference(_posSentAt);
      // Every 30 s when walking (25 m or more), at least every 3 minutes when resting.
      if (p.accuracy <= 50 && ((moved >= posMinMove && since >= posEvery) || since >= const Duration(minutes: 3))) {
        _posSent = p;
        _posSentAt = DateTime.now();
        _sendPos(p);
      }
    }, onError: (_) {});
  }

  Future<void> _sendPos(Position p) async {
    int? bat;
    try {
      bat = await Battery().batteryLevel;
    } catch (_) {}
    final moving = p.speed > 0.5 && p.heading >= 0;
    await _node?.send(MeshType.pos, {'lat': p.latitude, 'lng': p.longitude, 'acc': p.accuracy, 'bat': ?bat, if (moving) 'hdg': p.heading.roundToDouble()});
  }

  /// Distance from this phone to a member (metres), when both positions are known.
  double? distanceTo(MeshMember m) {
    final me = myPosition;
    if (me == null || !m.hasPosition) return null;
    return distanceM(me.latitude, me.longitude, m.lat!, m.lng!);
  }

  // --- storage ------------------------------------------------------------------

  Future<void> _saveGroup({required bool on}) async {
    final g = group;
    if (g == null) return;
    await _secure.write(key: 'mesh_group', value: jsonEncode({'code': g.code, 'name': g.name, 'on': on}));
  }

  Future<File> _chatFile(MeshGroup g) async => File('${(await getApplicationDocumentsDirectory()).path}/mesh_${g.tag}.json');

  Future<void> _saveChat() async {
    final g = group;
    if (g == null) return;
    try {
      final data = chat
          .map((m) => {'id': m.id, 'from': m.from, 'name': m.name, 't': m.time.millisecondsSinceEpoch, 'type': m.type.name, 'body': m.body, 'hops': m.hops})
          .toList();
      await (await _chatFile(g)).writeAsString(jsonEncode(data));
    } catch (_) {}
  }

  Future<void> _loadChat() async {
    final g = group;
    if (g == null) return;
    try {
      final f = await _chatFile(g);
      if (!await f.exists()) return;
      for (final j in jsonDecode(await f.readAsString()) as List) {
        chat.add(
          MeshMessage(
            id: '${j['id']}',
            from: '${j['from']}',
            name: '${j['name']}',
            time: DateTime.fromMillisecondsSinceEpoch((j['t'] as num).toInt()),
            type: j['type'] == 'ping' ? MeshType.ping : MeshType.chat,
            body: j['body'] is Map ? Map<String, dynamic>.from(j['body'] as Map) : {'text': '${j['text'] ?? ''}'},
            hops: (j['hops'] as num?)?.toInt() ?? 0,
          ),
        );
      }
    } catch (_) {}
  }
}

/// The one instance the app uses.
final mesh = MeshService();
