import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshshare/features/peers/peer_contact_store.dart';

void main() {
  late Directory tmpDir;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('meshshare_block_');
  });

  tearDown(() async {
    if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
  });

  group('PeerContactStore blocking', () {
    const peerId = 'a1b2c3d4e5f6a7b8';

    test('a fresh peer is not blocked', () {
      final store = PeerContactStore.forTesting(tmpDir);
      expect(store.isBlocked(peerId), isFalse);
    });

    test('setBlocked creates a contact row when none exists', () async {
      final store = PeerContactStore.forTesting(tmpDir);
      await store.setBlocked(peerId, true);

      expect(store.isBlocked(peerId), isTrue);
      expect(store.contactFor(peerId), isNotNull);
      expect(store.contactFor(peerId)!.blocked, isTrue);
    });

    test('unblocking clears the flag', () async {
      final store = PeerContactStore.forTesting(tmpDir);
      await store.setBlocked(peerId, true);
      await store.setBlocked(peerId, false);
      expect(store.isBlocked(peerId), isFalse);
    });

    test('unblocking an unknown peer is a no-op (no row created)', () async {
      final store = PeerContactStore.forTesting(tmpDir);
      await store.setBlocked(peerId, false);
      expect(store.contactFor(peerId), isNull);
    });

    test('rename keeps the blocked flag intact', () async {
      final store = PeerContactStore.forTesting(tmpDir);
      await store.setBlocked(peerId, true);
      await store.rename(peerId, 'Noisy Neighbour');

      expect(store.isBlocked(peerId), isTrue);
      expect(store.nameFor(peerId), equals('Noisy Neighbour'));
    });

    test('block state survives a reload from disk', () async {
      final store = PeerContactStore.forTesting(tmpDir);
      await store.setBlocked(peerId, true);

      final reloaded = PeerContactStore.forTesting(tmpDir);
      await reloaded.init();
      expect(reloaded.isBlocked(peerId), isTrue);
    });

    test('isBlocked matches when queried with a longer identity hex', () async {
      final store = PeerContactStore.forTesting(tmpDir);
      await store.setBlocked(peerId, true); // 16-char short id stored

      // A caller that only has the full 64-char identity should still match.
      expect(store.isBlocked('${peerId}deadbeefdeadbeef'), isTrue);
    });

    test('notifies listeners on block and unblock', () async {
      final store = PeerContactStore.forTesting(tmpDir);
      var notifications = 0;
      store.addListener(() => notifications++);

      await store.setBlocked(peerId, true);
      await store.setBlocked(peerId, false);

      expect(notifications, equals(2));
    });
  });
}
