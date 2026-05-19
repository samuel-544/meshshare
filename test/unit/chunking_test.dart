import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshshare/core/constants.dart';
import 'package:meshshare/features/file_transfer/file_chunker.dart';

void main() {
  group('FileChunker', () {
    test('splits file into correct number of chunks', () async {
      final data = Uint8List(100); // 100 bytes → ceil(100/20) = 5 chunks
      final chunks = await FileChunker.chunkFile(data);
      expect(chunks.length, equals(5));
    });

    test('all chunks share the same fileId', () async {
      final data = Uint8List(50);
      final chunks = await FileChunker.chunkFile(data);
      final id = chunks.first.fileId;
      expect(chunks.every((c) => c.fileId == id), isTrue);
    });

    test('chunkIndex is sequential from 0', () async {
      final data = Uint8List(60);
      final chunks = await FileChunker.chunkFile(data);
      for (int i = 0; i < chunks.length; i++) {
        expect(chunks[i].chunkIndex, equals(i));
      }
    });

    test('last chunk may be smaller than kBleChunkPayloadBytes', () async {
      // 45 bytes → 2 full chunks (20+20) + 1 partial (5)
      final data = Uint8List(45);
      final chunks = await FileChunker.chunkFile(data);
      expect(chunks.last.data.length, equals(5));
    });

    test('each chunk carries a valid 32-byte checksum', () async {
      final data = Uint8List(20);
      final chunks = await FileChunker.chunkFile(data);
      expect(chunks.first.checksum.length, equals(32));
    });

    test('TTL is set to kDefaultTtl', () async {
      final data = Uint8List(20);
      final chunks = await FileChunker.chunkFile(data);
      expect(chunks.first.ttl, equals(kDefaultTtl));
    });
  });
}
