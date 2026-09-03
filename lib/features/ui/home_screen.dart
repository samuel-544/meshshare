import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../../core/demo_peers.dart';
import '../../core/theme.dart';
import '../bluetooth/ble_mesh_service.dart';
import '../bluetooth/mesh_node.dart';
import '../crypto/key_manager.dart';
import '../file_transfer/transfer_manager.dart';
import '../file_transfer/transfer_progress.dart';
import '../peers/peer_contact_store.dart';
import 'chat_screen.dart';
import 'device_discovery_screen.dart';
import 'receive_file_screen.dart';
import 'send_file_screen.dart';
import 'widgets/mesh_logo.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final List<MeshNode> _peers = [];
  StreamSubscription<MeshNode>? _peerSub;
  StreamSubscription<PeerLostEvent>? _peerLostSub;
  StreamSubscription<SavedFile>? _savedFileSub;
  Timer? _demoFallbackTimer;
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

    _peerLostSub = ble.peerLost.listen((event) {
      if (!mounted) return;
      MeshNode? lost;
      setState(() {
        final idx = _peers.indexWhere((p) => p.shortId == event.shortId);
        if (idx >= 0) lost = _peers.removeAt(idx);
      });
      final contacts = context.read<PeerContactStore>();
      if (lost != null && !contacts.isBlocked(event.shortId)) {
        final name = contacts.nameFor(
          event.shortId,
          fallback: lost!.displayName,
        );
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(event.message(name))));
      }
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
      _loadDemoPeers();
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
      await ble.start(localIdentity: identityBytes);
    } catch (_) {
      // BLE unavailable (e.g. emulator, Bluetooth off) — silent degradation.
    } finally {
      if (mounted) setState(() => _scanning = false);
      // Debug builds on a device with no working Bluetooth radio (e.g. an
      // emulator used for a presentation) never discover a real peer. Fall
      // back to the same demo peers the desktop build uses so the dashboard,
      // chat and transfer screens have content to show.
      if (kDebugMode) {
        _demoFallbackTimer?.cancel();
        _demoFallbackTimer = Timer(const Duration(seconds: 4), () {
          if (mounted && _peers.isEmpty) _loadDemoPeers();
        });
      }
    }
  }

  void _loadDemoPeers() {
    if (!mounted || _peers.isNotEmpty) return;
    setState(() => _peers.addAll(buildDemoPeers()));
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
    _peerSub?.cancel();
    _peerLostSub?.cancel();
    _savedFileSub?.cancel();
    _demoFallbackTimer?.cancel();
    super.dispose();
  }

  // ── Navigation ────────────────────────────────────────────────────────────

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

  void _openDiscoverPeers() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const DeviceDiscoveryScreen()),
    );
  }

  void _openReceivedFiles() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const ReceiveFileScreen()),
    );
  }

  void _openChat(String peerId, String name, {MeshNode? target}) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            ChatScreen(peerId: peerId, displayName: name, target: target),
      ),
    );
  }

  Future<void> _renamePeer(String peerId, String currentName) async {
    final controller = TextEditingController(text: currentName);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit contact name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(hintText: 'Name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();

    if (name == null || name.isEmpty || !mounted) return;
    await context.read<PeerContactStore>().rename(peerId, name);
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Consumer<PeerContactStore>(
          builder: (_, contacts, _) {
            final connectedIds = _peers.map((p) => p.shortId).toSet();
            final offline = contacts.contacts
                .where((c) => !connectedIds.contains(c.peerId))
                .toList();

            return CustomScrollView(
              slivers: [
                SliverToBoxAdapter(child: _topBar()),
                SliverToBoxAdapter(child: _hero()),
                const SliverToBoxAdapter(child: SizedBox(height: 20)),
                SliverToBoxAdapter(child: _statusCard()),
                const SliverToBoxAdapter(child: SizedBox(height: 28)),
                if (_peers.isNotEmpty) ...[
                  SliverToBoxAdapter(
                    child: _SectionHeader('Online now', '${_peers.length}'),
                  ),
                  SliverToBoxAdapter(
                    child: _card(
                      children: [
                        for (var i = 0; i < _peers.length; i++) ...[
                          if (i > 0) const _RowDivider(),
                          _onlinePeerRow(_peers[i], contacts),
                        ],
                      ],
                    ),
                  ),
                  const SliverToBoxAdapter(child: SizedBox(height: 26)),
                ],
                if (offline.isNotEmpty) ...[
                  SliverToBoxAdapter(
                    child: _SectionHeader(
                      'Saved contacts',
                      '${offline.length}',
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: _card(
                      children: [
                        for (var i = 0; i < offline.length; i++) ...[
                          if (i > 0) const _RowDivider(),
                          _savedRow(offline[i]),
                        ],
                      ],
                    ),
                  ),
                ],
                if (_peers.isEmpty && offline.isEmpty)
                  SliverToBoxAdapter(child: _emptyHint()),
                const SliverToBoxAdapter(child: SizedBox(height: 130)),
              ],
            );
          },
        ),
      ),
      extendBody: true,
      bottomNavigationBar: _MeshBottomBar(
        onHome: () {},
        onPeers: _openDiscoverPeers,
        onFiles: _openReceivedFiles,
        onSend: _openSendFile,
      ),
    );
  }

  // ── Pieces ────────────────────────────────────────────────────────────────

  Widget _topBar() => Padding(
    padding: const EdgeInsets.fromLTRB(20, 12, 12, 0),
    child: Row(
      children: [
        const MeshWordmark(),
        const Spacer(),
        IconButton(
          onPressed: _openReceivedFiles,
          icon: const Icon(Icons.folder_open_outlined),
          tooltip: 'Received files',
        ),
        IconButton(
          onPressed: _openDiscoverPeers,
          icon: const Icon(Icons.radar_outlined),
          tooltip: 'Discover devices',
        ),
      ],
    ),
  );

  Widget _hero() {
    final String line1, line2;
    if (_scanning && _peers.isEmpty) {
      line1 = 'Looking for';
      line2 = 'devices nearby';
    } else if (_peers.isNotEmpty) {
      line1 = _peers.length == 1 ? '1 device' : '${_peers.length} devices';
      line2 = 'in range now';
    } else {
      line1 = 'Share nearby.';
      line2 = 'Off the grid.';
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
      child: RichText(
        text: TextSpan(
          style: Theme.of(context).textTheme.displayMedium,
          children: [
            TextSpan(text: '$line1\n'),
            TextSpan(
              text: line2,
              style: const TextStyle(color: MeshColors.copper),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusCard() {
    final online = _peers.isNotEmpty;
    final String status;
    final Color dot;
    if (_scanning) {
      status = 'Scanning for MeshShare devices…';
      dot = MeshColors.copper;
    } else if (online) {
      status = 'Connected to the mesh';
      dot = MeshColors.success;
    } else {
      status = 'Not connected — tap scan to find devices';
      dot = MeshColors.textFaint;
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: MeshColors.surface,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: MeshColors.outline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _PulseDot(color: dot, pulsing: _scanning),
                const SizedBox(width: 10),
                const Text(
                  'Mesh status',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                    color: MeshColors.textDim,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(status, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _scanning ? null : _openDiscoverPeers,
                    icon: Icon(
                      _scanning ? Icons.bluetooth_searching : Icons.radar,
                      size: 19,
                    ),
                    label: Text(_scanning ? 'Scanning…' : 'Scan for devices'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                _SquareButton(
                  icon: Icons.send_rounded,
                  onTap: _openSendFile,
                  tooltip: 'Send a file',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _card({required List<Widget> children}) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: Container(
      decoration: BoxDecoration(
        color: MeshColors.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: MeshColors.outline),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: children),
    ),
  );

  Widget _onlinePeerRow(MeshNode node, PeerContactStore contacts) {
    final name = contacts.nameFor(node.shortId, fallback: node.displayName);
    final blocked = contacts.isBlocked(node.shortId);
    return _PeerRow(
      title: name,
      subtitle: blocked
          ? '${node.shortId} · relaying only'
          : '${node.shortId} · in range',
      leading: _Avatar(text: node.shortId.substring(0, 2), online: true),
      trailing: blocked ? const _BlockedChip() : _RssiBars(rssi: node.rssi),
      onTap: () => _openChat(node.shortId, name, target: node),
      onLongPress: () => _peerActions(node.shortId, name, node: node),
    );
  }

  Widget _savedRow(PeerContact contact) => _PeerRow(
    title: contact.displayName,
    subtitle: contact.blocked
        ? '${contact.peerId} · blocked'
        : '${contact.peerId} · offline',
    leading: _Avatar(text: contact.displayName, online: false),
    trailing: contact.blocked
        ? const _BlockedChip()
        : const Icon(Icons.chevron_right, color: MeshColors.textFaint),
    onTap: () => _openChat(contact.peerId, contact.displayName),
    onLongPress: () => _peerActions(contact.peerId, contact.displayName),
  );

  void _peerActions(String peerId, String name, {MeshNode? node}) {
    final contacts = context.read<PeerContactStore>();
    final blocked = contacts.isBlocked(peerId);
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            if (!blocked) ...[
              ListTile(
                leading: const Icon(Icons.chat_bubble_outline),
                title: const Text('Open chat'),
                onTap: () {
                  Navigator.pop(context);
                  _openChat(peerId, name, target: node);
                },
              ),
              if (node != null)
                ListTile(
                  leading: const Icon(Icons.send_rounded),
                  title: const Text('Send a file'),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => SendFileScreen(target: node),
                      ),
                    );
                  },
                ),
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Rename'),
                onTap: () {
                  Navigator.pop(context);
                  _renamePeer(peerId, name);
                },
              ),
            ],
            ListTile(
              leading: Icon(
                blocked ? Icons.person_add_alt_1_outlined : Icons.block,
                color: blocked ? MeshColors.text : MeshColors.danger,
              ),
              title: Text(
                blocked ? 'Unblock' : 'Block',
                style: TextStyle(
                  color: blocked ? MeshColors.text : MeshColors.danger,
                ),
              ),
              subtitle: Text(
                blocked
                    ? 'Start receiving messages and files again'
                    : 'Stop messages and files from this contact',
              ),
              onTap: () {
                Navigator.pop(context);
                _setBlocked(peerId, name, !blocked);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _setBlocked(String peerId, String name, bool blocked) async {
    await context.read<PeerContactStore>().setBlocked(
      peerId,
      blocked,
      displayName: name,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          blocked
              ? '$name blocked. They can still relay mesh traffic, but their '
                    'messages and files to you are dropped.'
              : '$name unblocked.',
        ),
      ),
    );
  }

  Widget _emptyHint() => Padding(
    padding: const EdgeInsets.fromLTRB(28, 40, 28, 0),
    child: Column(
      children: [
        Icon(
          Icons.wifi_tethering_off_rounded,
          size: 44,
          color: MeshColors.textFaint,
        ),
        const SizedBox(height: 14),
        Text(
          'No devices yet',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 6),
        Text(
          'Keep Bluetooth on, stay close to another\nMeshShare device, and tap scan.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ],
    ),
  );
}

// ── Section header ─────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String title;
  final String? count;
  const _SectionHeader(this.title, [this.count]);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(22, 0, 22, 12),
    child: Row(
      children: [
        Text(
          title.toUpperCase(),
          style: const TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.1,
            color: MeshColors.textDim,
          ),
        ),
        if (count != null) ...[
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
            decoration: BoxDecoration(
              color: MeshColors.surfaceHigh,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              count!,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: MeshColors.textDim,
              ),
            ),
          ),
        ],
      ],
    ),
  );
}

// ── Peer row ───────────────────────────────────────────────────────────────

class _PeerRow extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget leading;
  final Widget trailing;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _PeerRow({
    required this.title,
    required this.subtitle,
    required this.leading,
    required this.trailing,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    onLongPress: onLongPress,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          leading,
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: MeshColors.text,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: MeshColors.textDim,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          trailing,
        ],
      ),
    ),
  );
}

