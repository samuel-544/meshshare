import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshshare/features/crypto/aead_cipher.dart';
import 'package:meshshare/features/crypto/key_manager.dart';
import 'package:meshshare/features/file_transfer/chunk_model.dart';
import 'package:meshshare/features/file_transfer/file_assembler.dart';
import 'package:meshshare/features/file_transfer/file_chunker.dart';
import 'package:meshshare/features/file_transfer/transfer_progress.dart';
import 'package:meshshare/features/messaging/message_model.dart';
import 'package:meshshare/features/messaging/message_store.dart';

void main() {
  // ── Full encrypt → chunk → decrypt → assemble pipeline ────────────────────

  group('Encrypt → chunk → decrypt → assemble pipeline', () {
    late SecretKey sendKey;
    late SecretKey receiveKey;

    setUp(() async {
      final algo = Chacha20.poly1305Aead();
      sendKey    = await algo.newSecretKey();
      receiveKey = await algo.newSecretKey();
    });

    test('file bytes survive a full round trip', () async {
      final original = Uint8List.fromList(
        List.generate(200, (i) => i % 256), // 200 bytes → 10 chunks of 20
      );

      // Sender side: chunk → encrypt
      final plainChunks = await FileChunker.chunkFile(original);
      final encryptedChunks = <FileChunk>[];
      for (final chunk in plainChunks) {
        encryptedChunks.add(await AeadCipher.encryptChunk(chunk, sendKey));
      }

      // Receiver side: decrypt → assemble
      final assembler = FileAssembler(
        fileId: encryptedChunks.first.fileId,
        totalChunks: encryptedChunks.first.totalChunks,
      );
      for (final enc in encryptedChunks) {
        final dec = await AeadCipher.decryptChunk(enc, sendKey);
        assembler.addChunk(dec);
      }

      final result = await assembler.assemble();
      expect(result, equals(original));
    });

    test('out-of-order encrypted chunks are reassembled correctly', () async {
      final original = Uint8List.fromList(List.generate(100, (i) => i));
      final plainChunks = await FileChunker.chunkFile(original);

      final encrypted = <FileChunk>[];
      for (final c in plainChunks) {
        encrypted.add(await AeadCipher.encryptChunk(c, sendKey));
      }

      // Shuffle the encrypted chunks before delivering.
      final shuffled = [...encrypted]..shuffle();

      final assembler = FileAssembler(
        fileId: encrypted.first.fileId,
        totalChunks: encrypted.first.totalChunks,
      );
      for (final enc in shuffled) {
        final dec = await AeadCipher.decryptChunk(enc, sendKey);
        assembler.addChunk(dec);
      }

      final result = await assembler.assemble();
      expect(result, equals(original));
    });

    test('tampered chunk is rejected before it reaches the assembler', () async {
      final plain = (await FileChunker.chunkFile(Uint8List(20))).first;
      final enc   = await AeadCipher.encryptChunk(plain, sendKey);

      final tampered = Uint8List.fromList(enc.data);
      tampered[0] ^= 0xff;
      final tamperedChunk = FileChunk(
        fileId: enc.fileId,
        chunkIndex: enc.chunkIndex,
        totalChunks: enc.totalChunks,
        data: tampered,
        checksum: enc.checksum,
        ttl: enc.ttl,
      );

      expect(
        () => AeadCipher.decryptChunk(tamperedChunk, sendKey),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });
  });

  // ── TransferProgress model ─────────────────────────────────────────────────

  group('TransferProgress', () {
    test('copyWith updates only specified fields', () {
      const p = TransferProgress(
        transferId: 'tid',
        label: 'file.txt',
        progress: 0.5,
        status: TransferStatus.sending,
        type: PayloadType.file,
        peerId: 'peer1',
      );

      final updated = p.copyWith(progress: 1.0, status: TransferStatus.complete);

      expect(updated.progress, equals(1.0));
      expect(updated.status, equals(TransferStatus.complete));
      expect(updated.label, equals('file.txt')); // unchanged
      expect(updated.peerId, equals('peer1'));    // unchanged
    });
  });

  // ── MessageStore integration ───────────────────────────────────────────────

  group('MessageStore delivery tracking', () {
    test('markDelivered transitions status from sending to delivered', () {
      final store = MessageStore();
      final msg = TextMessage(
        messageId: 'msg-001',
        senderPeerId: 'peer-a',
        recipientPeerId: 'peer-b',
        content: 'Hello',
        timestampMs: 0,
        isOutgoing: true,
        status: MessageStatus.sending,
      );
      store.upsert(msg);
      store.markDelivered('msg-001', 'peer-b');
      expect(store.messagesFor('peer-b').first.status,
          equals(MessageStatus.delivered));
    });

    test('markFailed transitions status to failed', () {
      final store = MessageStore();
      final msg = TextMessage(
        messageId: 'msg-002',
        senderPeerId: 'peer-a',
        recipientPeerId: 'peer-b',
        content: 'Hello',
        timestampMs: 0,
        isOutgoing: true,
        status: MessageStatus.sending,
      );
      store.upsert(msg);
      store.markFailed('msg-002', 'peer-b');
      expect(store.messagesFor('peer-b').first.status,
          equals(MessageStatus.failed));
    });
  });

  // ── KeyManager session integration ────────────────────────────────────────

  group('KeyManager session key lifecycle', () {
    late Directory tmpDir;

    setUp(() async {
      tmpDir = await Directory.systemTemp.createTemp('meshshare_phase6_');
    });

    tearDown(() async {
      await tmpDir.delete(recursive: true);
    });

    test('session keys survive store and retrieve cycle', () async {
      final km   = KeyManager.forTesting(tmpDir);
      final algo = Chacha20.poly1305Aead();
      final send = await algo.newSecretKey();
      final recv = await algo.newSecretKey();

      km.storeSession('peer-x', send, recv);

      final retrievedSend = km.sessionSendKey('peer-x');
      final retrievedRecv = km.sessionReceiveKey('peer-x');

      expect(retrievedSend, isNotNull);
      expect(retrievedRecv, isNotNull);

      final sendBytes1 = await send.extractBytes();
      final sendBytes2 = await retrievedSend!.extractBytes();
      expect(sendBytes1, equals(sendBytes2));
    });

    test('encrypt with send key decrypts with same key (session simulation)', () async {
      final km   = KeyManager.forTesting(tmpDir);
      final algo = Chacha20.poly1305Aead();
      final key  = await algo.newSecretKey();

      km.storeSession('peer-x', key, key); // use same key both ways for test

      final plain = (await FileChunker.chunkFile(
        Uint8List.fromList(List.generate(20, (i) => i)),
      )).first;

      final enc = await AeadCipher.encryptChunk(
          plain, km.sessionSendKey('peer-x')!);
      final dec = await AeadCipher.decryptChunk(
          enc, km.sessionReceiveKey('peer-x')!);

      expect(dec.data, equals(plain.data));
    });
  });

  // ── SavedFile model ───────────────────────────────────────────────────────

  group('SavedFile', () {
    test('fields are set correctly', () {
      final now = DateTime.now();
      final sf = SavedFile(
        path: '/data/app/MeshShare/abc123_received',
        name: 'abc123_received',
        sizeBytes: 1024,
        senderPeerId: 'abcdef12',
        receivedAt: now,
      );
      expect(sf.sizeBytes, equals(1024));
      expect(sf.senderPeerId, equals('abcdef12'));
      expect(sf.receivedAt, equals(now));
    });
  });
}
