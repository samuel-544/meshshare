import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'chunk_model.dart';

/// Collects decrypted [FileChunk]s and reassembles the original file bytes.
class FileAssembler {
  final String fileId;
  final int totalChunks;

  final Map<int, FileChunk> _received = {};

  FileAssembler({required this.fileId, required this.totalChunks});

  /// Returns true if this chunk is new (not a duplicate).
  bool addChunk(FileChunk chunk) {
    if (_received.containsKey(chunk.chunkIndex)) return false;
    _received[chunk.chunkIndex] = chunk;
    return true;
  }

  bool get isComplete => _received.length == totalChunks;

  double get progress => _received.length / totalChunks;

  /// Sorted list of chunk indices still missing.
  List<int> get missingChunks {
    final all = List.generate(totalChunks, (i) => i).toSet();
    return all.difference(_received.keys.toSet()).toList()..sort();
  }

  /// Reassemble and verify all chunks.
  ///
  /// Each chunk's [FileChunk.data] must already be *decrypted* plaintext.
  /// Throws [StateError] if not all chunks received.
  /// Throws [Exception] if a chunk's checksum does not match.
  Future<Uint8List> assemble() async {
    if (!isComplete) {
      throw StateError('Cannot assemble: missing ${missingChunks.length} chunks.');
    }

    final sha256 = Sha256();
    final sortedChunks = _received.values.toList()
      ..sort((a, b) => a.chunkIndex.compareTo(b.chunkIndex));

    final buffer = <int>[];
    for (final chunk in sortedChunks) {
      final hash = await sha256.hash(chunk.data);
      if (!_bytesEqual(Uint8List.fromList(hash.bytes), chunk.checksum)) {
        throw Exception(
            'Checksum mismatch on chunk ${chunk.chunkIndex} of $fileId');
      }
      buffer.addAll(chunk.data);
    }

    return Uint8List.fromList(buffer);
  }

  bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
