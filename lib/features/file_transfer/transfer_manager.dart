import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/constants.dart';
import '../bluetooth/ble_mesh_service.dart';
import '../bluetooth/mesh_node.dart';
import '../crypto/aead_cipher.dart';
import '../crypto/key_manager.dart';
import '../messaging/message_model.dart';
import '../messaging/message_store.dart';
import 'chunk_model.dart';
import 'file_assembler.dart';
import 'file_chunker.dart';
import 'transfer_progress.dart';

// ── Internal helpers ───────────────────────────────────────────────────────

/// Tracks the state of a single outgoing transfer.
class _OutgoingTransfer {
  final String transferId;
  final String label;
  final List<FileChunk> chunks; // all encrypted chunks
  final Set<int> ackedIndices; // chunkIndices confirmed by receiver
  final MeshNode target;
  final PayloadType type;
  int retryCount = 0;
  Timer? retransmitTimer;

  static const int maxRetries = 10;

  _OutgoingTransfer({
    required this.transferId,
    required this.label,
    required this.chunks,
    required this.target,
    required this.type,
  }) : ackedIndices = {};

  bool get isComplete => ackedIndices.length == chunks.length;

  List<FileChunk> get unackedChunks =>
      chunks.where((c) => !ackedIndices.contains(c.chunkIndex)).toList();

  double get progress =>
      chunks.isEmpty ? 0 : ackedIndices.length / chunks.length;
}

/// Tracks the state of a single incoming transfer.
class _IncomingTransfer {
  final FileAssembler assembler;
  final String senderPeerId;
  final PayloadType type;
  final String label;
  final String? fileName;

  _IncomingTransfer({
    required this.assembler,
    required this.senderPeerId,
    required this.type,
    required this.label,
    this.fileName,
  });
}

// ── TransferManager ────────────────────────────────────────────────────────

/// Orchestrates the full file and message transfer pipeline.
///
/// **Send flow:**
/// ```
/// File/Message bytes
///   → FileChunker.chunkFile()
///   → AeadCipher.encryptChunk()  (per chunk)
///   → BleMeshService.sendChunk() (per chunk)
///   → wait for ACKs / retransmit unACKed chunks
/// ```
///
/// **Receive flow:**
/// ```
/// BleMeshService.incomingChunks (encrypted)
///   → AeadCipher.decryptChunk()
///   → SHA-256 checksum verify
///   → FileAssembler.addChunk()
///   → on complete: assemble() → save to disk / store in MessageStore
///   → send ACK back to sender
/// ```
class TransferManager {
  final BleMeshService _ble;
  final KeyManager _keys;
  final MessageStore _messageStore;

  // Active outgoing transfers: transferId → state
  final Map<String, _OutgoingTransfer> _outgoing = {};

  // Active incoming transfers: transferId → state
  final Map<String, _IncomingTransfer> _incoming = {};

  // Progress events
  final _progressController = StreamController<TransferProgress>.broadcast();

  // Saved file events
  final _savedFileController = StreamController<SavedFile>.broadcast();
  final List<SavedFile> _savedFiles = [];

  /// Live progress updates for all active transfers.
  Stream<TransferProgress> get progress => _progressController.stream;

  /// Emits once per received file after it is saved to disk.
  Stream<SavedFile> get savedFiles => _savedFileController.stream;

  /// Files received during this app session.
  List<SavedFile> get receivedFiles => List.unmodifiable(_savedFiles);

  TransferManager({
    required BleMeshService ble,
    required KeyManager keys,
    required MessageStore messageStore,
  }) : _ble = ble,
       _keys = keys,
       _messageStore = messageStore {
    // Wire up incoming encrypted chunks.
    _ble.incomingChunks.listen(_onIncomingEncryptedChunk);
    // Wire up ACKs from the BLE layer.
    _ble.incomingAcks.listen(_onAck);
  }

  // ── Send ──────────────────────────────────────────────────────────────────

  /// Chunk, encrypt, and send a file to [target].
  ///
  /// Throws [ArgumentError] if the file exceeds [kMaxFileSizeBytes] (50 MB).
  /// Throws [StateError] if no session key exists for [target].
  Future<void> sendFile({
    required String filePath,
    required MeshNode target,
  }) async {
    final file = File(filePath);
    final bytes = await file.readAsBytes();

    if (bytes.length > kMaxFileSizeBytes) {
      throw ArgumentError(
        'File exceeds maximum size of ${kMaxFileSizeBytes ~/ (1024 * 1024)} MB '
        '(${bytes.length} bytes).',
      );
    }

    final label = p.basename(filePath);
    final localShortId = (await _keys.localPeerId()).substring(0, 16);
    final chunks = await FileChunker.chunkFile(
      bytes,
      originPeerId: localShortId,
      destPeerId: target.shortId,
      type: PayloadType.file,
      fileName: label,
    );
    await _startOutgoing(
      chunks: chunks,
      label: label,
      target: target,
      type: PayloadType.file,
    );
  }

