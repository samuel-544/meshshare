import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../bluetooth/mesh_node.dart';
import '../messaging/message_model.dart';
import '../messaging/message_sender.dart';
import '../messaging/message_store.dart';
import 'send_file_screen.dart';

class ChatScreen extends StatefulWidget {
  final String peerId;
  final String? displayName;

  /// The live [MeshNode] for this peer — required to send messages.
  /// Null if the peer has disconnected (chat is read-only in that case).
  final MeshNode? target;

  const ChatScreen({
    super.key,
    required this.peerId,
    this.displayName,
    this.target,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();
  bool _sending = false;

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _sendMessage() async {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;

    final target = widget.target;
    if (target == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Peer is not connected.')),
      );
      return;
    }

    setState(() => _sending = true);
    _inputController.clear();

    try {
      await context.read<MessageSender>().send(content: text, target: target);
      _scrollToBottom();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Send failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final displayName =
        widget.displayName ?? 'Peer ${widget.peerId.substring(0, 8)}';

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(displayName),
            Text(
              widget.peerId.substring(0, 16),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withAlpha(153),
                  ),
            ),
          ],
        ),
        actions: [
          if (widget.target != null)
            IconButton(
              icon: const Icon(Icons.upload_file),
              tooltip: 'Send File',
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => SendFileScreen(target: widget.target!),
                ),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _buildMessageList()),
          _buildInputBar(),
        ],
      ),
    );
  }

  Widget _buildMessageList() {
    return Consumer<MessageStore>(
      builder: (_, store, _) {
        final messages = store.messagesFor(widget.peerId);
        if (messages.isEmpty) {
          return Center(
            child: Text(
              'No messages yet.\nSay hello!',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withAlpha(128),
                  ),
            ),
          );
        }
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
        return ListView.builder(
          controller: _scrollController,
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
          itemCount: messages.length,
          itemBuilder: (_, i) => _MessageBubble(message: messages[i]),
        );
      },
    );
  }

  Widget _buildInputBar() {
    final colorScheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          color: colorScheme.surface,
          border: Border(
            top: BorderSide(color: colorScheme.outlineVariant, width: 0.5),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _inputController,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _sendMessage(),
                minLines: 1,
                maxLines: 4,
                decoration: InputDecoration(
                  hintText: 'Message…',
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                  filled: true,
                  fillColor: colorScheme.surfaceContainerHighest,
                ),
              ),
            ),
            const SizedBox(width: 8),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: _sending
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : IconButton.filled(
                      key: const ValueKey('send'),
                      onPressed: _sendMessage,
                      icon: const Icon(Icons.send),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Message bubble ─────────────────────────────────────────────────────────

class _MessageBubble extends StatelessWidget {
  final TextMessage message;

  const _MessageBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final isOutgoing = message.isOutgoing;
    final colorScheme = Theme.of(context).colorScheme;
    final bgColor =
        isOutgoing ? colorScheme.primaryContainer : colorScheme.surfaceContainerHighest;
    final textColor = isOutgoing
        ? colorScheme.onPrimaryContainer
        : colorScheme.onSurfaceVariant;

    return Align(
      alignment:
          isOutgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.72,
        ),
        padding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: Radius.circular(isOutgoing ? 18 : 4),
            bottomRight: Radius.circular(isOutgoing ? 4 : 18),
          ),
        ),
        child: Column(
          crossAxisAlignment: isOutgoing
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            Text(message.content, style: TextStyle(color: textColor)),
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _formatTime(message.timestampMs),
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: textColor.withAlpha(153),
                      ),
                ),
                if (isOutgoing) ...[
                  const SizedBox(width: 4),
                  _DeliveryIcon(
                      status: message.status, tint: textColor),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}';
  }
}

class _DeliveryIcon extends StatelessWidget {
  final MessageStatus status;
  final Color tint;

  const _DeliveryIcon({required this.status, required this.tint});

  @override
  Widget build(BuildContext context) {
    switch (status) {
      case MessageStatus.sending:
        return Icon(Icons.access_time, size: 12, color: tint.withAlpha(179));
      case MessageStatus.delivered:
        return Icon(Icons.done, size: 12, color: tint.withAlpha(179));
      case MessageStatus.failed:
        return Icon(Icons.error_outline,
            size: 12, color: Theme.of(context).colorScheme.error);
    }
  }
}
