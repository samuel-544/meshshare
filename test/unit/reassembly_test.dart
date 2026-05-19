import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshshare/features/file_transfer/file_assembler.dart';
import 'package:meshshare/features/file_transfer/file_chunker.dart';

void main() {
  group('FileAssembler', () {
    test('reassembles chunks in order', () async {
      final original = Uint8List.fromList(List.generate(60, (i) => i % 256));
      final chunks = await FileChunker.chunkFile(original);

      final assembler = FileAssembler(
        fileId: chunks.first.fileId,
        totalChunks: chunks.first.totalChunks,
      );
      for (final chunk in chunks) {
        assembler.addChunk(chunk);
      }

      final result = await assembler.assemble();
      expect(result, equals(original));
    });

    test('reassembles out-of-order chunks correctly', () async {
      final original = Uint8List.fromList(List.generate(60, (i) => i % 256));
      final chunks = await FileChunker.chunkFile(original);
      final shuffled = [...chunks]..shuffle();

      final assembler = FileAssembler(
        fileId: chunks.first.fileId,
        totalChunks: chunks.first.totalChunks,
      );
      for (final chunk in shuffled) {
        assembler.addChunk(chunk);
      }

      final result = await assembler.assemble();
      expect(result, equals(original));
    });

    test('isComplete is false while chunks are missing', () async {
      final original = Uint8List(40); // 2 chunks
      final chunks = await FileChunker.chunkFile(original);

      final assembler = FileAssembler(
        fileId: chunks.first.fileId,
        totalChunks: chunks.first.totalChunks,
      );
      assembler.addChunk(chunks.first);

      expect(assembler.isComplete, isFalse);
      expect(assembler.missingChunks, contains(1));
    });

    test('throws StateError if assembled before complete', () async {
      final original = Uint8List(40);
      final chunks = await FileChunker.chunkFile(original);

      final assembler = FileAssembler(
        fileId: chunks.first.fileId,
        totalChunks: chunks.first.totalChunks,
      );
      assembler.addChunk(chunks.first); // only 1 of 2

      expect(() => assembler.assemble(), throwsStateError);
    });

    test('duplicate chunks are ignored', () async {
      final original = Uint8List(20); // 1 chunk
      final chunks = await FileChunker.chunkFile(original);

      final assembler = FileAssembler(
        fileId: chunks.first.fileId,
        totalChunks: 1,
      );
      final first = assembler.addChunk(chunks.first);
      final second = assembler.addChunk(chunks.first); // duplicate

      expect(first, isTrue);
      expect(second, isFalse);
    });
  });
}