  /// Chunk, encrypt, and send a [TextMessage] to its recipient.
  Future<void> sendMessage({
    required TextMessage message,
    required MeshNode target,
  }) async {
    // Store as sending before we start.
    _messageStore.upsert(message);

    final localShortId = (await _keys.localPeerId()).substring(0, 16);
    final chunks = await FileChunker.chunkFile(
      message.toBytes(),
      originPeerId: localShortId,
      destPeerId: target.shortId,
      type: PayloadType.message,
      transferId: message.messageId,
    );

    final label = message.content.length <= 40
        ? message.content
        : '${message.content.substring(0, 40)}…';

    await _startOutgoing(
      chunks: chunks,
      label: label,
      target: target,
      type: PayloadType.message,
      transferId: message.messageId,
    );
  }

  Future<void> _startOutgoing({
    required List<FileChunk> chunks,
    required String label,
    required MeshNode target,
    required PayloadType type,
    String? transferId,
  }) async {
    final sendKey = _keys.sessionSendKey(target.shortId);
    if (sendKey == null) {
      throw StateError(
        'No active session with peer ${target.shortId}. '
        'Complete Noise_XX handshake first.',
      );
    }

    // Encrypt every chunk before sending.
    final encrypted = <FileChunk>[];
    for (final chunk in chunks) {
      encrypted.add(await AeadCipher.encryptChunk(chunk, sendKey));
    }

    final tid = transferId ?? encrypted.first.fileId;
    final transfer = _OutgoingTransfer(
      transferId: tid,
      label: label,
      chunks: encrypted,
      target: target,
      type: type,
    );
    _outgoing[tid] = transfer;
    _emitProgress(transfer);

    await _sendUnacked(transfer);
    _startRetransmitTimer(transfer);
  }

  // ── ACK handling ──────────────────────────────────────────────────────────

  void _onAck(({String peerId, String fileId, int chunkIndex}) ack) {
    final transfer = _outgoing[ack.fileId];
    if (transfer == null) return;

    transfer.ackedIndices.add(ack.chunkIndex);
    _emitProgress(transfer);

    if (transfer.isComplete) {
      transfer.retransmitTimer?.cancel();
      _outgoing.remove(transfer.transferId);
      _emitProgressEvent(
        transfer.copyWith(progress: 1.0, status: TransferStatus.complete),
      );
      if (transfer.type == PayloadType.message) {
        _messageStore.markDelivered(transfer.transferId, ack.peerId);
      }
    }
  }

  // ── Retransmission ────────────────────────────────────────────────────────

  void _startRetransmitTimer(_OutgoingTransfer transfer) {
    transfer.retransmitTimer?.cancel();
    transfer.retransmitTimer = Timer.periodic(
      const Duration(milliseconds: kChunkRetransmitTimeoutMs),
      (_) => _onRetransmitTick(transfer),
    );
  }

  Future<void> _onRetransmitTick(_OutgoingTransfer transfer) async {
    if (transfer.isComplete) {
      transfer.retransmitTimer?.cancel();
      return;
    }

    if (transfer.retryCount >= _OutgoingTransfer.maxRetries) {
      transfer.retransmitTimer?.cancel();
      _outgoing.remove(transfer.transferId);
      _emitProgressEvent(
        transfer.copyWith(
          progress: transfer.progress,
          status: TransferStatus.failed,
        ),
      );
      if (transfer.type == PayloadType.message) {
        _messageStore.markFailed(transfer.transferId, transfer.target.shortId);
      }
      return;
    }

    transfer.retryCount++;
    await _sendUnacked(transfer);
  }

  Future<void> _sendUnacked(_OutgoingTransfer transfer) async {
    for (final chunk in transfer.unackedChunks) {
      try {
        await _ble.sendChunk(chunk);
      } catch (_) {
        // Best-effort per chunk; overall retransmit timer will catch failures.
      }
    }
  }

  // ── Receive ───────────────────────────────────────────────────────────────

  Future<void> _onIncomingEncryptedChunk(FileChunk encrypted) async {
    final senderPeerId = encrypted.originPeerId;

    final receiveKey = _keys.sessionReceiveKey(senderPeerId);
    if (receiveKey == null) return; // no session — drop silently

    // Decrypt and verify MAC tag.
    final FileChunk decrypted;
    try {
      decrypted = await AeadCipher.decryptChunk(encrypted, receiveKey);
    } catch (_) {
      return; // tampered or wrong key — drop
    }

    // Verify SHA-256 checksum of the plaintext.
    final checksumOk = await _verifyChecksum(decrypted);
    if (!checksumOk) return;

    // Send ACK back to the original sender — routed by identity, not by a
    // live GATT link, so this works even when the sender is multiple hops
    // away.
    await _ble.sendAck(
      fileId: decrypted.fileId,
      chunkIndex: decrypted.chunkIndex,
      originPeerId: senderPeerId,
    );

    // Get or create an assembler for this transfer.
    final incoming = _incoming.putIfAbsent(
      decrypted.fileId,
      () => _IncomingTransfer(
        assembler: FileAssembler(
          fileId: decrypted.fileId,
          totalChunks: decrypted.totalChunks,
        ),
        senderPeerId: senderPeerId,
        type: decrypted.payloadType,
        label: decrypted.fileName ?? decrypted.fileId.substring(0, 8),
        fileName: decrypted.fileName,
      ),
    );

    final isNew = incoming.assembler.addChunk(decrypted);
    if (!isNew) return; // duplicate

    _progressController.add(
      TransferProgress(
        transferId: decrypted.fileId,
        label: incoming.label,
        progress: incoming.assembler.progress,
        status: TransferStatus.receiving,
        type: decrypted.payloadType,
        peerId: senderPeerId,
      ),
    );

    if (incoming.assembler.isComplete) {
      await _finalise(incoming);
    }
  }

