// Integration tests: full transfer pipeline across Noise_XX handshake,
// AEAD encryption, file chunking, mesh relay, and reassembly.
//
// No BLE hardware is required — chunks are passed in-memory between
// a simulated sender and receiver. These tests verify that the four
// core objectives work together end-to-end before any device is deployed.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:meshshare/features/crypto/aead_cipher.dart';
import 'package:meshshare/features/crypto/key_manager.dart';
import 'package:meshshare/features/crypto/noise_handshake.dart';
import 'package:meshshare/features/file_transfer/chunk_model.dart';
import 'package:meshshare/features/file_transfer/file_assembler.dart';
import 'package:meshshare/features/file_transfer/file_chunker.dart';

// ── Helpers ────────────────────────────────────────────────────────────────

/// Encrypt, transmit (in memory), decrypt, and reassemble [bytes].
///
/// Returns the assembled bytes so the caller can compare them to [bytes].
Future<Uint8List> _transferFile({
  required Uint8List bytes,
  required KeyManager senderKeys,
  required KeyManager receiverKeys,
  required String receiverPeerId,
  required String senderPeerId,
  PayloadType type = PayloadType.file,
  List<FileChunk> Function(List<FileChunk>)? transmit,
}) async {
  final sendKey = senderKeys.sessionSendKey(receiverPeerId)!;
  final receiveKey = receiverKeys.sessionReceiveKey(senderPeerId)!;

  final chunks = await FileChunker.chunkFile(bytes, type: type);
  final encrypted = [
    for (final c in chunks) await AeadCipher.encryptChunk(c, sendKey),
  ];

  // Optional transform — used to simulate relay hops, reordering, duplicates.
  final delivered = transmit != null ? transmit(encrypted) : encrypted;

  final assembler = FileAssembler(
    fileId: chunks.first.fileId,
    totalChunks: chunks.length,
  );
  for (final enc in delivered) {
    final dec = await AeadCipher.decryptChunk(enc, receiveKey);
    assembler.addChunk(dec);
  }

  return assembler.assemble();
}

// ── Test setup / teardown ─────────────────────────────────────────────────

