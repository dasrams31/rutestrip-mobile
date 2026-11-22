import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Offline group ("Rombongan") protocol, shared by every transport.
///
/// - A group is a 10-character join code. The code derives the group key
///   (PBKDF2-HMAC-SHA256); every packet body is sealed with AES-256-GCM under it,
///   so phones outside the group can relay nothing they can read or forge.
/// - Each phone has its own Ed25519 key; its node id is the hash of the public key and
///   every message is signed, so members cannot pose as another member's node.
/// - Outer packet: {"v":1,"id","ttl","hop","box"}; only ttl and hop change while
///   relaying, and the id is bound into the seal (AAD).
class MeshProtocol {
  static const version = 1;
  static const maxPacketBytes = 8 * 1024;
  static const maxAge = Duration(hours: 24);
  static const maxTextLength = 500;

  /// Unambiguous letters and digits (no 0/O, 1/I/L): read out loud on a mountain.
  static const codeAlphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  static const codeLength = 10;

  static String newCode([math.Random? random]) {
    final r = random ?? math.Random.secure();
    return List.generate(codeLength, (_) => codeAlphabet[r.nextInt(codeAlphabet.length)]).join();
  }

  /// "abcd-efgh jk" -> "ABCDEFGHJK"; null when it is not a valid code.
  static String? normalizeCode(String input) {
    final c = input.toUpperCase().replaceAll(RegExp(r'[\s-]'), '');
    if (c.length != codeLength) return null;
    for (final ch in c.split('')) {
      if (!codeAlphabet.contains(ch)) return null;
    }
    return c;
  }

  static String prettyCode(String code) => code.length == codeLength ? '${code.substring(0, 5)}-${code.substring(5)}' : code;
}

/// A joined group: its name, code and the keys derived from the code.
class MeshGroup {
  MeshGroup._(this.code, this.name, this.key, this.tag);

  final String code, name;
  final SecretKey key;

  /// Short public label used to find group members nearby (not secret, not the key).
  final String tag;

  static Future<MeshGroup> open(String code, String name) async {
    final pbkdf2 = Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: 20000, bits: 256);
    final key = await pbkdf2.deriveKeyFromPassword(password: code, nonce: utf8.encode('rutestrip-mesh-v1'));
    final keyBytes = await key.extractBytes();
    final tagHash = await Sha256().hash([...utf8.encode('tag:'), ...keyBytes]);
    final tag = _hex(tagHash.bytes).substring(0, 8);
    return MeshGroup._(code, name, SecretKey(keyBytes), tag);
  }
}

/// This phone's signing identity.
class MeshIdentity {
  MeshIdentity._(this.keyPair, this.publicKey, this.nodeId);

  final SimpleKeyPair keyPair;
  final List<int> publicKey;
  final String nodeId;

  static Future<MeshIdentity> fromSeed(List<int> seed) async {
    final kp = await Ed25519().newKeyPairFromSeed(seed);
    final pk = (await kp.extractPublicKey()).bytes;
    return MeshIdentity._(kp, pk, await nodeIdOf(pk));
  }

  static List<int> newSeed() {
    final r = math.Random.secure();
    return List.generate(32, (_) => r.nextInt(256));
  }

  static Future<String> nodeIdOf(List<int> publicKey) async => _hex((await Sha256().hash(publicKey)).bytes).substring(0, 16);
}

/// hello: announce; chat: text (optionally with lat/lng); pos: position; sos: alert;
/// ping: team call (buzz + short siren); pin: the group's pinned note.
enum MeshType { hello, chat, pos, sos, ping, pin }

/// A verified message from a member.
class MeshMessage {
  MeshMessage({required this.id, required this.from, required this.name, required this.time, required this.type, required this.body, this.hops = 0});

  final String id, from, name;
  final DateTime time;
  final MeshType type;
  final Map<String, dynamic> body;

  /// How many phones it passed through on the way here (0 = direct).
  final int hops;
}

class MeshCodec {
  MeshCodec(this.group, this.identity);

  final MeshGroup group;
  final MeshIdentity identity;
  final _aes = AesGcm.with256bits();
  final _ed = Ed25519();

  static String newId() {
    final r = math.Random.secure();
    return _hex(List.generate(12, (_) => r.nextInt(256)));
  }

