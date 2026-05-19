import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/demo_peers.dart';
import '../bluetooth/ble_mesh_service.dart';
import '../bluetooth/mesh_node.dart';
import '../crypto/key_manager.dart';

class DeviceDiscoveryScreen extends StatefulWidget {
  /// Called when the user taps a peer. If null, the screen pops with the node.
  final void Function(MeshNode)? onPeerSelected;

  const DeviceDiscoveryScreen({super.key, this.onPeerSelected});

  @override
  State<DeviceDiscoveryScreen> createState() => _DeviceDiscoveryScreenState();
}

class _DeviceDiscoveryScreenState extends State<DeviceDiscoveryScreen> {
  final List<MeshNode> _discovered = [];
  StreamSubscription<MeshNode>? _sub;
  bool _scanning = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _startScan());
  }

  Future<void> _startScan() async {
    final ble = context.read<BleMeshService>();

    // Seed with peers already connected.
    for (final p in ble.connectedPeers) {
      if (!_discovered.any((d) => d.shortId == p.shortId)) {
        setState(() => _discovered.add(p));
      }
    }

    _sub = ble.discoveredPeers.listen((node) {
      if (!mounted) return;
      setState(() {
        final idx = _discovered.indexWhere((p) => p.shortId == node.shortId);
        if (idx >= 0) {
          _discovered[idx] = node;
        } else {
          _discovered.add(node);
        }
      });
    });

    if (!Platform.isAndroid && !Platform.isIOS) {
      await Future.delayed(const Duration(milliseconds: 600));
      if (!mounted) return;
      setState(() {
        for (final p in buildDemoPeers()) {
          if (!_discovered.any((d) => d.shortId == p.shortId)) {
            _discovered.add(p);
          }
        }
        _scanning = false;
      });
      return;
    }

    setState(() => _scanning = true);
    try {
      final keys = context.read<KeyManager>();
      final identityBytes = await keys.localIdentityBytes();
      await ble.start(localIdentity: identityBytes); // no-op if already running
    } catch (_) {
      // BLE unavailable — show whatever was already discovered.
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _selectPeer(MeshNode node) {
    if (widget.onPeerSelected != null) {
      widget.onPeerSelected!(node);
    } else {
      Navigator.pop(context, node);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Discover Peers'),
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
        ],
      ),
      body: _discovered.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(
                    'Searching for nearby devices…',
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Keep Bluetooth on and stay close.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            )
          : ListView.builder(
              itemCount: _discovered.length,
              itemBuilder: (_, i) {
                final node = _discovered[i];
                return ListTile(
                  leading: CircleAvatar(
                    child: Text(node.shortId.substring(0, 2).toUpperCase()),
                  ),
                  title: Text(
                      node.displayName ?? 'Peer ${node.shortId.substring(0, 8)}'),
                  subtitle: Text('RSSI: ${node.rssi} dBm'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _selectPeer(node),
                );
              },
            ),
    );
  }
}
