import '../file_transfer/chunk_model.dart';

/// The lifecycle state of a transfer.
enum TransferStatus {
  /// Chunks are being sent; waiting for ACKs.
  sending,

  /// Chunks are arriving; assembling.
  receiving,

  /// All chunks sent and ACKed (outgoing) or assembled (incoming).
  complete,

  /// Transfer timed out or authentication failed.
  failed,
}

/// Live progress snapshot of a single file or message transfer.
class TransferProgress {
  /// Unique transfer ID — matches [FileChunk.fileId].
  final String transferId;

  /// Human-readable label: file name for files, first 40 chars for messages.
  final String label;

  /// 0.0 (just started) → 1.0 (complete).
  final double progress;

  final TransferStatus status;
  final PayloadType type;

  /// Peer identity string of the other party.
  final String peerId;

  const TransferProgress({
    required this.transferId,
    required this.label,
    required this.progress,
    required this.status,
    required this.type,
    required this.peerId,
  });

  TransferProgress copyWith({double? progress, TransferStatus? status}) {
    return TransferProgress(
      transferId: transferId,
      label: label,
      progress: progress ?? this.progress,
      status: status ?? this.status,
      type: type,
      peerId: peerId,
    );
  }
}

/// Emitted when an incoming file has been fully assembled and saved to disk.
class SavedFile {
  /// Absolute path to the saved file on this device.
  final String path;

  /// Original filename as embedded in the transfer (from [label]).
  final String name;

  /// File size in bytes.
  final int sizeBytes;

  /// Peer identity of the sender.
  final String senderPeerId;

  final DateTime receivedAt;

  const SavedFile({
    required this.path,
    required this.name,
    required this.sizeBytes,
    required this.senderPeerId,
    required this.receivedAt,
  });
}
