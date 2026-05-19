import 'dart:convert';
import 'dart:typed_data';

/// Delivery state of an outgoing message.
enum MessageStatus {
  /// Chunks sent but no ACK yet.
  sending,

  /// All chunks ACKed by the recipient.
  delivered,

  /// Retransmit timed out — delivery failed.
  failed,
}

/// A single text message exchanged between two MeshShare peers.
class TextMessage {
  /// Unique message ID (UUID v4) — also used as the [FileChunk.fileId]
  /// so that the chunk pipeline treats this message like any other transfer.
  final String messageId;

  /// Stable peer identity of the sender (hex of Noise public key hash).
  final String senderPeerId;

  /// Stable peer identity of the intended recipient.
  final String recipientPeerId;

  /// The plaintext message content (max [kMaxMessageLength] chars).
  final String content;

  /// Unix timestamp in milliseconds when the message was created.
  final int timestampMs;

  /// Whether this message was sent by the local device.
  final bool isOutgoing;

  /// Delivery status — only meaningful for outgoing messages.
  final MessageStatus status;

  const TextMessage({
    required this.messageId,
    required this.senderPeerId,
    required this.recipientPeerId,
    required this.content,
    required this.timestampMs,
    required this.isOutgoing,
    this.status = MessageStatus.sending,
  });

  /// Maximum text length enforced before chunking (characters).
  static const int kMaxMessageLength = 2000;

  /// Returns the message content as UTF-8 bytes for chunking.
  Uint8List toBytes() => Uint8List.fromList(utf8.encode(content));

  /// Reconstruct [TextMessage] from reassembled UTF-8 bytes.
  factory TextMessage.fromBytes({
    required Uint8List bytes,
    required String messageId,
    required String senderPeerId,
    required String recipientPeerId,
    required int timestampMs,
  }) {
    return TextMessage(
      messageId: messageId,
      senderPeerId: senderPeerId,
      recipientPeerId: recipientPeerId,
      content: utf8.decode(bytes),
      timestampMs: timestampMs,
      isOutgoing: false,
      status: MessageStatus.delivered,
    );
  }

  TextMessage copyWith({MessageStatus? status}) {
    return TextMessage(
      messageId: messageId,
      senderPeerId: senderPeerId,
      recipientPeerId: recipientPeerId,
      content: content,
      timestampMs: timestampMs,
      isOutgoing: isOutgoing,
      status: status ?? this.status,
    );
  }
}
