import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../../core/demo_peers.dart';
import '../bluetooth/ble_mesh_service.dart';
import '../bluetooth/mesh_node.dart';
import '../crypto/key_manager.dart';
import '../peers/peer_contact_store.dart';

class DeviceDiscoveryScreen extends StatefulWidget {
  /// Called when the user taps a peer. If null, the screen pops with the node.
  final void Function(MeshNode)? onPeerSelected;

  const DeviceDiscoveryScreen({super.key, this.onPeerSelected});

  @override
  State<DeviceDiscoveryScreen> createState() => _DeviceDiscoveryScreenState();
}

class _DeviceDiscoveryScreenState extends State<DeviceDiscoveryScreen> {
  final List<MeshNode> _discovered = [];
  final List<MeshNode> _indirect = [];
  final Set<String> _connectingShortIds = {};
  final List<String> _logs = [];
  StreamSubscription<MeshNode>? _sub;
  StreamSubscription<MeshNode>? _indirectSub;
  StreamSubscription<PeerLostEvent>? _peerLostSub;
  StreamSubscription<String>? _logSub;
  bool _scanning = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _prepareDiscovery());
  }

  Future<void> _prepareDiscovery() async {
    final ble = context.read<BleMeshService>();

    // Seed with peers already connected.
    for (final p in ble.connectedPeers) {
      if (!_discovered.any((d) => d.shortId == p.shortId)) {
        setState(() => _discovered.add(p));
      }
    }

    _sub = ble.discoveredPeers.listen((node) {
      if (!mounted) return;
      final wasIndirect = _connectingShortIds.contains(node.shortId);
      setState(() {
        final idx = _discovered.indexWhere((p) => p.shortId == node.shortId);
        if (idx >= 0) {
          _discovered[idx] = node;
        } else {
          _discovered.add(node);
        }
        _indirect.removeWhere((p) => p.shortId == node.shortId);
        _connectingShortIds.remove(node.shortId);
      });
      final name = context.read<PeerContactStore>().nameFor(
        node.shortId,
        fallback: node.displayName,
      );
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$name is ready to share.')));
      // If the user tapped this peer while it was still gossip-only, carry
      // them straight into whatever flow they were starting.
      if (wasIndirect) _selectPeer(node);
    });

    _indirectSub = ble.indirectPeers.listen((node) {
      if (!mounted) return;
      if (_discovered.any((p) => p.shortId == node.shortId)) return;
      setState(() {
        final idx = _indirect.indexWhere((p) => p.shortId == node.shortId);
        if (idx >= 0) {
          _indirect[idx] = node;
        } else {
          _indirect.add(node);
        }
      });
    });

    _peerLostSub = ble.peerLost.listen((event) {
      if (!mounted) return;
      setState(() {
        _discovered.removeWhere((p) => p.shortId == event.shortId);
        _connectingShortIds.remove(event.shortId);
      });
      final name = context.read<PeerContactStore>().nameFor(event.shortId);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(event.message(name))));
    });

    _logSub = ble.discoveryLogs.listen((message) {
      if (!mounted) return;
      setState(() {
        _logs
          ..add(message)
          ..removeRange(0, _logs.length > 6 ? _logs.length - 6 : 0);
      });
    });
  }

  Future<void> _startScan() async {
    final ble = context.read<BleMeshService>();
    final keys = context.read<KeyManager>();

    if (!Platform.isAndroid && !Platform.isIOS) {
      setState(() {
        _scanning = true;
        _logs
          ..clear()
          ..add('Scanning for demo peers...')
          ..add('Starting demo secure handshakes...');
      });
      await Future.delayed(const Duration(milliseconds: 600));
      if (!mounted) return;
      setState(() {
        for (final p in buildDemoPeers()) {
          if (!_discovered.any((d) => d.shortId == p.shortId)) {
            _discovered.add(p);
          }
        }
        _logs.add('Demo peers are ready to share.');
        _scanning = false;
      });
      return;
    }

    setState(() => _scanning = true);
    try {
      final allowed = await _requestBlePermissions();
      if (!allowed) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Bluetooth permissions are required for discovery.'),
          ),
        );
        return;
      }
      final identityBytes = await keys.localIdentityBytes();
      await ble.start(localIdentity: identityBytes); // no-op if already running
      await ble.discoverPeers();
      await Future.delayed(const Duration(seconds: 4));
    } catch (_) {
      // BLE unavailable — show whatever was already discovered.
      if (mounted) {
        setState(() => _logs.add('Bluetooth discovery could not start.'));
      }
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<bool> _requestBlePermissions() async {
    final permissions = <Permission>[
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.bluetoothAdvertise,
      Permission.notification,
      if (Platform.isAndroid) Permission.locationWhenInUse,
    ];

    final statuses = await permissions.request();
    return statuses.entries
        .where(
          (entry) =>
              entry.key != Permission.notification &&
              entry.key != Permission.locationWhenInUse,
        )
        .every((entry) => entry.value.isGranted || entry.value.isLimited);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _indirectSub?.cancel();
    _peerLostSub?.cancel();
    _logSub?.cancel();
    super.dispose();
  }

  void _selectPeer(MeshNode node) {
    if (widget.onPeerSelected != null) {
      widget.onPeerSelected!(node);
    } else {
      Navigator.pop(context, node);
    }
  }

  /// A peer known only via mesh gossip has no session yet — request one
  /// (flooded through the mesh, may involve a relay) before it can be used.
  /// Once ready it arrives through [BleMeshService.discoveredPeers], which
  /// automatically continues into [_selectPeer].
  Future<void> _connectToIndirectPeer(MeshNode node) async {
    final ble = context.read<BleMeshService>();
    setState(() => _connectingShortIds.add(node.shortId));

    final ready = await ble.requestSecureSession(node.shortId);

    if (!mounted) return;
    if (!ready) {
      setState(() => _connectingShortIds.remove(node.shortId));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not reach that peer over the mesh.'),
        ),
      );
    }
    // On success, _connectingShortIds is cleared by the discoveredPeers
    // listener above, which also triggers _selectPeer.
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Discover Peers'),
        actions: [
          IconButton(
            icon: _scanning
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.bluetooth_searching),
            tooltip: 'Scan',
            onPressed: _scanning ? null : _startScan,
          ),
        ],
      ),
      body: Column(
        children: [
          _buildDiscoveryHeader(),
          if (_logs.isNotEmpty) _buildLogPanel(),
          Expanded(
            child: _discovered.isEmpty && _indirect.isEmpty
                ? Center(
                    child: Text(
                      _scanning
                          ? 'Looking for nearby devices...'
                          : 'Tap scan to discover nearby MeshShare devices.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                  )
                : ListView(
                    children: [
                      for (final node in _discovered)
                        Consumer<PeerContactStore>(
                          builder: (_, contacts, _) {
                            final name = contacts.nameFor(
                              node.shortId,
                              fallback: node.displayName,
                            );
                            final blocked = contacts.isBlocked(node.shortId);
                            return ListTile(
                              leading: CircleAvatar(
                                child: Text(
                                  name.substring(0, 1).toUpperCase(),
                                ),
                              ),
                              title: Text(name),
                              subtitle: Text(
                                blocked
                                    ? '${node.shortId} · blocked · relaying only'
                                    : '${node.shortId} · RSSI: ${node.rssi} dBm',
                              ),
                              trailing: blocked
                                  ? Icon(
                                      Icons.block,
                                      size: 18,
                                      color: Theme.of(context).colorScheme.error,
                                    )
                                  : const Icon(Icons.chevron_right),
                              onTap: blocked ? null : () => _selectPeer(node),
                            );
                          },
                        ),
                      if (_indirect.isNotEmpty) ...[
                        const Padding(
                          padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                          child: Text(
                            'Nearby via mesh — tap to connect',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        for (final node in _indirect)
                          Consumer<PeerContactStore>(
                            builder: (_, contacts, _) {
                              final name = contacts.nameFor(node.shortId);
                              final connecting = _connectingShortIds.contains(
                                node.shortId,
                              );
                              return ListTile(
                                leading: CircleAvatar(
                                  child: Text(
                                    name.substring(0, 1).toUpperCase(),
                                  ),
                                ),
                                title: Text(name),
                                subtitle: Text(
                                  '${node.shortId} · reachable via a relay',
                                ),
                                trailing: connecting
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(Icons.bluetooth_connected),
                                onTap: connecting
                                    ? null
                                    : () => _connectToIndirectPeer(node),
                              );
                            },
                          ),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildDiscoveryHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: FilledButton.icon(
        onPressed: _scanning ? null : _startScan,
        icon: _scanning
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.bluetooth_searching),
        label: Text(_scanning ? 'Scanning...' : 'Scan for Peers'),
      ),
    );
  }

  Widget _buildLogPanel() {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Discovery Log', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 6),
          for (final log in _logs)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(log, style: Theme.of(context).textTheme.bodySmall),
            ),
        ],
      ),
    );
  }
}
