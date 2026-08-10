import 'dart:convert';
import 'dart:typed_data';

import '../../core/utils.dart';

/// Distinguishes what kind of payload is being carried in a [FileChunk].
enum PayloadType {
  /// Binary file (image, document, video, etc.)
  file,

  /// UTF-8 text message.
  message;

  int get wire => index; // 0 = file, 1 = message

  static PayloadType fromWire(int v) => PayloadType.values[v];
}

/// A single encrypted unit of a file or message transfer.
///
/// Serialisation layout (binary, sent over BLE):
/// ```
///  0               1               2               3
///  0 1 2 3 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 4 5 6 7
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |                  fileId (36 bytes UTF-8 UUID)                  |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |         chunkIndex (4 bytes, big-endian uint32)                |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |         totalChunks (4 bytes, big-endian uint32)               |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// | type (1 byte) |  ttl (1 byte) | originPeerId (8 bytes)         |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// | destPeerId (8 bytes) | fileNameLen (2) | dataLen (2)           |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// | fileName + data (dataLen bytes) + checksum (32 bytes SHA-256)   |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// ```
///
/// [originPeerId] and [destPeerId] are the true end-to-end sender/recipient
/// identity (`MeshNode.shortId`), set once by the originating device and left
/// untouched by every relay hop — unlike [ttl], which decrements per hop.
/// This is what lets a multi-hop recipient look up the correct session key
/// regardless of which relay actually delivered the packet.
class FileChunk {
  /// Transfer session identifier (UUID v4, 36 ASCII chars).
  final String fileId;

  /// Zero-based position of this chunk in the complete file.
  final int chunkIndex;

  /// Total number of chunks that make up the file.
  final int totalChunks;

  /// ChaCha20-Poly1305 encrypted payload.
  final Uint8List data;

  /// SHA-256 of the *plaintext* chunk — verified after decryption.
  final Uint8List checksum;

  /// Remaining hop count; decremented at each relay. Drop if reaches 0.
  final int ttl;

  /// Whether this chunk carries a file or a text message.
  final PayloadType payloadType;

  /// Identity ([MeshNode.shortId]) of the device that originated this
  /// transfer — the true end-to-end sender, unchanged across relay hops.
  final String originPeerId;

  /// Identity ([MeshNode.shortId]) of the intended final recipient.
  final String destPeerId;

  /// Original file name for file payloads.
  final String? fileName;

  const FileChunk({
    required this.fileId,
    required this.chunkIndex,
    required this.totalChunks,
    required this.data,
    required this.checksum,
    required this.ttl,
    required this.originPeerId,
    required this.destPeerId,
    this.payloadType = PayloadType.file,
    this.fileName,
  });

  /// Deduplication key used in the relay LRU cache.
  String get dedupKey => '$fileId:$chunkIndex';

  /// Returns a copy with TTL decremented by 1 (for relay forwarding).
  FileChunk decrementTtl() {
    return FileChunk(
      fileId: fileId,
      chunkIndex: chunkIndex,
      totalChunks: totalChunks,
      data: data,
      checksum: checksum,
      ttl: ttl - 1,
      payloadType: payloadType,
      originPeerId: originPeerId,
      destPeerId: destPeerId,
      fileName: fileName,
    );
  }

  /// Serialise to bytes for BLE transmission.
  Uint8List toBytes() {
    final fileIdBytes = fileId.codeUnits;
    final fileNameBytes = utf8.encode(fileName ?? '');
    if (fileNameBytes.length > 65535) {
      throw ArgumentError('File name is too long to serialise.');
    }
    final originBytes = hexToBytes(originPeerId);
    final destBytes = hexToBytes(destPeerId);
    if (originBytes.length != 8 || destBytes.length != 8) {
      throw ArgumentError('originPeerId/destPeerId must be 8-byte shortIds.');
    }
    // fileId(36) + chunkIndex(4) + totalChunks(4) + type(1) + ttl(1)
    // + originPeerId(8) + destPeerId(8)
    // + fileNameLen(2) + dataLen(2) + fileName + data + checksum(32)
    final totalLen =
        36 +
        4 +
        4 +
        1 +
        1 +
        8 +
        8 +
        2 +
        2 +
        fileNameBytes.length +
        data.length +
        32;
    final buf = ByteData(totalLen);
    int offset = 0;

    for (int i = 0; i < 36; i++) {
      buf.setUint8(offset++, fileIdBytes[i]);
    }
    buf.setUint32(offset, chunkIndex, Endian.big);
    offset += 4;
    buf.setUint32(offset, totalChunks, Endian.big);
    offset += 4;
    buf.setUint8(offset++, payloadType.wire);
    buf.setUint8(offset++, ttl);

    final result = buf.buffer.asUint8List();
    result.setRange(offset, offset + 8, originBytes);
    offset += 8;
    result.setRange(offset, offset + 8, destBytes);
    offset += 8;

    buf.setUint16(offset, fileNameBytes.length, Endian.big);
    offset += 2;
    buf.setUint16(offset, data.length, Endian.big);
    offset += 2;

    result.setRange(offset, offset + fileNameBytes.length, fileNameBytes);
    offset += fileNameBytes.length;
    result.setRange(offset, offset + data.length, data);
    offset += data.length;
    result.setRange(offset, offset + 32, checksum);

    return result;
  }

  /// Deserialise from bytes received over BLE.
  factory FileChunk.fromBytes(Uint8List bytes) {
    int offset = 0;
    final fileId = String.fromCharCodes(bytes.sublist(offset, offset + 36));
    offset += 36;
    final bd = ByteData.sublistView(bytes);
    final chunkIndex = bd.getUint32(offset, Endian.big);
    offset += 4;
    final totalChunks = bd.getUint32(offset, Endian.big);
    offset += 4;
    final payloadType = PayloadType.fromWire(bd.getUint8(offset++));
    final ttl = bd.getUint8(offset++);
    final originPeerId = bytesToHex(bytes.sublist(offset, offset + 8));
    offset += 8;
    final destPeerId = bytesToHex(bytes.sublist(offset, offset + 8));
    offset += 8;
    final fileNameLen = bd.getUint16(offset, Endian.big);
    offset += 2;
    final dataLen = bd.getUint16(offset, Endian.big);
    offset += 2;
    final fileName = fileNameLen == 0
        ? null
        : utf8.decode(bytes.sublist(offset, offset + fileNameLen));
    offset += fileNameLen;
    final data = bytes.sublist(offset, offset + dataLen);
    offset += dataLen;
    final checksum = bytes.sublist(offset, offset + 32);

    return FileChunk(
      fileId: fileId,
      chunkIndex: chunkIndex,
      totalChunks: totalChunks,
      data: data,
      checksum: checksum,
      ttl: ttl,
      originPeerId: originPeerId,
      destPeerId: destPeerId,
      payloadType: payloadType,
      fileName: fileName,
    );
  }
}
