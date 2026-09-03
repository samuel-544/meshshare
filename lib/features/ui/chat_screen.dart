import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../bluetooth/ble_mesh_service.dart';
import '../../core/log.dart';
import '../bluetooth/mesh_node.dart';
import '../messaging/message_model.dart';
import '../messaging/message_sender.dart';
import '../messaging/message_store.dart';
import '../peers/peer_contact_store.dart';
import 'demo_transfer_trace.dart';
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
  final List<String> _demoTrace = [];
  bool _sending = false;

  /// Non-null while this chat's peer is known to be offline — shown as a
  /// banner above the input bar so the user knows why sends won't go through.
  String? _offlineNote;
  StreamSubscription<PeerLostEvent>? _peerLostSub;
  StreamSubscription<MeshNode>? _peerBackSub;

  bool _isThisPeer(String shortId) =>
      shortId == widget.peerId || widget.peerId.startsWith(shortId);

  @override
  void initState() {
    super.initState();
    if (!Platform.isAndroid && !Platform.isIOS) return;
    final ble = context.read<BleMeshService>();
    _peerLostSub = ble.peerLost.listen((event) {
      if (!mounted || !_isThisPeer(event.shortId)) return;
      final name = context.read<PeerContactStore>().nameFor(
        widget.peerId,
        fallback: widget.displayName,
      );
      setState(() => _offlineNote = event.message(name));
    });
    _peerBackSub = ble.discoveredPeers.listen((node) {
      if (!mounted || !_isThisPeer(node.shortId)) return;
      setState(() => _offlineNote = null);
    });
  }

  @override
  void dispose() {
    _peerLostSub?.cancel();
    _peerBackSub?.cancel();
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _sendMessage() async {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;

    final target = widget.target;
    if (target == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Peer is not connected.')));
      return;
    }

    setState(() => _sending = true);
    _inputController.clear();
    final sender = context.read<MessageSender>();
    final store = context.read<MessageStore>();

    try {
      if (!Platform.isAndroid && !Platform.isIOS) {
        await _runDemoTrace(text);
      }
      await sender.send(content: text, target: target);
      if (!Platform.isAndroid && !Platform.isIOS) {
        _addDemoReply(store, text);
      }
      _scrollToBottom();
    } catch (e, st) {
      meshLog('chat _sendMessage failed: $e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Send failed: $e')));
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

  Future<void> _runDemoTrace(String text) async {
    final peerName = widget.displayName ?? 'peer';
    final trace = [
      'Plaintext typed: "$text".',
      'Message converted to UTF-8 bytes and split into chunk 1/1.',
      'Chunk encrypted with ChaCha20-Poly1305: 0x4d7a...91bf.',
      'Encrypted chunk hops Local Device -> Relay Node #1 -> $peerName.',
      '$peerName verifies MAC, decrypts, and reassembles the message.',
    ];
    setState(() => _demoTrace.clear());
    for (final event in trace) {
      await Future.delayed(const Duration(milliseconds: 420));
      if (!mounted) return;
      setState(() => _demoTrace.add(event));
    }
  }

  void _addDemoReply(MessageStore store, String original) {
    final reply = TextMessage(
      messageId: 'demo-reply-${DateTime.now().millisecondsSinceEpoch}',
      senderPeerId: widget.peerId,
      recipientPeerId: 'local-demo-peer',
      content: original.toLowerCase() == 'hello'
          ? 'Hello. I received and decrypted your MeshShare message.'
          : 'Received securely. The encrypted chunks were reassembled here.',
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      isOutgoing: false,
      status: MessageStatus.delivered,
    );
    store.upsert(reply);
    setState(() {
      _demoTrace.add('ACK received. Reply generated by receiver for demo.');
    });
  }

  Future<void> _renamePeer(String currentName) async {
    final controller = TextEditingController(text: currentName);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit Contact Name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();

    if (name == null || name.isEmpty || !mounted) return;
    await context.read<PeerContactStore>().rename(widget.peerId, name);
  }

  Future<void> _setBlocked(bool blocked) async {
    final store = context.read<PeerContactStore>();
    final name = store.nameFor(widget.peerId, fallback: widget.displayName);
    await store.setBlocked(widget.peerId, blocked, displayName: name);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          blocked
              ? '$name blocked. Their messages and files to you are dropped; '
                    'they can still relay mesh traffic.'
              : '$name unblocked.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final contacts = context.watch<PeerContactStore>();
    final displayName = contacts.nameFor(
      widget.peerId,
      fallback: widget.displayName,
    );
    final blocked = contacts.isBlocked(widget.peerId);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(displayName),
            Text(
              widget.peerId.substring(0, 16),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurface.withAlpha(153),
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: 'Edit name',
            onPressed: () => _renamePeer(displayName),
          ),
          if (widget.target != null && !blocked)
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
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'block') _setBlocked(true);
              if (value == 'unblock') _setBlocked(false);
            },
            itemBuilder: (_) => [
              blocked
                  ? const PopupMenuItem(
                      value: 'unblock',
                      child: Text('Unblock contact'),
                    )
                  : const PopupMenuItem(
                      value: 'block',
                      child: Text(
                        'Block contact',
                        style: TextStyle(color: Colors.redAccent),
                      ),
                    ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _buildMessageList()),
          if (_offlineNote != null && !blocked)
            _buildOfflineBanner(_offlineNote!),
          if (_demoTrace.isNotEmpty && !blocked)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
              child: DemoTransferTrace(events: _demoTrace),
            ),
          blocked ? _buildBlockedBar() : _buildInputBar(),
        ],
      ),
    );
  }

  Widget _buildBlockedBar() {
    final colorScheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(
          color: colorScheme.surface,
          border: Border(
            top: BorderSide(color: colorScheme.outlineVariant, width: 0.5),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.block, size: 18, color: colorScheme.error),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'You blocked this contact. Their messages and files to '
                    'you are dropped. Unblock to message them again.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.person_add_alt_1_outlined, size: 18),
                label: const Text('Unblock'),
                onPressed: () => _setBlocked(false),
              ),
            ),
          ],
        ),
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
                color: Theme.of(context).colorScheme.onSurface.withAlpha(128),
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

  Widget _buildOfflineBanner(String note) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: colorScheme.errorContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(
            Icons.bluetooth_disabled,
            size: 18,
            color: colorScheme.onErrorContainer,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              note,
              style: TextStyle(
                fontSize: 13,
                color: colorScheme.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
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
    final bgColor = isOutgoing
        ? colorScheme.primaryContainer
        : colorScheme.surfaceContainerHighest;
    final textColor = isOutgoing
        ? colorScheme.onPrimaryContainer
        : colorScheme.onSurfaceVariant;

    return Align(
      alignment: isOutgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.72,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
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
                  _DeliveryIcon(status: message.status, tint: textColor),
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
        return Icon(
          Icons.error_outline,
          size: 12,
          color: Theme.of(context).colorScheme.error,
        );
    }
  }
}
