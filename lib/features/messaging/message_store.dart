import 'package:flutter/foundation.dart';

import 'message_model.dart';

/// In-memory store of all messages, organised by conversation (peerId).
///
/// Extends [ChangeNotifier] so the UI can rebuild when messages arrive.
/// Persistence to disk (path_provider + JSON) will be added in Phase 7.
class MessageStore extends ChangeNotifier {
  /// Map of peerId → ordered list of messages (oldest first).
  final Map<String, List<TextMessage>> _conversations = {};

  /// All peer IDs that have at least one message.
  List<String> get conversationPeerIds => _conversations.keys.toList();

  /// Returns messages for a given [peerId], oldest first.
  List<TextMessage> messagesFor(String peerId) =>
      List.unmodifiable(_conversations[peerId] ?? []);

  /// Number of unread incoming messages across all conversations.
  int get totalUnread => _conversations.values
      .expand((msgs) => msgs)
      .where((m) => !m.isOutgoing && m.status != MessageStatus.delivered)
      .length;

  /// Add or update a message in its conversation thread.
  ///
  /// If a message with [message.messageId] already exists it is replaced
  /// (used to update status from [MessageStatus.sending] → delivered/failed).
  void upsert(TextMessage message) {
    final peerId =
        message.isOutgoing ? message.recipientPeerId : message.senderPeerId;

    _conversations.putIfAbsent(peerId, () => []);
    final thread = _conversations[peerId]!;

    final idx = thread.indexWhere((m) => m.messageId == message.messageId);
    if (idx >= 0) {
      thread[idx] = message;
    } else {
      thread.add(message);
      // Keep thread sorted by timestamp.
      thread.sort((a, b) => a.timestampMs.compareTo(b.timestampMs));
    }

    notifyListeners();
  }

  /// Mark an outgoing message as delivered.
  void markDelivered(String messageId, String peerId) {
    final thread = _conversations[peerId];
    if (thread == null) return;
    final idx = thread.indexWhere((m) => m.messageId == messageId);
    if (idx < 0) return;
    thread[idx] = thread[idx].copyWith(status: MessageStatus.delivered);
    notifyListeners();
  }

  /// Mark an outgoing message as failed.
  void markFailed(String messageId, String peerId) {
    final thread = _conversations[peerId];
    if (thread == null) return;
    final idx = thread.indexWhere((m) => m.messageId == messageId);
    if (idx < 0) return;
    thread[idx] = thread[idx].copyWith(status: MessageStatus.failed);
    notifyListeners();
  }
}
