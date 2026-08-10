import 'dart:io';

import '../../core/utils.dart';
import '../bluetooth/mesh_node.dart';
import '../file_transfer/transfer_manager.dart';
import 'message_model.dart';
import 'message_store.dart';

/// Convenience wrapper that builds a [TextMessage] and hands it to
/// [TransferManager.sendMessage].
///
/// Callers only need to supply the content string and target peer — this class
/// handles identity, timestamp, and message ID.
class MessageSender {
  final TransferManager _transferManager;
  final MessageStore _store;
  final String _localPeerId;

  MessageSender({
    required TransferManager transferManager,
    required MessageStore store,
    required String localPeerId,
  }) : _transferManager = transferManager,
       _store = store,
       _localPeerId = localPeerId;

  /// Send [content] to [target].
  ///
  /// Throws [ArgumentError] if [content] is empty or exceeds
  /// [TextMessage.kMaxMessageLength].
  Future<TextMessage> send({
    required String content,
    required MeshNode target,
  }) async {
    if (content.isEmpty) {
      throw ArgumentError('Message content must not be empty.');
    }
    if (content.length > TextMessage.kMaxMessageLength) {
      throw ArgumentError(
        'Message exceeds maximum length of ${TextMessage.kMaxMessageLength} characters.',
      );
    }

    final message = TextMessage(
      messageId: generateUuid(),
      senderPeerId: _localPeerId,
      recipientPeerId: target.shortId,
      content: content,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      isOutgoing: true,
      status: MessageStatus.sending,
    );

    // Optimistically add to the store so the UI shows it immediately.
    _store.upsert(message);

    if (!Platform.isAndroid && !Platform.isIOS) {
      // Demo mode: simulate delivery after a short delay without real BLE.
      Future.delayed(const Duration(milliseconds: 800), () {
        _store.markDelivered(message.messageId, target.shortId);
      });
      return message;
    }

    await _transferManager.sendMessage(message: message, target: target);
    return message;
  }
}
