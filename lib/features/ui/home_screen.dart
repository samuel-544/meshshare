import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/demo_peers.dart';
import '../bluetooth/ble_mesh_service.dart';
import '../bluetooth/mesh_node.dart';
import '../crypto/key_manager.dart';
import '../file_transfer/transfer_manager.dart';
import '../file_transfer/transfer_progress.dart';
import 'chat_screen.dart';
import 'device_discovery_screen.dart';
import 'receive_file_screen.dart';
import 'send_file_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final List<MeshNode> _peers = [];
  StreamSubscription<MeshNode>? _peerSub;
  StreamSubscription<SavedFile>? _savedFileSub;
  bool _scanning = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _startBle());
  }

  Future<void> _startBle() async {
    // Capture all service references synchronously before any awaits.
    final ble = context.read<BleMeshService>();
    final keys = context.read<KeyManager>();
    final tm = context.read<TransferManager>();

    _peerSub = ble.discoveredPeers.listen((node) {
      if (!mounted) return;
      setState(() {
        final idx = _peers.indexWhere((p) => p.shortId == node.shortId);
        if (idx >= 0) {
          _peers[idx] = node;
        } else {
          _peers.add(node);
        }
      });
    });

    _savedFileSub = tm.savedFiles.listen((file) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Received: ${file.name}'),
          action: SnackBarAction(
            label: 'View',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ReceiveFileScreen()),
            ),
          ),
        ),
      );
    });

    // BLE platform APIs are only available on Android/iOS.
    if (!Platform.isAndroid && !Platform.isIOS) {
      setState(() => _peers.addAll(buildDemoPeers()));
      return;
    }

    setState(() => _scanning = true);
    try {
      final identityBytes = await keys.localIdentityBytes();
      await ble.start(localIdentity: identityBytes);
    } catch (_) {
      // BLE unavailable (e.g. emulator, Bluetooth off) — silent degradation.
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  @override
  void dispose() {
    _peerSub?.cancel();
    _savedFileSub?.cancel();
    super.dispose();
  }

  void _openSendFile() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DeviceDiscoveryScreen(
          onPeerSelected: (node) {
            Navigator.pop(context);
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => SendFileScreen(target: node)),
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('MeshShare'),
        actions: [
          if (_scanning)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.download_outlined),
            tooltip: 'Received Files',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ReceiveFileScreen()),
            ),
          ),
        ],
      ),
      body: _peers.isEmpty ? _buildEmptyState() : _buildPeerList(),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openSendFile,
        icon: const Icon(Icons.upload_file),
        label: const Text('Send File'),
      ),
    );
  }

  Widget _buildEmptyState() {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.bluetooth_searching,
            size: 72,
            color: colorScheme.primary.withAlpha(102),
          ),
          const SizedBox(height: 16),
          Text(
            'No peers found',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            'Make sure Bluetooth is on and\nother devices are nearby.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurface.withAlpha(153),
                ),
          ),
        ],
      ),
    );
  }

  Widget _buildPeerList() {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _peers.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final node = _peers[i];
        return _PeerTile(
          node: node,
          onChat: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => ChatScreen(
                peerId: node.shortId,
                displayName: node.displayName,
                target: node,
              ),
            ),
          ),
          onSendFile: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => SendFileScreen(target: node)),
          ),
        );
      },
    );
  }
}

// ── Peer list tile ─────────────────────────────────────────────────────────

class _PeerTile extends StatelessWidget {
  final MeshNode node;
  final VoidCallback onChat;
  final VoidCallback onSendFile;

  const _PeerTile({
    required this.node,
    required this.onChat,
    required this.onSendFile,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final initials = node.shortId.substring(0, 2).toUpperCase();

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: colorScheme.primaryContainer,
        child: Text(
          initials,
          style: TextStyle(
            color: colorScheme.onPrimaryContainer,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      title: Text(node.displayName ?? 'Peer ${node.shortId.substring(0, 8)}'),
      subtitle: Text(node.shortId),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _RssiBars(rssi: node.rssi),
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(Icons.chat_bubble_outline),
            tooltip: 'Chat',
            onPressed: onChat,
          ),
          IconButton(
            icon: const Icon(Icons.upload_file),
            tooltip: 'Send File',
            onPressed: onSendFile,
          ),
        ],
      ),
    );
  }
}

// ── RSSI signal-strength bars ──────────────────────────────────────────────

class _RssiBars extends StatelessWidget {
  final int rssi;

  const _RssiBars({required this.rssi});

  int get _activeBars {
    if (rssi >= -60) return 4;
    if (rssi >= -70) return 3;
    if (rssi >= -80) return 2;
    return 1;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: List.generate(4, (i) {
        final height = 6.0 + i * 4.0;
        return Container(
          width: 4,
          height: height,
          margin: const EdgeInsets.symmetric(horizontal: 1),
          decoration: BoxDecoration(
            color: i < _activeBars
                ? colorScheme.primary
                : colorScheme.outline.withAlpha(77),
            borderRadius: BorderRadius.circular(1),
          ),
        );
      }),
    );
  }
}
