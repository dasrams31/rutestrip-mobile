import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';

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
    mySos = false;
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
    notifyListeners();
  }

  // ---------------------------------------------------------------------------

  void _onMessage(MeshMessage m) {
    final member = members.putIfAbsent(m.from, () => MeshMember(m.from, m.name));
    member
      ..name = m.name
      ..hops = m.hops;
    if (m.time.isAfter(member.lastSeen)) member.lastSeen = m.time;
    switch (m.type) {
      case MeshType.chat:
        _addChat(m);
      case MeshType.pos:
        _takePosition(member, m);
      case MeshType.sos:
        _takePosition(member, m);
        if (m.body['active'] == true) {
          final isNew = !sos.containsKey(m.from);
          sos[m.from] = m;
          if (isNew) _alarm();
        } else {
          sos.remove(m.from);
        }
      case MeshType.hello:
        break;
    }
    notifyListeners();
  }

  void _takePosition(MeshMember member, MeshMessage m) {
    final lat = (m.body['lat'] as num?)?.toDouble(), lng = (m.body['lng'] as num?)?.toDouble();
    if (lat == null || lng == null || lat.abs() > 90 || lng.abs() > 180) return;
    if (member.posTime != null && !m.time.isAfter(member.posTime!)) return; // an older position relayed late
    member
      ..lat = lat
      ..lng = lng
      ..accuracy = (m.body['acc'] as num?)?.toDouble()
      ..posTime = m.time;
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
    _posSub =
        Geolocator.getPositionStream(
          locationSettings: AndroidSettings(accuracy: LocationAccuracy.high, forceLocationManager: true, distanceFilter: 10, intervalDuration: posEvery),
        ).listen((p) {
          myPosition = p;
          notifyListeners();
          final prev = _posSent;
          final moved = prev == null ? double.infinity : distanceM(prev.latitude, prev.longitude, p.latitude, p.longitude);
          final since = DateTime.now().difference(_posSentAt);
          // Every 30 s when walking (25 m or more), at least every 3 minutes when resting.
          if (p.accuracy <= 50 && ((moved >= posMinMove && since >= posEvery) || since >= const Duration(minutes: 3))) {
            _posSent = p;
            _posSentAt = DateTime.now();
            _node?.send(MeshType.pos, {'lat': p.latitude, 'lng': p.longitude, 'acc': p.accuracy});
          }
        }, onError: (_) {});
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
          .map((m) => {'id': m.id, 'from': m.from, 'name': m.name, 't': m.time.millisecondsSinceEpoch, 'text': m.body['text'], 'hops': m.hops})
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
            type: MeshType.chat,
            body: {'text': '${j['text']}'},
            hops: (j['hops'] as num?)?.toInt() ?? 0,
          ),
        );
      }
    } catch (_) {}
  }
}

/// The one instance the app uses.
final mesh = MeshService();