class _RowDivider extends StatelessWidget {
  const _RowDivider();
  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.only(left: 62),
    child: Divider(height: 1),
  );
}

class _Avatar extends StatelessWidget {
  final String text;
  final bool online;
  const _Avatar({required this.text, required this.online});

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: MeshColors.surfaceHigh,
            shape: BoxShape.circle,
            border: Border.all(color: MeshColors.outline),
          ),
          alignment: Alignment.center,
          child: Text(
            text.substring(0, text.length >= 2 ? 2 : 1).toUpperCase(),
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: MeshColors.textDim,
            ),
          ),
        ),
        if (online)
          Positioned(
            right: -1,
            bottom: -1,
            child: Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: MeshColors.success,
                shape: BoxShape.circle,
                border: Border.all(color: MeshColors.surface, width: 2.5),
              ),
            ),
          ),
      ],
    );
  }
}

// ── Small controls ─────────────────────────────────────────────────────────

class _SquareButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final String tooltip;
  const _SquareButton({
    required this.icon,
    required this.onTap,
    required this.tooltip,
  });

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Material(
      color: MeshColors.surfaceHigh,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: 48,
          height: 48,
          child: Icon(icon, color: MeshColors.text, size: 20),
        ),
      ),
    ),
  );
}

class _PulseDot extends StatefulWidget {
  final Color color;
  final bool pulsing;
  const _PulseDot({required this.color, required this.pulsing});

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    );
    if (widget.pulsing) _c.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(_PulseDot old) {
    super.didUpdateWidget(old);
    if (widget.pulsing && !_c.isAnimating) {
      _c.repeat(reverse: true);
    } else if (!widget.pulsing && _c.isAnimating) {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dot = Container(
      width: 9,
      height: 9,
      decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
    );
    if (!widget.pulsing) return dot;
    return FadeTransition(
      opacity: Tween(begin: 0.35, end: 1.0).animate(_c),
      child: dot,
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
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.end,
    children: List.generate(4, (i) {
      return Container(
        width: 3.5,
        height: 6.0 + i * 4.0,
        margin: const EdgeInsets.symmetric(horizontal: 1.5),
        decoration: BoxDecoration(
          color: i < _activeBars ? MeshColors.copper : MeshColors.outline,
          borderRadius: BorderRadius.circular(2),
        ),
      );
    }),
  );
}

class _BlockedChip extends StatelessWidget {
  const _BlockedChip();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: MeshColors.danger.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(999),
      border: Border.all(color: MeshColors.danger.withValues(alpha: 0.35)),
    ),
    child: const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.block, size: 12, color: MeshColors.danger),
        SizedBox(width: 5),
        Text(
          'Blocked',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: MeshColors.danger,
          ),
        ),
      ],
    ),
  );
}

