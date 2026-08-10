import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshshare/features/file_transfer/chunk_model.dart';
import 'package:meshshare/features/file_transfer/file_assembler.dart';
import 'package:meshshare/features/file_transfer/file_chunker.dart';
import 'package:meshshare/features/messaging/message_model.dart';
import 'package:meshshare/features/messaging/message_store.dart';

void main() {
  group('TextMessage', () {
    test('serialises to UTF-8 bytes and back', () {
      const content = 'Hello, MeshShare!';
      final msg = TextMessage(
        messageId: 'test-id',
        senderPeerId: 'peer-a',
        recipientPeerId: 'peer-b',
        content: content,
        timestampMs: 0,
        isOutgoing: true,
      );

      final bytes = msg.toBytes();
      final recovered = TextMessage.fromBytes(
        bytes: bytes,
        messageId: msg.messageId,
        senderPeerId: msg.senderPeerId,
        recipientPeerId: msg.recipientPeerId,
        timestampMs: msg.timestampMs,
      );

      expect(recovered.content, equals(content));
    });

    test('handles unicode content correctly', () {
      const content = 'Habari! 🌍 Mambo vipi?';
      final msg = TextMessage(
        messageId: 'unicode-test',
        senderPeerId: 'peer-a',
        recipientPeerId: 'peer-b',
        content: content,
        timestampMs: 0,
        isOutgoing: true,
      );

      final recovered = TextMessage.fromBytes(
        bytes: msg.toBytes(),
        messageId: msg.messageId,
        senderPeerId: msg.senderPeerId,
        recipientPeerId: msg.recipientPeerId,
        timestampMs: msg.timestampMs,
      );

      expect(recovered.content, equals(content));
    });
  });

  group('Message chunking pipeline', () {
    test('message chunks carry PayloadType.message', () async {
      final msg = TextMessage(
        messageId: 'msg-001',
        senderPeerId: 'peer-a',
        recipientPeerId: 'peer-b',
        content: 'Test message',
        timestampMs: 0,
        isOutgoing: true,
      );

      final chunks = await FileChunker.chunkFile(
        msg.toBytes(),
        originPeerId: 'aaaaaaaaaaaaaaaa',
        destPeerId: 'bbbbbbbbbbbbbbbb',
        type: PayloadType.message,
        transferId: msg.messageId,
      );

      expect(chunks.every((c) => c.payloadType == PayloadType.message), isTrue);
    });

    test('message survives chunk → reassemble round trip', () async {
      const content =
          'This is a test message that spans multiple BLE chunks '
          'because it is longer than twenty bytes.';
      final msg = TextMessage(
        messageId: 'msg-002',
        senderPeerId: 'peer-a',
        recipientPeerId: 'peer-b',
        content: content,
        timestampMs: 0,
        isOutgoing: true,
      );

      final chunks = await FileChunker.chunkFile(
        msg.toBytes(),
        originPeerId: 'aaaaaaaaaaaaaaaa',
        destPeerId: 'bbbbbbbbbbbbbbbb',
        type: PayloadType.message,
        transferId: msg.messageId,
      );

      final assembler = FileAssembler(
        fileId: msg.messageId,
        totalChunks: chunks.first.totalChunks,
      );
      for (final chunk in chunks) {
        assembler.addChunk(chunk);
      }

      final bytes = await assembler.assemble();
      final recovered = TextMessage.fromBytes(
        bytes: bytes,
        messageId: msg.messageId,
        senderPeerId: msg.senderPeerId,
        recipientPeerId: msg.recipientPeerId,
        timestampMs: msg.timestampMs,
      );

      expect(recovered.content, equals(content));
    });

    test('file chunks still carry PayloadType.file by default', () async {
      final chunks = await FileChunker.chunkFile(
        Uint8List.fromList(List.filled(40, 0x42)),
        originPeerId: 'aaaaaaaaaaaaaaaa',
        destPeerId: 'bbbbbbbbbbbbbbbb',
      );
      expect(chunks.every((c) => c.payloadType == PayloadType.file), isTrue);
    });
  });

  group('MessageStore', () {
    test('stores and retrieves messages by peerId', () {
      final store = MessageStore();
      final msg = TextMessage(
        messageId: 'store-001',
        senderPeerId: 'peer-a',
        recipientPeerId: 'peer-b',
        content: 'Hi',
        timestampMs: 1000,
        isOutgoing: true,
      );

      store.upsert(msg);
      expect(store.messagesFor('peer-b').length, equals(1));
      expect(store.messagesFor('peer-b').first.content, equals('Hi'));
    });

    test('upserting same messageId replaces existing entry', () {
      final store = MessageStore();
      final msg = TextMessage(
        messageId: 'store-002',
        senderPeerId: 'peer-a',
        recipientPeerId: 'peer-b',
        content: 'Hi',
        timestampMs: 1000,
        isOutgoing: true,
        status: MessageStatus.sending,
      );

      store.upsert(msg);
      store.markDelivered('store-002', 'peer-b');

      final updated = store.messagesFor('peer-b').first;
      expect(updated.status, equals(MessageStatus.delivered));
      expect(store.messagesFor('peer-b').length, equals(1));
    });

    test('messages are sorted oldest-first', () {
      final store = MessageStore();
      store.upsert(
        TextMessage(
          messageId: 'later',
          senderPeerId: 'peer-a',
          recipientPeerId: 'peer-b',
          content: 'Second',
          timestampMs: 2000,
          isOutgoing: true,
        ),
      );
      store.upsert(
        TextMessage(
          messageId: 'earlier',
          senderPeerId: 'peer-a',
          recipientPeerId: 'peer-b',
          content: 'First',
          timestampMs: 1000,
          isOutgoing: true,
        ),
      );

      final thread = store.messagesFor('peer-b');
      expect(thread.first.content, equals('First'));
      expect(thread.last.content, equals('Second'));
    });
  });
}
