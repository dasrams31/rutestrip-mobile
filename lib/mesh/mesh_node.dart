import 'dart:async';
import 'dart:typed_data';

import 'mesh_protocol.dart';

/// Moves bytes between this phone and the phones it is directly connected to.
abstract class MeshTransport {
  /// Bytes from a connected peer.
  Stream<(String peer, Uint8List bytes)> get incoming;

  /// A peer connected (true) or disconnected (false).
  Stream<(String peer, bool up)> get peers;

  Set<String> get connected;

  Future<void> start({required String tag, required String nodeId, required String name});

  Future<void> stop();

  Future<void> send(String peer, Uint8List bytes);
}

/// One phone in the group: de-duplicates, relays (store and forward) and hands verified
/// messages to the app. Knows nothing about radios.
class MeshNode {
  MeshNode({required this.codec, required this.transport, required this.name, this.historySize = 300});

  final MeshCodec codec;
  final MeshTransport transport;
  String name;
  final int historySize;

  final _seen = <String>{}; // insertion-ordered (LinkedHashSet)
  static const _seenMax = 4000;

  /// Recent packets as they travel (for peers that connect later).
  final _history = <String, Uint8List>{};

  final _messages = StreamController<MeshMessage>.broadcast();
  final _subs = <StreamSubscription<Object?>>[];

  Stream<MeshMessage> get messages => _messages.stream;

  /// Counts for tests and the screen.
  int relayed = 0, rejected = 0;

  Future<void> start() async {
    _subs
      ..add(transport.incoming.listen((e) => receive(e.$1, e.$2)))
      ..add(
        transport.peers.listen((e) {
          if (e.$2) _catchUp(e.$1);
        }),
      );
    await transport.start(tag: codec.group.tag, nodeId: codec.identity.nodeId, name: name);
  }

  Future<void> stop() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await transport.stop();
  }

  Future<void> dispose() async {
    await stop();
    await _messages.close();
  }

  /// Sends a new message to everyone; returns it as the others will see it.
  Future<MeshMessage> send(MeshType type, Map<String, dynamic> body, {DateTime? time}) async {
    final id = MeshCodec.newId();
    final t = time ?? DateTime.now();
    final bytes = await codec.seal(id: id, type: type, body: body, name: name, time: t);
    _markSeen(id);
    _remember(id, bytes);
    await _broadcast(bytes, except: null);
    return MeshMessage(id: id, from: codec.identity.nodeId, name: name, time: t, type: type, body: body);
  }

  /// Bytes from a peer: drop repeats and strangers, hand over, pass on.
  Future<void> receive(String peer, Uint8List bytes) async {
    final outer = MeshCodec.peek(bytes);
    if (outer == null) {
      rejected++;
      return;
    }
    if (!_markSeen(outer.id)) return; // already had it
    final msg = await codec.open(outer.raw);
    if (msg == null) {
      rejected++;
      return; // not this group, tampered or too old: not relayed either
    }
    if (msg.from == codec.identity.nodeId) return; // our own packet came back
    if (!_messages.isClosed) _messages.add(msg);
    if (outer.ttl > 0) {
      final next = MeshCodec.relayed(outer.raw);
      _remember(outer.id, next);
      relayed++;
      await _broadcast(next, except: peer);
    }
  }

  /// A phone joined: give it what it missed (dedup on its side drops repeats).
  Future<void> _catchUp(String peer) async {
    for (final b in _history.values.toList()) {
      await _safeSend(peer, b);
    }
  }

  Future<void> _broadcast(Uint8List bytes, {required String? except}) async {
    for (final p in transport.connected.toList()) {
      if (p != except) await _safeSend(p, bytes);
    }
  }

  Future<void> _safeSend(String peer, Uint8List bytes) async {
    try {
      await transport.send(peer, bytes);
    } catch (_) {
      // A peer that just left: its disconnect event follows.
    }
  }

  bool _markSeen(String id) {
    if (_seen.contains(id)) return false;
    _seen.add(id);
    if (_seen.length > _seenMax) _seen.remove(_seen.first);
    return true;
  }

  void _remember(String id, Uint8List bytes) {
    _history[id] = bytes;
    while (_history.length > historySize) {
      _history.remove(_history.keys.first);
    }
  }
}

/// In-memory radio for tests and demos: links are added between named phones.
class MemoryHub {
  final _nodes = <String, MemoryTransport>{};
  final _links = <String, Set<String>>{};

  MemoryTransport transport(String id) => _nodes.putIfAbsent(id, () => MemoryTransport._(id, this));

  void link(String a, String b) {
    _links.putIfAbsent(a, () => {}).add(b);
    _links.putIfAbsent(b, () => {}).add(a);
    _nodes[a]?._up(b);
    _nodes[b]?._up(a);
  }

  void unlink(String a, String b) {
    _links[a]?.remove(b);
    _links[b]?.remove(a);
    _nodes[a]?._down(b);
    _nodes[b]?._down(a);
  }

  Future<void> _deliver(String from, String to, Uint8List bytes) async {
    if (!(_links[from]?.contains(to) ?? false)) throw StateError('not linked');
    final t = _nodes[to];
    if (t != null && t._running) t._in.add((from, Uint8List.fromList(bytes)));
  }
}

class MemoryTransport implements MeshTransport {
  MemoryTransport._(this.id, this.hub);

  final String id;
  final MemoryHub hub;
  final _in = StreamController<(String, Uint8List)>.broadcast(sync: true);
  final _peers = StreamController<(String, bool)>.broadcast(sync: true);
  final _connected = <String>{};
  bool _running = false;

  @override
  Stream<(String, Uint8List)> get incoming => _in.stream;

  @override
  Stream<(String, bool)> get peers => _peers.stream;

  @override
  Set<String> get connected => _connected;

  void _up(String peer) {
    if (!_running || !(hub._nodes[peer]?._running ?? false)) return;
    if (_connected.add(peer)) _peers.add((peer, true));
  }

  void _down(String peer) {
    if (_connected.remove(peer)) _peers.add((peer, false));
  }

  @override
  Future<void> start({required String tag, required String nodeId, required String name}) async {
    _running = true;
    for (final p in hub._links[id] ?? const <String>{}) {
      _up(p);
      hub._nodes[p]?._up(id);
    }
  }

  @override
  Future<void> stop() async {
    _running = false;
    for (final p in _connected.toList()) {
      _down(p);
      hub._nodes[p]?._down(id);
    }
  }

  @override
  Future<void> send(String peer, Uint8List bytes) => hub._deliver(id, peer, bytes);
}
