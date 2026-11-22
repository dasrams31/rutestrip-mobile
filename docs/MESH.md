# Rombongan: offline group mesh

Chat, positions and SOS between the phones of one hiking group without internet.
Code: `lib/mesh/` (protocol, node, Nearby transport, app service) and
`lib/screens/group_pane.dart`; tests in `test/mesh_test.dart`.

## Transport

Android Nearby Connections (`nearby_connections` plugin, Google Play services) in
`P2P_CLUSTER` mode: every phone advertises and discovers at once over Bluetooth, BLE
and Wi-Fi, and connects to every phone it finds that shows the group's tag
(`<tag>:<node>`). Only the phone with the smaller node id asks, so two phones do not
request each other at the same time. With at least one phone connected, discovery runs
30 s out of every 2 minutes to save battery; with nobody connected it keeps looking.

## Packets

```
outer (on the air): {"v":1, "id", "ttl", "hop", "box"}
box  = AES-256-GCM(group key, aad = id) of {"m": inner, "pk": Ed25519 public key, "sig"}
inner = {"id", "from": node id, "name", "t", "type": hello|chat|pos|sos, "body"}
```

- Group key: PBKDF2-HMAC-SHA256 (20,000 rounds) of the 10-character join code
  (31-letter alphabet, about 49 bits). Anyone with the code can read the group.
- Node id = first 16 hex characters of SHA-256(public key). A packet whose signature
  does not verify, or whose `from` is not the hash of its key, is dropped, so a member
  cannot send under another member's id (display names are self-chosen).
- Packets older or newer than 24 hours, larger than 8 KB, or not sealed with this
  group's key are dropped and never relayed.

## Relay

Each phone keeps the last 4,000 packet ids (de-duplication) and the last 300 packets.
A new packet is shown and passed to every other connected phone with `ttl - 1` (start
6, so up to 7 phones away). A phone that connects later receives the stored packets
(store and forward). Positions are sent every 30 s while walking (25 m or more) and
at least every 3 minutes, only with GPS accuracy of 50 m or better.

## Tested

- Unit tests: key derivation, sealing, tampering, wrong group, old packets,
  impersonation, A-B-C relay, a ring (no loops, one copy each), late joiner, ttl limit,
  junk input.
- Emulator: creating a group, permissions, radios on (Nearby starts and sees only
  itself over WIFI_LAN), chat stored and shown, SOS hold and stop, restart restores the
  group and turns the radios back on.
- Not testable on one emulator: two phones finding each other. Emulators have no
  Bluetooth and each sits behind its own virtual network, so this needs two (or three,
  for relaying) real Android phones with Google Play services.