// ── Floating bottom bar ────────────────────────────────────────────────────

class _MeshBottomBar extends StatelessWidget {
  final VoidCallback onHome;
  final VoidCallback onPeers;
  final VoidCallback onFiles;
  final VoidCallback onSend;

  const _MeshBottomBar({
    required this.onHome,
    required this.onPeers,
    required this.onFiles,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        22,
        0,
        22,
        14 + MediaQuery.of(context).padding.bottom,
      ),
      child: Container(
        height: 64,
        decoration: BoxDecoration(
          color: MeshColors.surfaceHigh,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: MeshColors.outline),
          boxShadow: const [
            BoxShadow(
              color: Colors.black54,
              blurRadius: 24,
              offset: Offset(0, 8),
            ),
          ],
        ),
        child: Row(
          children: [
            _BarIcon(icon: Icons.home_rounded, active: true, onTap: onHome),
            _BarIcon(icon: Icons.groups_2_outlined, onTap: onPeers),
            _CenterButton(onTap: onSend),
            _BarIcon(icon: Icons.folder_open_outlined, onTap: onFiles),
            _BarIcon(
              icon: Icons.shield_outlined,
              onTap: () => _showAbout(context),
            ),
          ],
        ),
      ),
    );
  }

  void _showAbout(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => const _AboutSheet(),
    );
  }
}

