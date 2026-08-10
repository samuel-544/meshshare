import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../file_transfer/chunk_model.dart';

/// Encrypts and decrypts [FileChunk] data using ChaCha20-Poly1305 AEAD.
///
/// ChaCha20-Poly1305 provides both confidentiality (encryption) and
/// integrity (authentication tag). If even one bit of the ciphertext is
/// modified in transit, decryption throws — the chunk is rejected.
///
/// **Nonce strategy:** The 12-byte nonce is derived deterministically from
/// `SHA-256(fileId_bytes || chunkIndex_big_endian)`. This is safe because
/// each (fileId, chunkIndex) pair is globally unique — a UUID v4 fileId is
/// never reused, so the same (key, nonce) pair can never appear twice.
///
/// **Wire format of FileChunk.data after encryption:**
/// ```
/// [ ciphertext (plaintext.length bytes) | Poly1305 MAC tag (16 bytes) ]
/// ```
class AeadCipher {
  static final _algorithm = Chacha20.poly1305Aead();
  static final _sha256 = Sha256();

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Encrypt [chunk]'s data field in-place and return the encrypted copy.
  ///
  /// [chunk.data] must be plaintext. [chunk.checksum] is already the SHA-256
  /// of the plaintext and must be computed before calling this.
  ///
  /// The [key] is the session key agreed during the Noise_XX handshake.
  static Future<FileChunk> encryptChunk(FileChunk chunk, SecretKey key) async {
    final nonce = await _deriveNonce(chunk.fileId, chunk.chunkIndex);
    final aad = utf8.encode(chunk.fileId); // binds ciphertext to this session

    final secretBox = await _algorithm.encrypt(
      chunk.data,
      secretKey: key,
      nonce: nonce,
      aad: aad,
    );

    // Concatenate ciphertext + 16-byte Poly1305 MAC tag.
    final encrypted = Uint8List(secretBox.cipherText.length + 16);
    encrypted.setAll(0, secretBox.cipherText);
    encrypted.setAll(secretBox.cipherText.length, secretBox.mac.bytes);

    return FileChunk(
      fileId: chunk.fileId,
      chunkIndex: chunk.chunkIndex,
      totalChunks: chunk.totalChunks,
      data: encrypted,
      checksum:
          chunk.checksum, // SHA-256 of plaintext — kept for post-decrypt verify
      ttl: chunk.ttl,
      payloadType: chunk.payloadType,
      originPeerId: chunk.originPeerId,
      destPeerId: chunk.destPeerId,
      fileName: chunk.fileName,
    );
  }

  /// Decrypt [chunk]'s data field and return the plaintext copy.
  ///
  /// Throws [SecretBoxAuthenticationError] if the MAC tag does not match
  /// (i.e. the data was tampered with or the wrong key was used).
  ///
  /// After decryption, the caller should verify [FileChunk.checksum] matches
  /// SHA-256 of the returned plaintext data.
  static Future<FileChunk> decryptChunk(FileChunk chunk, SecretKey key) async {
    final nonce = await _deriveNonce(chunk.fileId, chunk.chunkIndex);
    final aad = utf8.encode(chunk.fileId);

    if (chunk.data.length < 16) {
      throw ArgumentError('Encrypted data too short to contain a MAC tag.');
    }

    final cipherText = chunk.data.sublist(0, chunk.data.length - 16);
    final macBytes = chunk.data.sublist(chunk.data.length - 16);
    final secretBox = SecretBox(cipherText, nonce: nonce, mac: Mac(macBytes));

    final plaintext = await _algorithm.decrypt(
      secretBox,
      secretKey: key,
      aad: aad,
    );

    return FileChunk(
      fileId: chunk.fileId,
      chunkIndex: chunk.chunkIndex,
      totalChunks: chunk.totalChunks,
      data: Uint8List.fromList(plaintext),
      checksum: chunk.checksum,
      ttl: chunk.ttl,
      payloadType: chunk.payloadType,
      originPeerId: chunk.originPeerId,
      destPeerId: chunk.destPeerId,
      fileName: chunk.fileName,
    );
  }

  // ── Internal ───────────────────────────────────────────────────────────────

  /// Derive a deterministic 12-byte nonce from the transfer session ID and
  /// the chunk's position. Using a deterministic nonce is safe here because
  /// UUID v4 fileIds are never reused across sessions.
  static Future<List<int>> _deriveNonce(String fileId, int chunkIndex) async {
    final input = Uint8List(fileId.length + 4);
    final fileIdBytes = utf8.encode(fileId);
    input.setAll(0, fileIdBytes);
    // Append chunkIndex as big-endian uint32.
    input[fileId.length] = (chunkIndex >> 24) & 0xff;
    input[fileId.length + 1] = (chunkIndex >> 16) & 0xff;
    input[fileId.length + 2] = (chunkIndex >> 8) & 0xff;
    input[fileId.length + 3] = chunkIndex & 0xff;

    final hash = await _sha256.hash(input);
    return hash.bytes.sublist(
      0,
      12,
    ); // ChaCha20-Poly1305 requires exactly 12 bytes
  }
}
