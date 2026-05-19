import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshshare/core/constants.dart';
import 'package:meshshare/features/crypto/aead_cipher.dart';
import 'package:meshshare/features/crypto/key_manager.dart';
import 'package:meshshare/features/crypto/noise_handshake.dart';
import 'package:meshshare/features/file_transfer/chunk_model.dart';
import 'package:meshshare/features/file_transfer/file_chunker.dart';

void main() {
  // ── AeadCipher ─────────────────────────────────────────────────────────────

  group('AeadCipher', () {
    late SecretKey key;

    setUp(() async {
      key = await Chacha20.poly1305Aead().newSecretKey();
    });

    test('encrypt then decrypt yields original plaintext', () async {
      final chunks = await FileChunker.chunkFile(
        Uint8List.fromList(List.generate(60, (i) => i)),
      );

      for (final plain in chunks) {
        final encrypted = await AeadCipher.encryptChunk(plain, key);
        final decrypted = await AeadCipher.decryptChunk(encrypted, key);
        expect(decrypted.data, equals(plain.data));
      }
    });

    test('encrypted data differs from plaintext', () async {
      final plain = (await FileChunker.chunkFile(
        Uint8List.fromList(List.filled(20, 0xAB)),
      )).first;

      final encrypted = await AeadCipher.encryptChunk(plain, key);
      expect(encrypted.data, isNot(equals(plain.data)));
    });

    test('tampered ciphertext (flipped bit) throws on decrypt', () async {
      final plain = (await FileChunker.chunkFile(Uint8List(20))).first;
      final encrypted = await AeadCipher.encryptChunk(plain, key);

      // Flip the first byte of the ciphertext.
      final tampered = Uint8List.fromList(encrypted.data);
      tampered[0] ^= 0xff;

      final tamperedChunk = FileChunk(
        fileId: encrypted.fileId,
        chunkIndex: encrypted.chunkIndex,
        totalChunks: encrypted.totalChunks,
        data: tampered,
        checksum: encrypted.checksum,
        ttl: encrypted.ttl,
      );

      expect(
        () => AeadCipher.decryptChunk(tamperedChunk, key),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('wrong key throws on decrypt', () async {
      final plain = (await FileChunker.chunkFile(Uint8List(20))).first;
      final encrypted = await AeadCipher.encryptChunk(plain, key);
      final wrongKey  = await Chacha20.poly1305Aead().newSecretKey();

      expect(
        () => AeadCipher.decryptChunk(encrypted, wrongKey),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('different chunks produce different ciphertexts (unique nonces)', () async {
      final chunks = await FileChunker.chunkFile(
        Uint8List.fromList(List.filled(40, 0x11)),
      );
      final enc0 = await AeadCipher.encryptChunk(chunks[0], key);
      final enc1 = await AeadCipher.encryptChunk(chunks[1], key);

      // Same key, different nonces → different ciphertexts.
      expect(enc0.data, isNot(equals(enc1.data)));
    });

    test('encryption is deterministic for same inputs', () async {
      final plain = (await FileChunker.chunkFile(Uint8List(20))).first;
      final enc1 = await AeadCipher.encryptChunk(plain, key);
      final enc2 = await AeadCipher.encryptChunk(plain, key);
      expect(enc1.data, equals(enc2.data));
    });

    test('fileId and metadata are preserved after encrypt/decrypt', () async {
      final plain = (await FileChunker.chunkFile(Uint8List(20))).first;
      final enc   = await AeadCipher.encryptChunk(plain, key);
      final dec   = await AeadCipher.decryptChunk(enc, key);

      expect(dec.fileId,      equals(plain.fileId));
      expect(dec.chunkIndex,  equals(plain.chunkIndex));
      expect(dec.totalChunks, equals(plain.totalChunks));
      expect(dec.ttl,         equals(kDefaultTtl));
      expect(dec.checksum,    equals(plain.checksum));
    });
  });

  // ── Noise_XX Handshake ─────────────────────────────────────────────────────

  group('NoiseHandshake', () {
    late SimpleKeyPairData initiatorStatic;
    late SimpleKeyPairData responderStatic;

    setUp(() async {
      final x25519 = X25519();
      initiatorStatic = await x25519.newKeyPair()
          .then((kp) => kp.extract());
      responderStatic = await x25519.newKeyPair()
          .then((kp) => kp.extract());
    });

    test('full handshake completes without error', () async {
      final initiator = await NoiseInitiator.create(initiatorStatic);
      final responder = await NoiseResponder.create(responderStatic);

      final msg1 = await initiator.writeMessage1();
      final msg2 = await responder.readMsg1WriteMsg2(msg1);
      final msg3 = await initiator.readMsg2WriteMsg3(msg2);
      await responder.readMessage3(msg3);

      expect(initiator.result, isNotNull);
      expect(responder.result, isNotNull);
    });

    test('both sides derive the same transport keys', () async {
      final initiator = await NoiseInitiator.create(initiatorStatic);
      final responder = await NoiseResponder.create(responderStatic);

      final msg1 = await initiator.writeMessage1();
      final msg2 = await responder.readMsg1WriteMsg2(msg1);
      final msg3 = await initiator.readMsg2WriteMsg3(msg2);
      await responder.readMessage3(msg3);

      // initiator.sendKey should equal responder.receiveKey (i → r direction)
      final iSendBytes = await initiator.result.sendKey.extractBytes();
      final rRecvBytes = await responder.result.receiveKey.extractBytes();
      expect(iSendBytes, equals(rRecvBytes));

      // responder.sendKey should equal initiator.receiveKey (r → i direction)
      final rSendBytes = await responder.result.sendKey.extractBytes();
      final iRecvBytes = await initiator.result.receiveKey.extractBytes();
      expect(rSendBytes, equals(iRecvBytes));
    });

    test('each peer learns the other\'s static public key', () async {
      final initiator = await NoiseInitiator.create(initiatorStatic);
      final responder = await NoiseResponder.create(responderStatic);

      final msg1 = await initiator.writeMessage1();
      final msg2 = await responder.readMsg1WriteMsg2(msg1);
      final msg3 = await initiator.readMsg2WriteMsg3(msg2);
      await responder.readMessage3(msg3);

      expect(
        initiator.result.remoteStaticPublicKey.bytes,
        equals(responderStatic.publicKey.bytes),
      );
      expect(
        responder.result.remoteStaticPublicKey.bytes,
        equals(initiatorStatic.publicKey.bytes),
      );
    });

    test('two independent handshakes produce different keys', () async {
      Future<List<int>> runHandshake() async {
        final x25519 = X25519();
        final iKp = await x25519.newKeyPair().then((kp) => kp.extract());
        final rKp = await x25519.newKeyPair().then((kp) => kp.extract());

        final ini = await NoiseInitiator.create(iKp);
        final res = await NoiseResponder.create(rKp);

        final m1 = await ini.writeMessage1();
        final m2 = await res.readMsg1WriteMsg2(m1);
        final m3 = await ini.readMsg2WriteMsg3(m2);
        await res.readMessage3(m3);

        return ini.result.sendKey.extractBytes();
      }

      final keys1 = await runHandshake();
      final keys2 = await runHandshake();
      expect(keys1, isNot(equals(keys2)));
    });

    test('tampered message 2 causes decrypt to throw', () async {
      final initiator = await NoiseInitiator.create(initiatorStatic);
      final responder = await NoiseResponder.create(responderStatic);

      final msg1 = await initiator.writeMessage1();
      final msg2 = await responder.readMsg1WriteMsg2(msg1);

      // Flip a byte in the encrypted static public key portion of msg2.
      final tampered = Uint8List.fromList(msg2);
      tampered[40] ^= 0xff; // inside the enc(s_r) ciphertext

      expect(
        () => initiator.readMsg2WriteMsg3(tampered),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });
  });

  // ── KeyManager ────────────────────────────────────────────────────────────

  group('KeyManager', () {
    late Directory tmpDir;

    setUp(() async {
      tmpDir = await Directory.systemTemp.createTemp('meshshare_test_');
    });

    tearDown(() async {
      await tmpDir.delete(recursive: true);
    });

    test('generates a keypair and saves it to disk', () async {
      final km  = KeyManager.forTesting(tmpDir);
      final kp  = await km.getOrCreateStaticKeyPair();

      expect(kp.bytes.length, equals(32));
      expect(kp.publicKey.bytes.length, equals(32));

      final keyFile = File('${tmpDir.path}/meshshare_static_key.bin');
      expect(await keyFile.exists(), isTrue);
      expect((await keyFile.readAsBytes()).length, equals(64));
    });

    test('returns the same keypair on subsequent calls (in-memory cache)', () async {
      final km = KeyManager.forTesting(tmpDir);
      final kp1 = await km.getOrCreateStaticKeyPair();
      final kp2 = await km.getOrCreateStaticKeyPair();
      expect(identical(kp1, kp2), isTrue);
    });

    test('reloads the same keypair from disk after restart (new instance)', () async {
      final km1 = KeyManager.forTesting(tmpDir);
      final kp1 = await km1.getOrCreateStaticKeyPair();

      final km2 = KeyManager.forTesting(tmpDir); // simulates app restart
      final kp2 = await km2.getOrCreateStaticKeyPair();

      expect(kp1.bytes, equals(kp2.bytes));
      expect(kp1.publicKey.bytes, equals(kp2.publicKey.bytes));
    });

    test('localPeerId is a 64-char hex string', () async {
      final km = KeyManager.forTesting(tmpDir);
      final id = await km.localPeerId();
      expect(id.length, equals(64));
      expect(RegExp(r'^[0-9a-f]+$').hasMatch(id), isTrue);
    });

    test('localPeerId is stable across instances (same underlying key)', () async {
      final id1 = await KeyManager.forTesting(tmpDir).localPeerId();
      final id2 = await KeyManager.forTesting(tmpDir).localPeerId();
      expect(id1, equals(id2));
    });

    test('session keys stored and retrieved correctly', () async {
      final km = KeyManager.forTesting(tmpDir);
      final algo = Chacha20.poly1305Aead();
      final send = await algo.newSecretKey();
      final recv = await algo.newSecretKey();
      const peerId = 'abcdef1234';

      km.storeSession(peerId, send, recv);

      expect(km.sessionSendKey(peerId),    isNotNull);
      expect(km.sessionReceiveKey(peerId), isNotNull);
      expect(km.hasSession(peerId),        isTrue);
    });

    test('clearSession removes keys for that peer only', () async {
      final km   = KeyManager.forTesting(tmpDir);
      final algo = Chacha20.poly1305Aead();

      km.storeSession('peer-a', await algo.newSecretKey(), await algo.newSecretKey());
      km.storeSession('peer-b', await algo.newSecretKey(), await algo.newSecretKey());

      km.clearSession('peer-a');

      expect(km.hasSession('peer-a'), isFalse);
      expect(km.hasSession('peer-b'), isTrue);
    });

    test('session keys return null for unknown peer', () async {
      final km = KeyManager.forTesting(tmpDir);
      expect(km.sessionSendKey('nobody'),    isNull);
      expect(km.sessionReceiveKey('nobody'), isNull);
    });
  });
}
