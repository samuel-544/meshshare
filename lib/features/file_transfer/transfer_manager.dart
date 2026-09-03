import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/constants.dart';
import '../../core/log.dart';
import '../bluetooth/ble_mesh_service.dart';
import '../bluetooth/mesh_node.dart';
import '../crypto/aead_cipher.dart';
import '../crypto/key_manager.dart';
import '../messaging/message_model.dart';
import '../messaging/message_store.dart';
import '../peers/peer_contact_store.dart';
import 'chunk_model.dart';
import 'file_assembler.dart';
import 'file_chunker.dart';
import 'transfer_progress.dart';

// ── Internal helpers ───────────────────────────────────────────────────────

/// Placeholder swapped in for a plaintext chunk right after it is encrypted,
/// so the real (large) chunk can be garbage-collected during encryption.
final FileChunk _emptyChunk = FileChunk(
  fileId: '0' * 36,
  chunkIndex: 0,
  totalChunks: 0,
  data: Uint8List(0),
  checksum: Uint8List(32),
  ttl: 0,
  originPeerId: '0000000000000000',
  destPeerId: '0000000000000000',
);

/// Tracks the state of a single outgoing transfer.
///
/// Delivery uses a fixed-size sliding window: at most [kTransferWindowSize]
/// chunks are "in flight" (sent, not yet ACKed) at once. As ACKs arrive the
/// window advances. A transfer whose peer disconnects is *paused*, not
/// failed, and resumes from where it left off when the peer returns.
class _OutgoingTransfer {
  final String transferId;
  final String label;
  final List<FileChunk> chunks; // all encrypted chunks
  final Set<int> ackedIndices = {};
  final Set<int> inFlight = {};
  final MeshNode target;
  final PayloadType type;
  Timer? retransmitTimer;

  /// Index of the next chunk that has never been sent.
  int nextIndex = 0;

  /// Guards [_pump] against re-entrancy (it awaits between sends).
  bool pumping = false;

  /// chunkIndex → last time we put this chunk on the wire (Unix ms).
  final Map<int, int> lastSentMs = {};

  /// Last time a *new* ACK arrived — used to detect a stalled transfer.
  int lastProgressMs = DateTime.now().millisecondsSinceEpoch;

  /// When the peer went offline (null while the peer is connected).
  int? pausedSinceMs;

  _OutgoingTransfer({
    required this.transferId,
    required this.label,
    required this.chunks,
    required this.target,
    required this.type,
  });

  bool get isComplete => ackedIndices.length == chunks.length;
  bool get isPaused => pausedSinceMs != null;

  double get progress =>
      chunks.isEmpty ? 0 : ackedIndices.length / chunks.length;

  /// In-flight chunks that have gone unACKed past the retransmit timeout.
  List<FileChunk> overdue(int now) => [
    for (final i in inFlight)
      if (!ackedIndices.contains(i) &&
          now - (lastSentMs[i] ?? 0) >= kChunkRetransmitTimeoutMs)
        chunks[i],
  ];
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

  /// Optional block list. When a sender is blocked, inbound chunks from them
  /// are dropped here — on the local delivery path only. Mesh relaying in
  /// [BleMeshService] never consults this, so a blocked peer's traffic bound
  /// for other nodes is still forwarded.
  final PeerContactStore? _contacts;

  // Active outgoing transfers: transferId → state
  final Map<String, _OutgoingTransfer> _outgoing = {};

  // Active incoming transfers: transferId → state
  final Map<String, _IncomingTransfer> _incoming = {};

  /// Serialises incoming-chunk handling so assembler writes and the
  /// create-on-first-chunk step can't race across concurrent stream events.
  Future<void> _receiveQueue = Future<void>.value();

