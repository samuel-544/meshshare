import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../../core/constants.dart';
import '../../core/utils.dart';
import 'chunk_model.dart';

/// Splits raw bytes into [FileChunk] objects ready for encryption.
///
/// Works for both file transfers and text messages — pass the appropriate
/// [PayloadType] so the receiver knows how to handle the reassembled bytes.
///
/// Note: returns *plaintext* chunks — the crypto layer (`AeadCipher`)
/// encrypts each chunk's [FileChunk.data] before BLE transmission.
class FileChunker {
  /// Split [bytes] into chunks of [kBleChunkPayloadBytes] each.
  ///
  /// [type] defaults to [PayloadType.file]; pass [PayloadType.message]
  /// when chunking a text message.
  ///
  /// Returns an ordered list; each chunk has a pre-computed SHA-256 checksum
  /// of its plaintext payload so the receiver can verify after decryption.
  static Future<List<FileChunk>> chunkFile(
    Uint8List bytes, {
    required String originPeerId,
    required String destPeerId,
    PayloadType type = PayloadType.file,
    String? transferId, // pass message ID when type == message
    String? fileName,
  }) async {
    final sha256 = Sha256();
    final fileId = transferId ?? generateUuid();
    final totalChunks = (bytes.length / kBleChunkPayloadBytes).ceil().clamp(
      1,
      1 << 31,
    );
    final chunks = <FileChunk>[];

    for (int i = 0; i < totalChunks; i++) {
      final start = i * kBleChunkPayloadBytes;
      final end = (start + kBleChunkPayloadBytes).clamp(0, bytes.length);
      final payload = bytes.sublist(start, end);

      final hash = await sha256.hash(payload);
      final checksum = Uint8List.fromList(hash.bytes);

      chunks.add(
        FileChunk(
          fileId: fileId,
          chunkIndex: i,
          totalChunks: totalChunks,
          data: Uint8List.fromList(payload),
          checksum: checksum,
          ttl: kDefaultTtl,
          originPeerId: originPeerId,
          destPeerId: destPeerId,
          payloadType: type,
          fileName: type == PayloadType.file ? fileName : null,
        ),
      );
    }

    return chunks;
  }
}