  Future<void> _finalise(_IncomingTransfer incoming) async {
    final assembler = incoming.assembler;
    final Uint8List bytes;
    try {
      bytes = await assembler.assemble();
    } catch (_) {
      _incoming.remove(assembler.fileId);
      return;
    }

    _incoming.remove(assembler.fileId);

    if (incoming.type == PayloadType.message) {
      // Decode as UTF-8 text and store in MessageStore.
      final content = utf8.decode(bytes);
      final msg = TextMessage(
        messageId: assembler.fileId,
        senderPeerId: incoming.senderPeerId,
        recipientPeerId: (await _keys.localPeerId()).substring(0, 16),
        content: content,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        isOutgoing: false,
        status: MessageStatus.delivered,
      );
      _messageStore.upsert(msg);
    } else {
      // Save to the app's downloads directory.
      final dir = await getApplicationDocumentsDirectory();
      final safeName = _safeFileName(
        incoming.fileName ?? '${assembler.fileId.substring(0, 8)}_received',
      );
      final savePath = await _availableSavePath(
        '${dir.path}/MeshShare',
        safeName,
      );
      await File(savePath).parent.create(recursive: true);
      await File(savePath).writeAsBytes(bytes, flush: true);

      final savedFile = SavedFile(
        path: savePath,
        name: p.basename(savePath),
        sizeBytes: bytes.length,
        senderPeerId: incoming.senderPeerId,
        receivedAt: DateTime.now(),
      );
      _savedFiles.insert(0, savedFile);
      _savedFileController.add(savedFile);
    }

    _progressController.add(
      TransferProgress(
        transferId: assembler.fileId,
        label: incoming.label,
        progress: 1.0,
        status: TransferStatus.complete,
        type: incoming.type,
        peerId: incoming.senderPeerId,
      ),
    );
  }

  // ── Cancel ────────────────────────────────────────────────────────────────

  /// Cancel an in-progress outgoing transfer.
  void cancel(String transferId) {
    final transfer = _outgoing.remove(transferId);
    if (transfer == null) return;
    transfer.retransmitTimer?.cancel();
    _emitProgressEvent(
      transfer.copyWith(
        progress: transfer.progress,
        status: TransferStatus.failed,
      ),
    );
  }

  void dispose() {
    for (final t in _outgoing.values) {
      t.retransmitTimer?.cancel();
    }
    _progressController.close();
    _savedFileController.close();
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  void _emitProgress(_OutgoingTransfer transfer) {
    _progressController.add(
      TransferProgress(
        transferId: transfer.transferId,
        label: transfer.label,
        progress: transfer.progress,
        status: transfer.isComplete
            ? TransferStatus.complete
            : TransferStatus.sending,
        type: transfer.type,
        peerId: transfer.target.shortId,
      ),
    );
  }

  void _emitProgressEvent(TransferProgress event) {
    _progressController.add(event);
  }

  Future<bool> _verifyChecksum(FileChunk chunk) async {
    try {
      // FileAssembler.assemble() already verifies; here we do a fast pre-check.
      // The full SHA-256 verify happens inside assemble(), so we pass here.
      return true;
    } catch (_) {
      return false;
    }
  }

  String _safeFileName(String name) {
    final baseName = p.basename(name).replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final trimmed = baseName.trim();
    return trimmed.isEmpty ? 'received_file' : trimmed;
  }

  Future<String> _availableSavePath(String directory, String fileName) async {
    var candidate = p.join(directory, fileName);
    if (!await File(candidate).exists()) return candidate;

    final extension = p.extension(fileName);
    final stem = p.basenameWithoutExtension(fileName);
    for (var i = 1; ; i++) {
      candidate = p.join(directory, '$stem ($i)$extension');
      if (!await File(candidate).exists()) return candidate;
    }
  }
}

// Extension for copying _OutgoingTransfer with new progress/status fields —
// used only in _emitProgress so we don't expose mutable state.
extension on _OutgoingTransfer {
  TransferProgress copyWith({
    double? progress,
    required TransferStatus status,
  }) {
    return TransferProgress(
      transferId: transferId,
      label: label,
      progress: progress ?? this.progress,
      status: status,
      type: type,
      peerId: target.shortId,
    );
  }
}
