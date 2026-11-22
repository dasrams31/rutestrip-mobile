import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rutestrip/mesh/mesh_node.dart';
import 'package:rutestrip/mesh/mesh_protocol.dart';

Future<MeshNode> _node(MemoryHub hub, String id, MeshGroup group, {int seed = 1}) async {
  final identity = await MeshIdentity.fromSeed(List.generate(32, (i) => (i * seed + seed) % 256));
  return MeshNode(codec: MeshCodec(group, identity), transport: hub.transport(id), name: 'Pendaki $id');
}

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 50));

void main() {
  late MeshGroup group;

  setUpAll(() async {
    group = await MeshGroup.open('ABCDE23456', 'Uji');
  });

  test('codes are 10 unambiguous characters and normalise from what people type', () {
    final code = MeshProtocol.newCode(math.Random(1));
    expect(code.length, 10);
    expect(code, matches(RegExp(r'^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]+$')));
    expect(MeshProtocol.normalizeCode(' abcde-23456 '), 'ABCDE23456');
    expect(MeshProtocol.normalizeCode('ABCDE2345O'), isNull); // letter O is not used
    expect(MeshProtocol.prettyCode('ABCDE23456'), 'ABCDE-23456');
  });

  test('the same code gives the same key and tag; another code does not', () async {
    final again = await MeshGroup.open('ABCDE23456', 'Nama lain');
    final other = await MeshGroup.open('ABCDE23457', 'Uji');
    expect(again.tag, group.tag);
    expect(await again.key.extractBytes(), await group.key.extractBytes());
    expect(other.tag, isNot(group.tag));
  });

  test('a sealed packet opens with its signature checked', () async {
    final me = await MeshIdentity.fromSeed(List.filled(32, 7));
    final codec = MeshCodec(group, me);
    final bytes = await codec.seal(id: 'a1', type: MeshType.chat, body: {'text': 'Halo pos 2'}, name: 'Rama', time: DateTime.now());
    final outer = MeshCodec.peek(bytes)!;
    final msg = (await codec.open(outer.raw))!;
    expect(msg.from, me.nodeId);
    expect(msg.name, 'Rama');
    expect(msg.body['text'], 'Halo pos 2');
    // Nothing readable on the air.
    expect(utf8.decode(bytes), isNot(contains('Halo')));
  });

  test('another group, a changed byte, a changed id or an old packet is rejected', () async {
    final me = await MeshIdentity.fromSeed(List.filled(32, 7));
    final codec = MeshCodec(group, me);
    final bytes = await codec.seal(id: 'a2', type: MeshType.chat, body: {'text': 'x'}, name: 'R', time: DateTime.now());
    final raw = MeshCodec.peek(bytes)!.raw;

    final stranger = MeshCodec(await MeshGroup.open('ZZZZZ22222', 'Lain'), me);
    expect(await stranger.open(raw), isNull);

    final box = base64.decode(raw['box'] as String);
    box[box.length - 20] ^= 1;
    expect(await codec.open({...raw, 'box': base64.encode(box)}), isNull);

    expect(await codec.open({...raw, 'id': 'a3'}), isNull);

    final old = await codec.seal(id: 'a4', type: MeshType.chat, body: {}, name: 'R', time: DateTime.now().subtract(const Duration(days: 2)));
    expect(await codec.open(MeshCodec.peek(old)!.raw), isNull);
  });

  test('a member cannot send under another member\'s node id', () async {
    final real = await MeshIdentity.fromSeed(List.filled(32, 1));
    final fake = await MeshIdentity.fromSeed(List.filled(32, 2));
    final aes = AesGcm.with256bits();

    // A group member (knows the group key) forges a packet claiming to be `real`.
    Future<Map<String, dynamic>> forged({required bool useRealKey}) async {
      final inner = jsonEncode({'id': 'f1', 'from': real.nodeId, 'name': 'Budi', 't': DateTime.now().millisecondsSinceEpoch, 'type': 'sos', 'body': {}});
      final sig = await Ed25519().sign(utf8.encode(inner), keyPair: fake.keyPair);
      final pk = useRealKey ? real.publicKey : fake.publicKey;
      final plain = utf8.encode(jsonEncode({'m': inner, 'pk': base64.encode(pk), 'sig': base64.encode(sig.bytes)}));
      final box = await aes.encrypt(plain, secretKey: group.key, aad: utf8.encode('f1'));
      return {'v': 1, 'id': 'f1', 'ttl': 6, 'hop': 0, 'box': base64.encode(box.concatenation())};
    }

    final codec = MeshCodec(group, real);
    expect(await codec.open(await forged(useRealKey: false)), isNull, reason: 'own key, someone else\'s id');
    expect(await codec.open(await forged(useRealKey: true)), isNull, reason: 'someone else\'s key, own signature');
  });

  test('messages hop A -> B -> C and arrive once', () async {
    final hub = MemoryHub();
    final a = await _node(hub, 'A', group, seed: 1);
    final b = await _node(hub, 'B', group, seed: 2);
    final c = await _node(hub, 'C', group, seed: 3);
    final atC = <MeshMessage>[];
    c.messages.listen(atC.add);
    for (final n in [a, b, c]) {
      await n.start();
    }
    hub.link('A', 'B');
    hub.link('B', 'C'); // A and C are out of range of each other

    await a.send(MeshType.chat, {'text': 'Sudah di pos 3'});
    await _settle();

    expect(atC.map((m) => m.body['text']), ['Sudah di pos 3']);
    expect(atC.single.hops, 1);
    expect(b.relayed, 1);
  });

  test('a ring does not loop forever and every phone gets each message once', () async {
    final hub = MemoryHub();
    final nodes = [
      for (final (i, id) in ['A', 'B', 'C', 'D'].indexed) await _node(hub, id, group, seed: i + 1),
    ];
    final got = {for (final n in nodes) n: <String>[]};
    for (final n in nodes) {
      n.messages.listen((m) => got[n]!.add(m.id));
      await n.start();
    }
    hub
      ..link('A', 'B')
      ..link('B', 'C')
      ..link('C', 'D')
      ..link('D', 'A');
    final sent = await nodes[0].send(MeshType.chat, {'text': 'ring'});
    await _settle();
    expect(got[nodes[0]], isEmpty);
    for (final n in nodes.skip(1)) {
      expect(got[n], [sent.id]);
    }
  });

  test('a phone that connects later gets the messages it missed', () async {
    final hub = MemoryHub();
    final a = await _node(hub, 'A', group, seed: 1);
    final b = await _node(hub, 'B', group, seed: 2);
    final atB = <MeshMessage>[];
    b.messages.listen(atB.add);
    await a.start();
    await b.start();
    await a.send(MeshType.sos, {'lat': -7.45, 'lng': 110.43, 'active': true});
    await a.send(MeshType.chat, {'text': 'Tolong'});
    expect(atB, isEmpty);

    hub.link('A', 'B');
    await _settle();
    expect(atB.map((m) => m.type), [MeshType.sos, MeshType.chat]);
  });

  test('ttl ends relaying', () async {
    final hub = MemoryHub();
    final ids = List.generate(9, (i) => 'N$i');
    final nodes = [for (final (i, id) in ids.indexed) await _node(hub, id, group, seed: i + 1)];
    final last = <MeshMessage>[];
    nodes.last.messages.listen(last.add);
    final eighth = <MeshMessage>[];
    nodes[7].messages.listen(eighth.add);
    for (final n in nodes) {
      await n.start();
    }
    for (var i = 0; i < ids.length - 1; i++) {
      hub.link(ids[i], ids[i + 1]);
    }
    await nodes.first.send(MeshType.chat, {'text': 'jauh'});
    await _settle();
    // ttl 6: reaches 7 hops away (N7), not 8 (N8).
    expect(eighth, hasLength(1));
    expect(last, isEmpty);
  });

  test('junk and oversized bytes are dropped without crashing', () async {
    final hub = MemoryHub();
    final a = await _node(hub, 'A', group);
    await a.start();
    await a.receive('X', Uint8List.fromList(utf8.encode('{"v":1,"id":"x"}')));
    await a.receive('X', Uint8List.fromList(List.filled(MeshProtocol.maxPacketBytes + 1, 65)));
    await a.receive('X', Uint8List.fromList([0, 1, 2]));
    expect(a.rejected, 3);
  });
}