void main() {
  group('End-to-end transfer pipeline', () {
    late Directory senderDir;
    late Directory receiverDir;
    late KeyManager senderKeys;
    late KeyManager receiverKeys;
    late String senderPeerId;
    late String receiverPeerId;

    setUp(() async {
      senderDir = await Directory.systemTemp.createTemp('mesh_sender_');
      receiverDir = await Directory.systemTemp.createTemp('mesh_receiver_');
      senderKeys = KeyManager.forTesting(senderDir);
      receiverKeys = KeyManager.forTesting(receiverDir);

      // ── Noise_XX handshake ────────────────────────────────────────────────
      final senderKp = await senderKeys.getOrCreateStaticKeyPair();
      final receiverKp = await receiverKeys.getOrCreateStaticKeyPair();

      final initiator = await NoiseInitiator.create(senderKp);
      final responder = await NoiseResponder.create(receiverKp);

      // 3-message exchange: msg1 → msg2 → msg3
      final msg1 = await initiator.writeMessage1();
      final msg2 = await responder.readMsg1WriteMsg2(msg1);
      final msg3 = await initiator.readMsg2WriteMsg3(msg2);
      await responder.readMessage3(msg3);

      // Store derived transport keys in each manager.
      // initiator.result.sendKey = k1  (sender→receiver)
      // responder.result.receiveKey = k1 (same key, used to decrypt by receiver)
      senderPeerId = await senderKeys.localPeerId();
      receiverPeerId = await receiverKeys.localPeerId();

      senderKeys.storeSession(
        receiverPeerId,
        initiator.result.sendKey,
        initiator.result.receiveKey,
      );
      receiverKeys.storeSession(
        senderPeerId,
        responder.result.sendKey,
        responder.result.receiveKey,
      );
    });

    tearDown(() async {
      await senderDir.delete(recursive: true);
      await receiverDir.delete(recursive: true);
    });

    // ── Test 1: basic round-trip ────────────────────────────────────────────

    test('file bytes survive encrypt → chunk → decrypt → assemble (1 KB)', () async {
      final original = Uint8List.fromList(
        List.generate(1024, (i) => (i * 31 + 7) % 256),
      );

      final assembled = await _transferFile(
        bytes: original,
        senderKeys: senderKeys,
        receiverKeys: receiverKeys,
        senderPeerId: senderPeerId,
        receiverPeerId: receiverPeerId,
      );

      expect(assembled, equals(original));
    });

    // ── Test 2: out-of-order delivery ─────────────────────────────────────

    test('out-of-order chunk delivery assembles correctly', () async {
      final original = Uint8List.fromList(
        List.generate(500, (i) => i % 256),
      );

      // Deliver chunks in reverse order — BLE mesh reordering simulation.
      final assembled = await _transferFile(
        bytes: original,
        senderKeys: senderKeys,
        receiverKeys: receiverKeys,
        senderPeerId: senderPeerId,
        receiverPeerId: receiverPeerId,
        transmit: (chunks) => chunks.reversed.toList(),
      );

      expect(assembled, equals(original));
    });

    // ── Test 3: tamper detection ───────────────────────────────────────────

    test('tampered chunk is rejected — AEAD MAC verification fails', () async {
      final original = Uint8List.fromList(List.generate(400, (i) => i % 256));

      final sendKey = senderKeys.sessionSendKey(receiverPeerId)!;
      final receiveKey = receiverKeys.sessionReceiveKey(senderPeerId)!;

      final chunks = await FileChunker.chunkFile(original, type: PayloadType.file);
      final encrypted = [
        for (final c in chunks) await AeadCipher.encryptChunk(c, sendKey),
      ];

      // Flip one bit in the first chunk's ciphertext.
      final first = encrypted.first;
      final corrupt = Uint8List.fromList(first.data.toList()..[0] ^= 0xFF);
      final tampered = FileChunk(
        fileId: first.fileId,
        chunkIndex: first.chunkIndex,
        totalChunks: first.totalChunks,
        data: corrupt,
        checksum: first.checksum,
        ttl: first.ttl,
        payloadType: first.payloadType,
      );

      // AEAD must throw when the MAC tag does not match.
      await expectLater(
        AeadCipher.decryptChunk(tampered, receiveKey),
        throwsA(anything),
      );

      // All other (untampered) chunks still decrypt without error.
      for (final enc in encrypted.skip(1)) {
        final dec = await AeadCipher.decryptChunk(enc, receiveKey);
        expect(dec.chunkIndex, equals(enc.chunkIndex));
      }
    });

    // ── Test 4: 2-hop relay ────────────────────────────────────────────────

    test('2-hop relay: sender → relay1 → relay2 → receiver — file arrives intact',
        () async {
      final original = Uint8List.fromList(
        List.generate(600, (i) => (i * 13 + 3) % 256),
      );

      // Each relay decrements TTL and blindly forwards (no decryption).
      final assembled = await _transferFile(
        bytes: original,
        senderKeys: senderKeys,
        receiverKeys: receiverKeys,
        senderPeerId: senderPeerId,
        receiverPeerId: receiverPeerId,
        transmit: (chunks) => chunks
            .map((c) => c.decrementTtl()) // relay 1
            .map((c) => c.decrementTtl()) // relay 2
            .toList(),
      );

      expect(assembled, equals(original));
    });

    test('relay chunks carry decremented TTL', () async {
      final original = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);

      final sendKey = senderKeys.sessionSendKey(receiverPeerId)!;
      final chunks = await FileChunker.chunkFile(original, type: PayloadType.file);
      final encrypted = [
        for (final c in chunks) await AeadCipher.encryptChunk(c, sendKey),
      ];

      final originalTtl = encrypted.first.ttl;
      final afterHop1 = encrypted.map((c) => c.decrementTtl()).toList();
      final afterHop2 = afterHop1.map((c) => c.decrementTtl()).toList();

      expect(afterHop1.first.ttl, equals(originalTtl - 1));
      expect(afterHop2.first.ttl, equals(originalTtl - 2));
      // Data is untouched — relay is blind
      expect(afterHop2.first.data, equals(encrypted.first.data));
    });

    // ── Test 5: relay cannot decrypt ──────────────────────────────────────

    test('relay node has no session keys and cannot decrypt chunks', () async {
      final relayDir = await Directory.systemTemp.createTemp('mesh_relay_');
      addTearDown(() => relayDir.delete(recursive: true));

      final relayKeys = KeyManager.forTesting(relayDir);

      // Relay was never part of the handshake — no session keys for either peer.
      expect(relayKeys.sessionReceiveKey(senderPeerId), isNull);
      expect(relayKeys.sessionReceiveKey(receiverPeerId), isNull);
      expect(relayKeys.sessionSendKey(senderPeerId), isNull);
      expect(relayKeys.sessionSendKey(receiverPeerId), isNull);
    });

    // ── Test 6: duplicate chunk deduplication ─────────────────────────────

    test('duplicate chunks at receiver are deduplicated — final bytes are correct',
        () async {
      final original = Uint8List.fromList(
        List.generate(200, (i) => (i * 7) % 256),
      );

      // Deliver every chunk twice to simulate a relay loop.
      final assembled = await _transferFile(
        bytes: original,
        senderKeys: senderKeys,
        receiverKeys: receiverKeys,
        senderPeerId: senderPeerId,
        receiverPeerId: receiverPeerId,
        transmit: (chunks) => [...chunks, ...chunks], // each chunk delivered twice
      );

      expect(assembled, equals(original));
    });

    // ── Test 7: text message round-trip ───────────────────────────────────

    test('UTF-8 text message bytes survive full pipeline', () async {
      const text = 'Hello from MeshShare! Secure offline transfer. 🔐📡';
      final msgBytes = Uint8List.fromList(utf8.encode(text));

      final sendKey = senderKeys.sessionSendKey(receiverPeerId)!;
      final chunks =
          await FileChunker.chunkFile(msgBytes, type: PayloadType.message);

      // All chunks must carry the message payload type.
      expect(chunks.every((c) => c.payloadType == PayloadType.message), isTrue);

      final encrypted = [
        for (final c in chunks) await AeadCipher.encryptChunk(c, sendKey),
      ];
      final receiveKey = receiverKeys.sessionReceiveKey(senderPeerId)!;
      final assembler = FileAssembler(
        fileId: chunks.first.fileId,
        totalChunks: chunks.length,
      );
      for (final enc in encrypted) {
        final dec = await AeadCipher.decryptChunk(enc, receiveKey);
        assembler.addChunk(dec);
      }

      expect(assembler.isComplete, isTrue);
      final assembled = await assembler.assemble();
      expect(utf8.decode(assembled), equals(text));
    });

    // ── Test 8: single-byte file (edge case) ──────────────────────────────

    test('single-byte file transfers correctly', () async {
      final original = Uint8List.fromList([0xAB]);

      final assembled = await _transferFile(
        bytes: original,
        senderKeys: senderKeys,
        receiverKeys: receiverKeys,
        senderPeerId: senderPeerId,
        receiverPeerId: receiverPeerId,
      );

      expect(assembled, equals(original));
    });

    // ── Test 9: two independent sessions produce different ciphertexts ────

    test('two transfers of identical bytes produce different ciphertexts (unique fileIds)',
        () async {
      final original = Uint8List.fromList(List.generate(40, (_) => 0xAA));

      final sendKey = senderKeys.sessionSendKey(receiverPeerId)!;

      final chunksA = await FileChunker.chunkFile(original, type: PayloadType.file);
      final chunksB = await FileChunker.chunkFile(original, type: PayloadType.file);

      // Different fileIds → different nonces → different ciphertexts
      expect(chunksA.first.fileId, isNot(equals(chunksB.first.fileId)));

      final encA = await AeadCipher.encryptChunk(chunksA.first, sendKey);
      final encB = await AeadCipher.encryptChunk(chunksB.first, sendKey);

      expect(encA.data, isNot(equals(encB.data)));
    });
  });
}