  static final _sha256 = Sha256();

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
    PeerContactStore? contacts,
  }) : _ble = ble,
       _keys = keys,
       _messageStore = messageStore,
       _contacts = contacts {
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
    final label = p.basename(filePath);
    final localShortId = (await _keys.localPeerId()).substring(0, 16);
    // Read + chunk in a helper so the whole-file byte buffer is released
    // before we start holding the (equally large) list of chunks.
    final chunks = await _readAndChunk(
      filePath,
      originPeerId: localShortId,
      destPeerId: target.shortId,
      fileName: label,
    );
    await _startOutgoing(
      chunks: chunks,
      label: label,
      target: target,
      type: PayloadType.file,
    );
  }

  Future<List<FileChunk>> _readAndChunk(
    String filePath, {
    required String originPeerId,
    required String destPeerId,
    required String fileName,
  }) async {
    final bytes = await File(filePath).readAsBytes();
    if (bytes.length > kMaxFileSizeBytes) {
      throw ArgumentError(
        'File exceeds maximum size of ${kMaxFileSizeBytes ~/ (1024 * 1024)} MB '
        '(${bytes.length} bytes).',
      );
    }
    return FileChunker.chunkFile(
      bytes,
      originPeerId: originPeerId,
      destPeerId: destPeerId,
      type: PayloadType.file,
      fileName: fileName,
      payloadBytes: _ble.maxChunkPayloadBytes,
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
      payloadBytes: _ble.maxChunkPayloadBytes,
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
    final tid = transferId ?? chunks.first.fileId;

    if (_contacts?.isBlocked(target.shortId) ?? false) {
      throw StateError(
        'You have blocked ${target.shortId}. Unblock this contact to send '
        'messages or files.',
      );
    }

    // Encrypt every chunk with a transfer-scoped key derived from both
    // devices' *static* keys. Unlike the live Noise session key, this
    // survives a mid-transfer disconnect + re-handshake, so chunks queued
    // before the drop still decrypt afterwards.
    final key = await _keys.deriveTransferKey(target.shortId, tid);
    meshLog(
      '_startOutgoing target=${target.shortId} '
      'deviceId=${target.deviceId} key=${key != null} chunks=${chunks.length}',
    );
    if (key == null) {
      throw StateError(
        'No completed handshake with peer ${target.shortId}. '
        'Connect to the peer first.',
      );
    }

    // Encrypt in place, releasing each plaintext chunk as we go so peak
    // memory stays near 2× the file size, not 3×.
    final encrypted = List<FileChunk>.filled(chunks.length, chunks.first);
    for (var i = 0; i < chunks.length; i++) {
      encrypted[i] = await AeadCipher.encryptChunk(chunks[i], key);
      chunks[i] = _emptyChunk;
    }

    final transfer = _OutgoingTransfer(
      transferId: tid,
      label: label,
      chunks: encrypted,
      target: target,
      type: type,
    );
    _outgoing[tid] = transfer;
    _emitProgress(transfer);

    _startRetransmitTimer(transfer);
    unawaited(_pump(transfer));
  }

  /// Fill the sliding window: send chunks until [kTransferWindowSize] are in
  /// flight or every chunk has been sent once. Paced so the OS BLE buffer
  /// doesn't overrun.
  Future<void> _pump(_OutgoingTransfer transfer) async {
    if (transfer.pumping || transfer.isPaused) return;
    transfer.pumping = true;
    try {
      while (transfer.inFlight.length < kTransferWindowSize &&
          transfer.nextIndex < transfer.chunks.length) {
        final i = transfer.nextIndex++;
        if (transfer.ackedIndices.contains(i)) continue;
        await _sendChunk(transfer, i);
      }
    } finally {
      transfer.pumping = false;
    }
  }

  Future<void> _sendChunk(_OutgoingTransfer transfer, int index) async {
    // Always track it as in-flight; on a send failure we mark it immediately
    // overdue so the next retransmit tick retries it rather than orphaning it.
    transfer.inFlight.add(index);
    try {
      await _ble.sendChunk(transfer.chunks[index]);
      transfer.lastSentMs[index] = DateTime.now().millisecondsSinceEpoch;
    } catch (e) {
      meshLog('send chunk $index failed: $e');
      transfer.lastSentMs[index] = 0;
    }
    await Future<void>.delayed(
      const Duration(milliseconds: kChunkSendSpacingMs),
    );
  }

  // ── ACK handling ──────────────────────────────────────────────────────────

  void _onAck(({String peerId, String fileId, int chunkIndex}) ack) {
    final transfer = _outgoing[ack.fileId];
    if (transfer == null) return;

    final isNewAck = transfer.ackedIndices.add(ack.chunkIndex);
    transfer.inFlight.remove(ack.chunkIndex);
    if (isNewAck) {
      transfer.lastProgressMs = DateTime.now().millisecondsSinceEpoch;
    }
    _emitProgress(transfer);

    if (transfer.isComplete) {
      transfer.retransmitTimer?.cancel();
      _outgoing.remove(transfer.transferId);
      _keys.clearTransferKey(transfer.target.shortId, transfer.transferId);
      _emitProgressEvent(
        transfer.copyWith(progress: 1.0, status: TransferStatus.complete),
      );
      if (transfer.type == PayloadType.message) {
        _messageStore.markDelivered(transfer.transferId, ack.peerId);
      }
      return;
    }

    // An ACK freed a window slot — send more.
    if (isNewAck) unawaited(_pump(transfer));
  }

  // ── Retransmission / pause-resume ─────────────────────────────────────────

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

    final now = DateTime.now().millisecondsSinceEpoch;
    final online = _ble.isPeerOnline(transfer.target.shortId);

    if (!online) {
      // Peer is gone — park the transfer instead of failing it.
      transfer.pausedSinceMs ??= now;
      if (now - transfer.pausedSinceMs! > kTransferPeerReconnectMs) {
        _failTransfer(transfer, 'peer did not reconnect');
      }
      return;
    }

    if (transfer.isPaused) {
      // Peer just came back — resume where we left off.
      meshLog('transfer ${transfer.transferId} resuming after reconnect');
      transfer.pausedSinceMs = null;
      transfer.lastProgressMs = now;
    }

    // Abandon only after a sustained stall *while connected*.
    if (now - transfer.lastProgressMs > kTransferStallTimeoutMs) {
      _failTransfer(transfer, 'stalled with no progress');
      return;
    }

    // Resend in-flight chunks that have gone unacked too long, then top the
    // window back up.
    final overdue = transfer.overdue(now);
    for (final chunk in overdue) {
      try {
        await _ble.sendChunk(chunk);
        transfer.lastSentMs[chunk.chunkIndex] =
            DateTime.now().millisecondsSinceEpoch;
      } catch (_) {
        transfer.inFlight.remove(chunk.chunkIndex);
      }
      await Future<void>.delayed(
        const Duration(milliseconds: kChunkSendSpacingMs),
      );
    }
    unawaited(_pump(transfer));
  }

  void _failTransfer(_OutgoingTransfer transfer, String why) {
    meshLog('transfer ${transfer.transferId} FAILED: $why');
    transfer.retransmitTimer?.cancel();
    _outgoing.remove(transfer.transferId);
    _keys.clearTransferKey(transfer.target.shortId, transfer.transferId);
    _emitProgressEvent(
      transfer.copyWith(
        progress: transfer.progress,
        status: TransferStatus.failed,
      ),
    );
    if (transfer.type == PayloadType.message) {
      _messageStore.markFailed(transfer.transferId, transfer.target.shortId);
    }
  }

  // ── Receive ───────────────────────────────────────────────────────────────

  void _onIncomingEncryptedChunk(FileChunk encrypted) {
    // Chain onto the queue so events are handled strictly in order.
    _receiveQueue = _receiveQueue
        .then((_) => _handleIncomingChunk(encrypted))
        .catchError((Object e) => meshLog('receive chunk error: $e'));
  }

  Future<void> _handleIncomingChunk(FileChunk encrypted) async {
    final senderPeerId = encrypted.originPeerId;

    // Blocked sender: drop before decrypt and before ACK, so no message/file
    // is delivered and the sender gets no delivery confirmation. This is the
    // ONLY place a block takes effect — the chunk was already relayed onward
    // to other neighbours by BleMeshService, so the mesh is unaffected.
    if (_contacts?.isBlocked(senderPeerId) ?? false) {
      meshLog('dropping chunk from blocked peer $senderPeerId');
      return;
    }

    // Same transfer-scoped key the sender used — derived from static keys, so
    // it's valid even if the Noise session was renegotiated mid-transfer.
    final key = await _keys.deriveTransferKey(senderPeerId, encrypted.fileId);
    if (key == null) return; // never handshaked with this sender / not for us

    final FileChunk decrypted;
    try {
      decrypted = await AeadCipher.decryptChunk(encrypted, key);
    } catch (_) {
      return; // wrong key or tampered — AEAD MAC rejected it
    }

    // Defence in depth: the plaintext must match the checksum the sender put
    // in the chunk header.
    if (!await _checksumMatches(decrypted)) return;

    // ACK back to the original sender (routed by identity — works multi-hop).
    await _ble.sendAck(
      fileId: decrypted.fileId,
      chunkIndex: decrypted.chunkIndex,
      originPeerId: senderPeerId,
    );

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
    if (!isNew) return; // duplicate — ACK already re-sent above

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

  Future<bool> _checksumMatches(FileChunk chunk) async {
    final hash = await _sha256.hash(chunk.data);
    final expected = chunk.checksum;
    if (hash.bytes.length != expected.length) return false;
    for (var i = 0; i < expected.length; i++) {
      if (hash.bytes[i] != expected[i]) return false;
    }
    return true;
  }

  Future<void> _finalise(_IncomingTransfer incoming) async {
    final assembler = incoming.assembler;
    final Uint8List bytes;
    try {
      bytes = await assembler.assemble();
    } catch (_) {
      _incoming.remove(assembler.fileId);
      assembler.discard();
      return;
    }

    _incoming.remove(assembler.fileId);
    assembler.discard();
    _keys.clearTransferKey(incoming.senderPeerId, assembler.fileId);

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
    _keys.clearTransferKey(transfer.target.shortId, transfer.transferId);
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
