import 'dart:typed_data';

import 'chunk_model.dart';

/// Collects decrypted chunk payloads and reassembles the original bytes.
///
/// Memory notes: payloads are stored as raw [Uint8List] slices keyed by
/// index (not whole [FileChunk] objects), and [assemble] writes into one
/// pre-sized buffer. A 20 MB transfer therefore costs ~2× its size, not the
/// ~8× a growable `List<int>` used to cost. Chunk integrity (SHA-256) is
/// verified by the caller as each chunk is decrypted, so it is not re-checked
/// here.
class FileAssembler {
  final String fileId;
  final int totalChunks;

  final Map<int, Uint8List> _received = {};

  FileAssembler({required this.fileId, required this.totalChunks});

  /// Returns true if this chunk is new (not a duplicate).
  bool addChunk(FileChunk chunk) {
    if (_received.containsKey(chunk.chunkIndex)) return false;
    _received[chunk.chunkIndex] = chunk.data;
    return true;
  }

  bool get isComplete => _received.length == totalChunks;

  double get progress => totalChunks == 0 ? 0 : _received.length / totalChunks;

  int get receivedCount => _received.length;

  /// Sorted list of chunk indices still missing.
  List<int> get missingChunks {
    final missing = <int>[];
    for (var i = 0; i < totalChunks; i++) {
      if (!_received.containsKey(i)) missing.add(i);
    }
    return missing;
  }

  /// Reassemble all received chunks into the original byte array.
  ///
  /// Throws [StateError] if not all chunks have been received.
  Future<Uint8List> assemble() async {
    if (!isComplete) {
      throw StateError(
        'Cannot assemble: missing ${missingChunks.length} chunks.',
      );
    }

    var total = 0;
    for (var i = 0; i < totalChunks; i++) {
      total += _received[i]!.length;
    }

    final out = Uint8List(total);
    var offset = 0;
    for (var i = 0; i < totalChunks; i++) {
      final part = _received[i]!;
      out.setRange(offset, offset + part.length, part);
      offset += part.length;
    }
    return out;
  }

  /// Release held chunk data (call after [assemble] or on failure).
  void discard() => _received.clear();
}
