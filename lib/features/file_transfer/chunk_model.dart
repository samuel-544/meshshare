import 'dart:typed_data';

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
/// | type (1 byte) |  ttl (1 byte) |  dataLen (2 bytes)             |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |  data (dataLen bytes) + checksum (32 bytes SHA-256 plaintext)  |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// ```
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

  const FileChunk({
    required this.fileId,
    required this.chunkIndex,
    required this.totalChunks,
    required this.data,
    required this.checksum,
    required this.ttl,
    this.payloadType = PayloadType.file,
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
    );
  }

  /// Serialise to bytes for BLE transmission.
  Uint8List toBytes() {
    final fileIdBytes = fileId.codeUnits;
    // fileId(36) + chunkIndex(4) + totalChunks(4) + type(1) + ttl(1) + dataLen(2) + data + checksum(32)
    final totalLen = 36 + 4 + 4 + 1 + 1 + 2 + data.length + 32;
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
    buf.setUint16(offset, data.length, Endian.big);
    offset += 2;

    final result = buf.buffer.asUint8List();
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
    final dataLen = bd.getUint16(offset, Endian.big);
    offset += 2;
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
      payloadType: payloadType,
    );
  }
}