  /// Signed and sealed packet, ready to send.
  Future<Uint8List> seal({
    required String id,
    required MeshType type,
    required Map<String, dynamic> body,
    required String name,
    required DateTime time,
    int ttl = 6,
  }) async {
    final inner = jsonEncode({'id': id, 'from': identity.nodeId, 'name': name, 't': time.millisecondsSinceEpoch, 'type': type.name, 'body': body});
    final sig = await _ed.sign(utf8.encode(inner), keyPair: identity.keyPair);
    final plain = utf8.encode(jsonEncode({'m': inner, 'pk': base64.encode(identity.publicKey), 'sig': base64.encode(sig.bytes)}));
    final box = await _aes.encrypt(plain, secretKey: group.key, aad: utf8.encode(id));
    return Uint8List.fromList(utf8.encode(jsonEncode({'v': MeshProtocol.version, 'id': id, 'ttl': ttl, 'hop': 0, 'box': base64.encode(box.concatenation())})));
  }

  /// Outer fields without opening the seal (for relaying and de-duplication), or null.
  static ({String id, int ttl, int hop, Map<String, dynamic> raw})? peek(List<int> bytes) {
    if (bytes.length > MeshProtocol.maxPacketBytes) return null;
    try {
      final j = jsonDecode(utf8.decode(bytes));
      if (j is! Map<String, dynamic> || j['v'] != MeshProtocol.version) return null;
      final id = j['id'], ttl = j['ttl'], hop = j['hop'];
      if (id is! String || id.length > 64 || ttl is! int || hop is! int || j['box'] is! String) return null;
      return (id: id, ttl: ttl.clamp(0, 10), hop: hop.clamp(0, 50), raw: j);
    } catch (_) {
      return null;
    }
  }

  /// The same packet one hop further (ttl - 1, hop + 1).
  static Uint8List relayed(Map<String, dynamic> raw) =>
      Uint8List.fromList(utf8.encode(jsonEncode({...raw, 'ttl': (raw['ttl'] as int) - 1, 'hop': (raw['hop'] as int) + 1})));

  /// Opens, checks the signature, the sender id and the age. Null for anything not from this group.
  Future<MeshMessage?> open(Map<String, dynamic> raw, {DateTime? now}) async {
    try {
      final id = raw['id'] as String;
      final box = SecretBox.fromConcatenation(base64.decode(raw['box'] as String), nonceLength: 12, macLength: 16);
      final plain = jsonDecode(utf8.decode(await _aes.decrypt(box, secretKey: group.key, aad: utf8.encode(id)))) as Map;
      final inner = plain['m'] as String;
      final pk = base64.decode(plain['pk'] as String);
      final ok = await _ed.verify(
        utf8.encode(inner),
        signature: Signature(base64.decode(plain['sig'] as String), publicKey: SimplePublicKey(pk, type: KeyPairType.ed25519)),
      );
      if (!ok) return null;
      final m = jsonDecode(inner) as Map<String, dynamic>;
      if (m['id'] != id || m['from'] != await MeshIdentity.nodeIdOf(pk)) return null;
      final time = DateTime.fromMillisecondsSinceEpoch((m['t'] as num).toInt());
      final age = (now ?? DateTime.now()).difference(time);
      if (age > MeshProtocol.maxAge || age < -MeshProtocol.maxAge) return null;
      final type = MeshType.values.firstWhere((t) => t.name == m['type']);
      final name = '${m['name'] ?? ''}';
      final body = Map<String, dynamic>.from(m['body'] as Map);
      // A teammate's phone is trusted with the key, but its text is still capped.
      final text = body['text'];
      if (text is! String && text != null) body.remove('text');
      if (text is String && text.length > MeshProtocol.maxTextLength) body['text'] = text.substring(0, MeshProtocol.maxTextLength);
      return MeshMessage(
        id: id,
        from: m['from'] as String,
        name: name.length > 60 ? name.substring(0, 60) : name,
        time: time,
        type: type,
        body: body,
        hops: (raw['hop'] as num).toInt(),
      );
    } catch (_) {
      return null; // wrong group key, tampered, or malformed
    }
  }
}

String _hex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