class _BarIcon extends StatelessWidget {
  final IconData icon;
  final bool active;
  final VoidCallback onTap;
  const _BarIcon({required this.icon, required this.onTap, this.active = false});

  @override
  Widget build(BuildContext context) => Expanded(
    child: InkResponse(
      onTap: onTap,
      radius: 28,
      child: Icon(
        icon,
        size: 23,
        color: active ? MeshColors.text : MeshColors.textFaint,
      ),
    ),
  );
}

class _CenterButton extends StatelessWidget {
  final VoidCallback onTap;
  const _CenterButton({required this.onTap});

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 66,
    child: Center(
      child: Material(
        color: MeshColors.copper,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: const SizedBox(
            width: 48,
            height: 48,
            child: Icon(Icons.add_rounded, color: MeshColors.copperInk, size: 26),
          ),
        ),
      ),
    ),
  );
}

class _AboutSheet extends StatelessWidget {
  const _AboutSheet();

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(24, 22, 24, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const MeshLogo(size: 48),
          const SizedBox(height: 16),
          Text('MeshShare', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 6),
          Text(
            'Files and messages that travel device-to-device over a '
            'Bluetooth Low Energy mesh. Nothing touches the internet, and '
            'every transfer is end-to-end encrypted.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    ),
  );
}
