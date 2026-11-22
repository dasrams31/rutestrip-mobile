import 'dart:async';
import 'dart:typed_data';

import 'package:nearby_connections/nearby_connections.dart';
import 'package:permission_handler/permission_handler.dart';

import 'mesh_node.dart';

/// Android Nearby Connections (Bluetooth + Wi-Fi, no internet) in P2P_CLUSTER mode:
/// every phone advertises and discovers at the same time and connects to the group's
/// phones it finds. Only phones showing the group's tag are connected; the content
/// itself is protected by the group key in [MeshCodec], not by this layer.
class NearbyTransport implements MeshTransport {
  static const serviceId = 'id.ai.rutestrip.mesh';

  /// While at least one phone is connected, discovery (the costly radio scan) runs in
  /// bursts to save battery; with nobody connected it keeps looking.
  static const scanOn = Duration(seconds: 30), scanOff = Duration(seconds: 90);

  final _nearby = Nearby();
  final _in = StreamController<(String, Uint8List)>.broadcast();
  final _peers = StreamController<(String, bool)>.broadcast();
  final _connected = <String>{};
  final _pending = <String>{};
  String _tag = '', _self = '';
  bool _running = false, _discovering = false;
  Timer? _cycle;

  @override
  Stream<(String, Uint8List)> get incoming => _in.stream;

  @override
  Stream<(String, bool)> get peers => _peers.stream;

  @override
  Set<String> get connected => _connected;

  /// Asks for what Nearby needs; false when something was refused.
  static Future<bool> ensurePermissions() async {
    final wanted = [
      Permission.locationWhenInUse,
      Permission.bluetoothScan,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.nearbyWifiDevices,
    ];
    final result = await wanted.request();
    // The group notification and SOS alerts; the group still works if this is refused.
    await Permission.notification.request();
    // Permissions that do not exist on this Android version come back as granted or restricted.
    return result.values.every((s) => s.isGranted || s.isLimited || s.isRestricted);
  }

  String get _nick => '$_tag:$_self';

  bool _ours(String endpointName) => endpointName.startsWith('$_tag:');

  @override
  Future<void> start({required String tag, required String nodeId, required String name}) async {
    if (_running) return;
    _tag = tag;
    _self = nodeId.substring(0, 8);
    _running = true;
    await _nearby.startAdvertising(
      _nick,
      Strategy.P2P_CLUSTER,
      serviceId: serviceId,
      onConnectionInitiated: _onInitiated,
      onConnectionResult: _onResult,
      onDisconnected: _onDisconnected,
    );
    await _discover(true);
    _cycle = Timer.periodic(scanOn + scanOff, (_) {
      if (_connected.isEmpty) return; // nobody yet: discovery simply stays on
      _discover(true);
      Timer(scanOn, () {
        if (_connected.isNotEmpty) _discover(false);
      });
    });
  }

  Future<void> _discover(bool on) async {
    if (!_running || on == _discovering) return;
    _discovering = on;
    try {
      if (on) {
        await _nearby.startDiscovery(_nick, Strategy.P2P_CLUSTER, serviceId: serviceId, onEndpointFound: _onFound, onEndpointLost: (_) {});
      } else {
        await _nearby.stopDiscovery();
      }
    } catch (_) {
      _discovering = !on;
    }
  }

  void _onFound(String endpointId, String endpointName, String _) {
    if (!_running || !_ours(endpointName) || _connected.contains(endpointId) || _pending.contains(endpointId)) return;
    // Both phones see each other; only the one with the smaller id asks, so they do not collide.
    final theirs = endpointName.substring(_tag.length + 1);
    if (_self.compareTo(theirs) > 0) return;
    _pending.add(endpointId);
    _nearby
        .requestConnection(_nick, endpointId, onConnectionInitiated: _onInitiated, onConnectionResult: _onResult, onDisconnected: _onDisconnected)
        .catchError((_) {
          _pending.remove(endpointId);
          return false;
        });
  }

  void _onInitiated(String endpointId, ConnectionInfo info) {
    if (!_running || !_ours(info.endpointName)) {
      _nearby.rejectConnection(endpointId);
      return;
    }
    _nearby.acceptConnection(
      endpointId,
      onPayLoadRecieved: (id, payload) {
        final bytes = payload.bytes;
        if (payload.type == PayloadType.BYTES && bytes != null) _in.add((id, bytes));
      },
    );
  }

  void _onResult(String endpointId, Status status) {
    _pending.remove(endpointId);
    if (status == Status.CONNECTED && _connected.add(endpointId)) _peers.add((endpointId, true));
  }

  void _onDisconnected(String endpointId) {
    _pending.remove(endpointId);
    if (_connected.remove(endpointId)) _peers.add((endpointId, false));
    if (_connected.isEmpty) _discover(true); // look for the group again
  }

  @override
  Future<void> send(String peer, Uint8List bytes) => _nearby.sendBytesPayload(peer, bytes);

  @override
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _cycle?.cancel();
    _cycle = null;
    for (final p in _connected.toList()) {
      _peers.add((p, false));
    }
    _connected.clear();
    _pending.clear();
    try {
      await _nearby.stopDiscovery();
      await _nearby.stopAdvertising();
      await _nearby.stopAllEndpoints();
    } catch (_) {}
    _discovering = false;
  }
}
