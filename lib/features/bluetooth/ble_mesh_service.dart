import 'dart:async';
import 'dart:developer' as developer;
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../../core/constants.dart';
import '../../core/utils.dart';
import '../../core/log.dart';
import '../crypto/key_manager.dart';
import '../crypto/noise_handshake.dart';
import '../file_transfer/chunk_model.dart';
import '../peers/peer_contact_store.dart';
import 'mesh_node.dart';
import 'platform_channel.dart';

enum TxNotificationType { empty, keepalive, meshPacket, handshakeResponse, unknown }

/// Why a peer stopped being a live direct neighbour.
enum PeerLostReason {
  /// The GATT link dropped (peer walked out of range, peer app closed, OS
  /// tore the connection down).
  connectionLost,

  /// Repeated keepalives went unanswered and nothing was heard for the
  /// unreachable window — peer is out of range or its Bluetooth is off.
  unreachable,

  /// This device's own Bluetooth adapter was turned off.
  bluetoothOff,
}

/// A direct neighbour became unavailable. Carries a human-readable reason so
/// the UI can tell the user *why* a chat/transfer partner went offline.
class PeerLostEvent {
  final String shortId;
  final PeerLostReason reason;
  const PeerLostEvent(this.shortId, this.reason);

  /// One-line explanation suitable for a snackbar or chat banner.
  String message(String peerName) => switch (reason) {
    PeerLostReason.connectionLost =>
      '$peerName went offline — the Bluetooth connection was lost.',
    PeerLostReason.unreachable =>
      '$peerName is no longer reachable. They may be out of range or have '
          'turned Bluetooth off.',
    PeerLostReason.bluetoothOff =>
      'Bluetooth is off on this device — $peerName and other peers are '
          'disconnected until you turn it back on.',
  };
}

@visibleForTesting
TxNotificationType classifyTxNotification(List<int> bytes) {
  if (bytes.isEmpty) return TxNotificationType.empty;

  final type = bytes[0] & 0xff;
  if (type == 0x00) return TxNotificationType.keepalive;
  if (type == 0xFE && bytes.length >= 2) {
    return TxNotificationType.handshakeResponse;
  }
  // Chunk (0x01), ACK (0xFF), routed handshake (0x02), presence announce
  // (0x03) — all dispatched uniformly by BleMeshService regardless of
  // whether they arrived via RX-write or TX-notify.
  if (type == 0x01 || type == 0x02 || type == 0x03 || type == 0xFF) {
    return TxNotificationType.meshPacket;
  }
  return TxNotificationType.unknown;
}

// ── Mesh packet wire formats ────────────────────────────────────────────────
//
// Pure encode/decode for the flooded packet types — no instance state, so
// they're plain top-level functions (matching classifyTxNotification above)
// and can be exercised directly in unit tests without any BLE transport.

/// ACK packet: `[0xFF][ttl(1)][destPeerId(8)][srcPeerId(8)][fileId(36)][chunkIndex(4 BE)]`.
/// [destPeerId] is who to route the ACK back to (the original chunk sender).
@visibleForTesting
Uint8List buildAckPacket({
  required int ttl,
  required String destPeerId,
  required String srcPeerId,
  required String fileId,
  required int chunkIndex,
}) {
  final buf = ByteData(1 + 1 + 8 + 8 + 36 + 4);
  int offset = 0;
  buf.setUint8(offset++, 0xFF);
  buf.setUint8(offset++, ttl);
  final result = buf.buffer.asUint8List();
  result.setRange(offset, offset + 8, hexToBytes(destPeerId));
  offset += 8;
  result.setRange(offset, offset + 8, hexToBytes(srcPeerId));
  offset += 8;
  result.setRange(offset, offset + 36, fileId.codeUnits);
  offset += 36;
  buf.setUint32(offset, chunkIndex, Endian.big);
  return result;
}

/// Parses a payload built by [buildAckPacket] (type byte already stripped).
/// Returns null if [payload] is too short to be a valid ACK.
@visibleForTesting
({int ttl, String destPeerId, String srcPeerId, String fileId, int chunkIndex})?
parseAckPacket(Uint8List payload) {
  if (payload.length < 57) return null; // ttl(1)+dest(8)+src(8)+fileId(36)+idx(4)
  final ttl = payload[0];
  final destPeerId = bytesToHex(payload.sublist(1, 9));
  final srcPeerId = bytesToHex(payload.sublist(9, 17));
  final fileId = String.fromCharCodes(payload.sublist(17, 53));
  final bd = ByteData.sublistView(payload);
  final chunkIndex = bd.getUint32(53, Endian.big);
  return (
    ttl: ttl,
    destPeerId: destPeerId,
    srcPeerId: srcPeerId,
    fileId: fileId,
    chunkIndex: chunkIndex,
  );
}

/// Routed (multi-hop) Noise handshake envelope:
/// `[0x02][ttl(1)][step(1)][srcPeerId(8)][dstPeerId(8)][nonce(4 BE)][msgLen(2 BE)][msg]`.
@visibleForTesting
Uint8List buildRoutedHandshakePacket({
  required int ttl,
  required int step,
  required String srcPeerId,
  required String dstPeerId,
  required int nonce,
  required Uint8List msg,
}) {
  final buf = ByteData(1 + 1 + 1 + 8 + 8 + 4 + 2 + msg.length);
  int offset = 0;
  buf.setUint8(offset++, 0x02);
  buf.setUint8(offset++, ttl);
  buf.setUint8(offset++, step);
  final result = buf.buffer.asUint8List();
  result.setRange(offset, offset + 8, hexToBytes(srcPeerId));
  offset += 8;
  result.setRange(offset, offset + 8, hexToBytes(dstPeerId));
  offset += 8;
  buf.setUint32(offset, nonce, Endian.big);
  offset += 4;
  buf.setUint16(offset, msg.length, Endian.big);
  offset += 2;
  result.setRange(offset, offset + msg.length, msg);
  return result;
}

/// Parses a payload built by [buildRoutedHandshakePacket] (type byte already
/// stripped). Returns null if [payload] is too short or truncated.
@visibleForTesting
({int ttl, int step, String srcPeerId, String dstPeerId, int nonce, Uint8List msg})?
parseRoutedHandshakePacket(Uint8List payload) {
  // ttl(1) + step(1) + srcPeerId(8) + dstPeerId(8) + nonce(4) + msgLen(2)
  if (payload.length < 24) return null;
  final ttl = payload[0];
  final step = payload[1];
  final srcPeerId = bytesToHex(payload.sublist(2, 10));
  final dstPeerId = bytesToHex(payload.sublist(10, 18));
  final bd = ByteData.sublistView(payload);
  final nonce = bd.getUint32(18, Endian.big);
  final msgLen = bd.getUint16(22, Endian.big);
  if (payload.length < 24 + msgLen) return null;
  final msg = payload.sublist(24, 24 + msgLen);
  return (
    ttl: ttl,
    step: step,
    srcPeerId: srcPeerId,
    dstPeerId: dstPeerId,
    nonce: nonce,
    msg: msg,
  );
}

/// Presence announce packet: `[0x03][ttl(1)][peerId(8)][nonce(4 BE)]`.
@visibleForTesting
Uint8List buildAnnouncePacket({
  required int ttl,
  required String peerId,
  required int nonce,
}) {
  final buf = ByteData(1 + 1 + 8 + 4);
  int offset = 0;
  buf.setUint8(offset++, 0x03);
  buf.setUint8(offset++, ttl);
  final result = buf.buffer.asUint8List();
  result.setRange(offset, offset + 8, hexToBytes(peerId));
  offset += 8;
  buf.setUint32(offset, nonce, Endian.big);
  return result;
}

/// Parses a payload built by [buildAnnouncePacket] (type byte already
/// stripped). Returns null if [payload] is too short.
@visibleForTesting
({int ttl, String peerId, int nonce})? parseAnnouncePacket(Uint8List payload) {
  if (payload.length < 13) return null; // ttl(1) + peerId(8) + nonce(4)
  final ttl = payload[0];
  final peerId = bytesToHex(payload.sublist(1, 9));
  final bd = ByteData.sublistView(payload);
  final nonce = bd.getUint32(9, Endian.big);
  return (ttl: ttl, peerId: peerId, nonce: nonce);
}

/// Central BLE Mesh service — manages discovery, connections, keepalives,
/// chunk transfer, and relay forwarding for all MeshShare peers.
///
/// Every device simultaneously acts as:
///   - **Central** (scanner + GATT client) via flutter_blue_plus
///   - **Peripheral** (advertiser + GATT server) via [MeshPlatformChannel]
///
/// All mesh traffic beyond direct-neighbor link setup (chunks, ACKs, routed
/// handshakes, presence gossip) is flooded: forwarded to every currently
/// connected neighbor with a decrementing TTL and a dedup cache, regardless
/// of whether this device is the Central or Peripheral side of a given link.
/// This is what allows messages/files to cross a relay device without every
/// pair of devices needing to be directly connected.
///
/// Usage:
/// ```dart
/// final ble = BleMeshService();
/// await ble.start(localIdentity: myIdentityBytes);
/// ble.discoveredPeers.listen((node) { ... });
/// ble.incomingChunks.listen((chunk) { ... });
/// await ble.sendChunk(chunk); // chunk.destPeerId carries the routing info
/// ```
class BleMeshService {
  final MeshPlatformChannel _channel;
  final KeyManager _keys;
  final PeerContactStore? _contacts;

  BleMeshService({
    MeshPlatformChannel? channel,
    required KeyManager keys,
    PeerContactStore? contacts,
  }) : _channel = channel ?? MeshPlatformChannel(),
       _keys = keys,
       _contacts = contacts;

  // ── Identity ──────────────────────────────────────────────────────────────

  late Uint8List _localIdentity; // 32-byte Noise public key hash

  // ── Stream controllers ────────────────────────────────────────────────────

  final _peerController = StreamController<MeshNode>.broadcast();
  final _peerLostController = StreamController<PeerLostEvent>.broadcast();
  final _indirectPeerController = StreamController<MeshNode>.broadcast();
  final _chunkController = StreamController<FileChunk>.broadcast();
  final _discoveryLogController = StreamController<String>.broadcast();
  final _ackController =
      StreamController<
        ({String peerId, String fileId, int chunkIndex})
      >.broadcast();

  /// Emits a [MeshNode] each time a new MeshShare peer becomes ready to
  /// send/receive — whether the session was established directly or through
  /// a routed (multi-hop) handshake over the mesh.
  Stream<MeshNode> get discoveredPeers => _peerController.stream;

  /// Emits when a peer's direct GATT link drops, so the UI can stop showing
  /// it as online and tell the user why. Covers links where this device is
  /// the Central *or* the Peripheral.
  Stream<PeerLostEvent> get peerLost => _peerLostController.stream;

  /// Emits a [MeshNode] each time a peer is heard about via presence gossip
  /// but has no session yet (`deviceId` is null). Call [requestSecureSession]
  /// with its `shortId` to establish one; the resulting session then arrives
  /// through [discoveredPeers] like any other peer.
  Stream<MeshNode> get indirectPeers => _indirectPeerController.stream;

  /// Emits brief user-facing discovery and handshake progress messages.
  Stream<String> get discoveryLogs => _discoveryLogController.stream;

  /// Emits each encrypted [FileChunk] that arrives at this device (after dedup).
  /// [TransferManager] decrypts and reassembles these.
  Stream<FileChunk> get incomingChunks => _chunkController.stream;

  /// Emits ACK records when the remote peer confirms receipt of a chunk.
  Stream<({String peerId, String fileId, int chunkIndex})> get incomingAcks =>
      _ackController.stream;

  // ── Connection state ──────────────────────────────────────────────────────

  /// deviceId → BluetoothDevice (active GATT connections where we are Central).
  final Map<String, BluetoothDevice> _connections = {};

  /// Devices currently going through connect/discover/handshake.
  final Set<String> _connectingDeviceIds = {};

  /// deviceId → time before which another connection attempt should be skipped.
  final Map<String, DateTime> _connectRetryAfter = {};

  /// peerId → MeshNode (known peers — direct neighbors and routed sessions).
  final Map<String, MeshNode> _peers = {};

  /// deviceId → RX characteristic (we write outgoing chunks here). Only
  /// populated for links where we are Central.
  final Map<String, BluetoothCharacteristic> _rxChars = {};

  /// deviceId → MTU granted by that link (0/absent = unknown, use fallback).
  final Map<String, int> _negotiatedMtu = {};

  /// deviceId → last time we received ANY frame from this peer (Unix ms).
  /// Used to keep a link alive as long as data is flowing, and to decide
  /// when a peer is genuinely unreachable.
  final Map<String, int> _lastHeardFromDevice = {};

  /// deviceId → TX characteristic (we subscribe for notifications here).
  final Map<String, BluetoothCharacteristic> _txChars = {};

  /// deviceId → subscriptions for TX notifications.
  final Map<String, List<StreamSubscription<List<int>>>> _txNotificationSubs =
      {};

  /// deviceId → last TX notification key, used to ignore duplicate stream emits.
  final Map<String, String> _lastTxNotificationKeys = {};

  /// All device IDs currently reachable over a live GATT link, regardless of
  /// which side (Central/Peripheral) we are on that link.
  Set<String> get _allConnectedDeviceIds => {
    ..._connections.keys,
    ..._peers.values.map((n) => n.deviceId).whereType<String>(),
  };

  /// Largest plaintext payload we can safely put in one chunk, derived from
  /// the smallest MTU across current links (so a relay can forward it too).
  /// Falls back to [kBleChunkPayloadBytes] when no MTU is known yet.
  int get maxChunkPayloadBytes {
    final mtus = _negotiatedMtu.values.where((m) => m > 23);
    if (mtus.isEmpty) return kBleChunkPayloadBytes;
    final minMtu = mtus.reduce((a, b) => a < b ? a : b);
    final usable = minMtu - kChunkFixedOverheadBytes;
    if (usable < kBleChunkPayloadBytes) return kBleChunkPayloadBytes;
    return usable > kMaxChunkPayloadBytes ? kMaxChunkPayloadBytes : usable;
  }

  /// Record that we just received a frame from [deviceId] — any inbound
  /// traffic proves the link is alive, so it resets the keepalive strike
  /// count and the unreachable timer.
  void _notePeerActivity(String deviceId) {
    _lastHeardFromDevice[deviceId] = DateTime.now().millisecondsSinceEpoch;
    for (final entry in _peers.entries) {
      if (entry.value.deviceId == deviceId) {
        _keepaliveMissed[entry.key] = 0;
      }
    }
  }

  // ── Keepalive ─────────────────────────────────────────────────────────────

  /// peerId → consecutive missed keepalive count.
  final Map<String, int> _keepaliveMissed = {};

  /// peerId → periodic keepalive timer.
  final Map<String, Timer> _keepaliveTimers = {};

  // ── Relay deduplication ───────────────────────────────────────────────────

  /// LRU cache of dedup keys seen at this node — covers chunks
  /// (`fileId:chunkIndex`), ACKs, routed handshake steps, and presence
  /// announces. Prevents re-processing/re-forwarding the same packet twice
  /// (avoids relay loops in the flood).
  final LruCache<String> _dedupCache = LruCache(kDedupCacheMaxSize);

  // ── Scanning state ────────────────────────────────────────────────────────

  bool _running = false;
  DateTime? _lastNewPeerAt;
  Timer? _scanCycleTimer;
  Timer? _advertiseRefreshTimer;
  Timer? _announceTimer;
  Timer? _indirectExpiryTimer;
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothAdapterState>? _adapterSub;
  StreamSubscription<PeripheralLinkEvent>? _peripheralLinkSub;

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  /// Start advertising and the GATT server.
  ///
  /// [localIdentity] is the 32-byte SHA-256 hash of the device's Noise
  /// static public key — used as the stable peer identity.
  Future<void> start({required Uint8List localIdentity}) async {
    if (_running) return;
    _localIdentity = localIdentity;
    _running = true;
    _log('MeshShare is ready for nearby peers.');

    // Foreground-service startup is intentionally disabled during foreground
    // device testing. Recent Android versions require the connectedDevice FGS
    // type to be started only after Bluetooth runtime permissions are fully
    // granted; if the OS rejects it, the service crash kills the app. BLE still
    // works while MeshShare is open, which is enough for the project demo.

    // Start GATT server on the Android side; incoming events are
    // forwarded to Dart via the typed event channel.
    await _channel.startGattServer();
    _channel.incomingPackets.listen(
      (e) => _onMeshPacket(e.deviceId, e.data),
    );
    // Responder side: handle incoming handshake messages from Centrals.
    _channel.incomingHandshakeMessages.listen(_onIncomingHandshakeMessage);
    // Responder side: a Central dropped its link to our GATT server — clean up
    // that peer so it stops showing as online here.
    _peripheralLinkSub = _channel.peripheralLinkEvents.listen((e) {
      meshLog('peripheralLink deviceId=${e.deviceId} connected=${e.connected}');
      if (!e.connected) _onDeviceDisconnected(e.deviceId);
    });

    // Watch adapter state — restart scanning if BT is toggled, and tell the
    // UI when our own Bluetooth goes off so it can explain the disconnects.
    _adapterSub = FlutterBluePlus.adapterState.listen((state) {
      if (state == BluetoothAdapterState.on && _running) {
        _log('Bluetooth is on.');
        _scheduleAdvertiseRefresh();
      } else if (state == BluetoothAdapterState.off) {
        _log('Bluetooth is off — all peers disconnected.');
        for (final deviceId
            in _allConnectedDeviceIds.toList(growable: false)) {
          _onDeviceDisconnected(
            deviceId,
            reason: PeerLostReason.bluetoothOff,
          );
        }
      }
    });

    _scheduleAnnounce();
    _scheduleIndirectPeerExpiry();

    if (await FlutterBluePlus.adapterState.first == BluetoothAdapterState.on) {
      _scheduleAdvertiseRefresh();
    }
  }

  /// Start an explicit user-requested discovery pass.
  Future<void> discoverPeers() async {
    if (!_running) {
      _log('MeshShare is not ready yet.');
      return;
    }
    _log('Scanning for nearby MeshShare devices...');
    _startScanCycle();
  }

  /// Stop all BLE activity and release resources.
  Future<void> stop() async {
    _running = false;
    _scanCycleTimer?.cancel();
    _advertiseRefreshTimer?.cancel();
    _announceTimer?.cancel();
    _indirectExpiryTimer?.cancel();
    _scanSub?.cancel();
    _adapterSub?.cancel();
    _peripheralLinkSub?.cancel();
    await FlutterBluePlus.stopScan();

    for (final timer in _keepaliveTimers.values) {
      timer.cancel();
    }
    _keepaliveTimers.clear();
    for (final timer in _routedHandshakeTimers.values) {
      timer.cancel();
    }
    _routedHandshakeTimers.clear();
    _pendingRoutedInitiators.clear();
    _pendingRoutedResponders.clear();
    _routedHandshakeCompleters.clear();
    _knownIndirectPeers.clear();

    for (final device in _connections.values) {
      await device.disconnect();
    }
    _connections.clear();
    _rxChars.clear();
    _txChars.clear();
    for (final subs in _txNotificationSubs.values) {
      for (final sub in subs) {
        await sub.cancel();
      }
    }
    _txNotificationSubs.clear();
    _lastTxNotificationKeys.clear();

    await _channel.stopGattServer();
    // Foreground service is not started in the current foreground-only demo.

    await _peerController.close();
    await _peerLostController.close();
    await _indirectPeerController.close();
    await _chunkController.close();
    await _discoveryLogController.close();
    await _ackController.close();
  }

  // ── Scanning ──────────────────────────────────────────────────────────────

  void _startScanCycle() {
    _scanCycleTimer?.cancel();
    _doScan();

    // Adaptive interval: active every 5s while peers are being found,
    // drops to 30s once the network has been quiet for 60s.
    _scanCycleTimer = Timer.periodic(
      const Duration(milliseconds: kScanIntervalActiveMs),
      (_) {
        final idleSince = _lastNewPeerAt;
        final idleMs = idleSince == null
            ? 0
            : DateTime.now().difference(idleSince).inMilliseconds;

        if (idleMs > 60000) {
          // Idle — slow down to 30s interval.
          _scanCycleTimer?.cancel();
          _scanCycleTimer = Timer.periodic(
            const Duration(milliseconds: kScanIntervalIdleMs),
            (_) => _doScan(),
          );
        }
        _doScan();
      },
    );
  }

  Future<void> _doScan() async {
    if (!_running) return;
    if (_connectingDeviceIds.isNotEmpty || _pendingInitiators.isNotEmpty) {
      return;
    }
    await FlutterBluePlus.stopScan();
    await _scanSub?.cancel();

    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      for (final result in results) {
        _onScanResult(result);
      }
    });

    try {
      await FlutterBluePlus.startScan(
        withServices: [Guid(kServiceUuid)],
        timeout: const Duration(seconds: 4),
      );
    } catch (e, st) {
      developer.log(
        'BLE scan failed to start',
        name: 'MeshShare.BLE',
        error: e,
        stackTrace: st,
      );
      if (e is PlatformException &&
          (e.message?.toLowerCase().contains('location') ?? false)) {
        _log('Please enable Location Services to scan for nearby devices.');
      } else {
        _log('Could not start scanning for nearby devices.');
      }
    }
  }

  void _onScanResult(ScanResult result) {
    final deviceId = result.device.remoteId.str;
    if (_connections.containsKey(deviceId)) return; // already connected
    if (_connectingDeviceIds.contains(deviceId)) return; // already connecting

    final retryAfter = _connectRetryAfter[deviceId];
    if (retryAfter != null && DateTime.now().isBefore(retryAfter)) return;

    _lastNewPeerAt = DateTime.now();
    _log('Found a MeshShare device. Connecting...');
    _connectingDeviceIds.add(deviceId);
    _scanCycleTimer?.cancel();
    unawaited(
      _connectToDevice(result.device, result.rssi, _displayNameFor(result)),
    );
  }

  String? _displayNameFor(ScanResult result) {
    final names = <String?>[];

    try {
      names.add((result.device as dynamic).platformName as String?);
    } catch (_) {}

    try {
      names.add((result.device as dynamic).name as String?);
    } catch (_) {}

    try {
      names.add((result.advertisementData as dynamic).advName as String?);
    } catch (_) {}

    try {
      names.add((result.advertisementData as dynamic).localName as String?);
    } catch (_) {}

    for (final name in names) {
      final clean = name?.trim();
      if (clean != null && clean.isNotEmpty) return clean;
    }
    return null;
  }

  // ── Advertising refresh ───────────────────────────────────────────────────

  void _scheduleAdvertiseRefresh() {
    _advertiseRefreshTimer?.cancel();
    _advertiseRefreshTimer = Timer.periodic(
      const Duration(milliseconds: kAdvertiseRefreshMs),
      (_) async {
        if (_running) await _channel.refreshAdvertising(_localIdentity);
      },
    );
    // Advertise immediately on start.
    _channel.refreshAdvertising(_localIdentity);
  }

  // ── GATT connection ───────────────────────────────────────────────────────

  Future<void> _connectToDevice(
    BluetoothDevice device,
    int rssi,
    String? displayName,
  ) async {
    final deviceId = device.remoteId.str;
    try {
      _log('Opening Bluetooth connection...');
      await FlutterBluePlus.stopScan();
      await device.connect(timeout: const Duration(seconds: 10));
      _connections[deviceId] = device;
      _connectRetryAfter.remove(deviceId);

      // Ask for the fastest connection interval — roughly 3–4x the default
      // throughput, which matters a lot for multi-megabyte file transfers.
      try {
        await device.requestConnectionPriority(
          connectionPriorityRequest: ConnectionPriority.high,
        );
      } catch (e) {
        meshLog('requestConnectionPriority failed for $deviceId: $e');
      }

      _log('Preparing secure transfer channel...');
      // Negotiate the largest MTU the link allows so file chunks aren't
      // fragmented into tiny 20-byte packets. The granted value drives the
      // actual chunk size — see [maxChunkPayloadBytes].
      try {
        final granted = await device.requestMtu(kRequestedMtu);
        _negotiatedMtu[deviceId] = granted;
        meshLog('MTU negotiated with $deviceId: $granted');
      } catch (e) {
        meshLog('MTU negotiation failed for $deviceId: $e');
      }

      // Listen for disconnection.
      device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _onDeviceDisconnected(deviceId);
        }
      });

      final services = await device.discoverServices();
      final meshService = services.firstWhere(
        (s) => s.serviceUuid == Guid(kServiceUuid),
        orElse: () =>
            throw Exception('MeshShare service not found on $deviceId'),
      );

      BluetoothCharacteristic? rxChar;
      BluetoothCharacteristic? txChar;
      BluetoothCharacteristic? identityChar;

      for (final c in meshService.characteristics) {
        final uuid = c.characteristicUuid.toString().toLowerCase();
        if (uuid == kRxCharUuid) rxChar = c;
        if (uuid == kTxCharUuid) txChar = c;
        if (uuid == kIdentityCharUuid) identityChar = c;
      }

      if (rxChar == null || txChar == null || identityChar == null) {
        throw Exception('Required GATT characteristics missing on $deviceId');
      }

      _rxChars[deviceId] = rxChar;
      _txChars[deviceId] = txChar;

      // Exchange identity.
      _log('Exchanging peer identity...');
      await identityChar.write(_localIdentity, withoutResponse: false);
      final peerIdentityBytes = await identityChar.read();
      final peerIdentity = Uint8List.fromList(peerIdentityBytes);
      final peerId = bytesToHex(peerIdentity);

      final node = MeshNode(
        identity: peerIdentity,
        deviceId: deviceId,
        displayName: displayName,
        rssi: rssi,
        lastSeenMs: DateTime.now().millisecondsSinceEpoch,
      );
      // Keep the peer internally while the handshake completes, but do not
      // expose it to the UI until session keys are available for sending.
      _peers[peerId] = node;

      // Subscribe before enabling notifications so the handshake response cannot
      // arrive between the CCCD write and our Dart listener registration.
      final previousSubs = _txNotificationSubs.remove(deviceId);
      if (previousSubs != null) {
        for (final sub in previousSubs) {
          await sub.cancel();
        }
      }
      void handleTxBytes(List<int> bytes) => _onTxNotification(
        deviceId: deviceId,
        peerId: peerId,
        node: node,
        bytes: bytes,
      );

      _txNotificationSubs[deviceId] = [
        txChar.onValueReceived.listen(handleTxBytes),
        txChar.lastValueStream.listen(handleTxBytes),
      ];
      await txChar.setNotifyValue(true);

      // ── Noise_XX handshake (initiator side) ────────────────────────────────
      _log('Starting secure handshake...');
      await _performHandshakeAsInitiator(
        deviceId: deviceId,
        peerId: peerId,
        rxChar: rxChar,
      );
    } catch (e, st) {
      developer.log(
        'Could not complete BLE discovery for $deviceId',
        name: 'MeshShare.BLE',
        error: e,
        stackTrace: st,
      );
      _log('Could not complete discovery for one device: $e');
      _connectRetryAfter[deviceId] = DateTime.now().add(
        const Duration(seconds: 15),
      );
      _connections.remove(deviceId);
      _rxChars.remove(deviceId);
      _txChars.remove(deviceId);
      final subs = _txNotificationSubs.remove(deviceId);
      if (subs != null) {
        for (final sub in subs) {
          await sub.cancel();
        }
      }
      _lastTxNotificationKeys.remove(deviceId);
      _peers.removeWhere((_, node) => node.deviceId == deviceId);
      try {
        await device.disconnect();
      } catch (_) {
        // Already disconnected.
      }
    } finally {
      _connectingDeviceIds.remove(deviceId);
      if (_running && _connections.isEmpty && _pendingInitiators.isEmpty) {
        _startScanCycle();
      }
    }
  }

  void _onDeviceDisconnected(
    String deviceId, {
    PeerLostReason reason = PeerLostReason.connectionLost,
  }) {
    // Ignore spurious disconnects for a link that isn't actually ours.
    final hadLink =
        _connections.containsKey(deviceId) ||
        _peers.values.any((n) => n.deviceId == deviceId);
    if (!hadLink) return;

    meshLog(
      '_onDeviceDisconnected deviceId=$deviceId reason=$reason '
      'peersBefore=${_peers.values.map((n) => n.shortId).toList()}',
    );
    _connections.remove(deviceId);
    _rxChars.remove(deviceId);
    _txChars.remove(deviceId);
    _negotiatedMtu.remove(deviceId);
    _lastHeardFromDevice.remove(deviceId);
    final subs = _txNotificationSubs.remove(deviceId);
    if (subs != null) {
      for (final sub in subs) {
        unawaited(sub.cancel());
      }
    }
    _lastTxNotificationKeys.remove(deviceId);

    // Find and remove the peer entry for this device.
    _peers.removeWhere((peerId, node) {
      if (node.deviceId == deviceId) {
        _keepaliveTimers[peerId]?.cancel();
        _keepaliveTimers.remove(peerId);
        _keepaliveMissed.remove(peerId);
        _keys.clearSession(node.shortId);
        if (!_peerLostController.isClosed) {
          _peerLostController.add(PeerLostEvent(node.shortId, reason));
        }
        return true;
      }
      return false;
    });
  }

  // ── Keepalive ─────────────────────────────────────────────────────────────

  void _startKeepalive(String peerId, String deviceId) {
    _keepaliveMissed[peerId] = 0;
    _lastHeardFromDevice[deviceId] = DateTime.now().millisecondsSinceEpoch;
    _keepaliveTimers[peerId]?.cancel();

    _keepaliveTimers[peerId] = Timer.periodic(
      const Duration(milliseconds: kKeepaliveIntervalMs),
      (_) async {
        final rx = _rxChars[deviceId];
        if (rx == null) return;

        final now = DateTime.now().millisecondsSinceEpoch;
        final quietFor = now - (_lastHeardFromDevice[deviceId] ?? now);

        // Anything received from the peer recently (chunks, ACKs, gossip,
        // keepalive echo) means the link is fine — don't even count a strike.
        if (quietFor < kKeepaliveIntervalMs) {
          _keepaliveMissed[peerId] = 0;
        }

        try {
          await rx.write([0x00], withoutResponse: true);
        } catch (_) {
          // The write itself failed — the GATT link is gone.
          _onDeviceDisconnected(deviceId, reason: PeerLostReason.connectionLost);
          return;
        }

        _keepaliveMissed[peerId] = (_keepaliveMissed[peerId] ?? 0) + 1;

        final strikes = _keepaliveMissed[peerId] ?? 0;
        if (strikes >= kKeepaliveMaxMissed && quietFor >= kPeerUnreachableMs) {
          // Repeated keepalives with zero response AND total silence for the
          // unreachable window — treat the peer as gone.
          meshLog(
            'keepalive: peer $deviceId unreachable '
            '(strikes=$strikes quietFor=${quietFor}ms)',
          );
          _onDeviceDisconnected(deviceId, reason: PeerLostReason.unreachable);
          _connections[deviceId]?.disconnect();
        }
      },
    );
  }

  // ── Flood send ────────────────────────────────────────────────────────────

  /// Send [packet] to every currently connected neighbor, regardless of
  /// whether we are the Central or Peripheral side of that link.
  ///
  /// This is the single primitive behind chunk origination/relay, ACK
  /// routing, routed handshakes, and presence gossip. Combined with a TTL
  /// byte in every packet and the dedup cache, this is enough to deliver
  /// traffic across multiple hops without a routing table.
  Future<void> _floodSend(Uint8List packet, {String? excludeDeviceId}) async {
    final ids = _allConnectedDeviceIds;
    meshLog(
      '_floodSend type=0x${packet.isNotEmpty ? packet[0].toRadixString(16) : "?"} '
      'neighbors=${ids.length} conns=${_connections.keys.toList()} '
      'peerDevIds=${_peers.values.map((n) => n.deviceId).toList()} '
      'rxChars=${_rxChars.keys.toList()}',
    );
    for (final id in ids) {
      if (id == excludeDeviceId) continue;
      try {
        final rx = _rxChars[id];
        if (rx != null) {
          // We're Central on this link — write to the neighbor's RX char.
          await rx.write(packet, withoutResponse: true);
          meshLog('_floodSend -> Central write to $id ok');
        } else {
          // We're Peripheral on this link — notify via our TX char.
          await _channel.sendRawNotification(deviceId: id, data: packet);
          meshLog('_floodSend -> Peripheral notify to $id ok');
        }
      } catch (e) {
        meshLog('_floodSend -> $id failed: $e');
        // Best-effort per-neighbor forward — one bad link shouldn't stop the rest.
      }
    }
  }

  // ── Sending ───────────────────────────────────────────────────────────────

  /// Encrypt-and-flood [chunk] into the mesh.
  ///
  /// The chunk's own `originPeerId`/`destPeerId` fields carry true end-to-end
  /// routing information, so this does not require (or use) a direct GATT
  /// link to the final recipient — it works identically for a directly
  /// connected peer and one several relay hops away.
  Future<void> sendChunk(FileChunk chunk) async {
    final chunkBytes = chunk.toBytes();
    final packet = Uint8List(1 + chunkBytes.length);
    packet[0] = 0x01; // type: chunk
    packet.setAll(1, chunkBytes);
    await _floodSend(packet);
  }

  /// Send an ACK for [chunkIndex] of transfer [fileId], routed back to
  /// [originPeerId] (the transfer's original sender) over the mesh.
  Future<void> sendAck({
    required String fileId,
    required int chunkIndex,
    required String originPeerId,
  }) async {
    final myPeerId = (await _keys.localPeerId()).substring(0, 16);
    final packet = buildAckPacket(
      ttl: kDefaultTtl,
      destPeerId: originPeerId,
      srcPeerId: myPeerId,
      fileId: fileId,
      chunkIndex: chunkIndex,
    );
    await _floodSend(packet);
  }

  // ── Receiving ─────────────────────────────────────────────────────────────

  void _onTxNotification({
    required String deviceId,
    required String peerId,
    required MeshNode node,
    required List<int> bytes,
  }) {
    if (bytes.isEmpty) return;
    _notePeerActivity(deviceId);
    final notificationKey = bytes.join(',');
    if (_lastTxNotificationKeys[deviceId] == notificationKey) return;
    _lastTxNotificationKeys[deviceId] = notificationKey;

    final type = bytes[0] & 0xff;
    _log(
      'TX notification: ${bytes.length} bytes, type 0x${type.toRadixString(16).padLeft(2, '0')}.',
    );
    switch (classifyTxNotification(bytes)) {
      case TxNotificationType.empty:
        return;
      case TxNotificationType.keepalive:
        // Keepalive echo — reset missed counter.
        _keepaliveMissed[peerId] = 0;
      case TxNotificationType.meshPacket:
        _onMeshPacket(deviceId, Uint8List.fromList(bytes));
      case TxNotificationType.handshakeResponse:
        // Handshake response (msg2 from responder): process as initiator.
        final step = bytes[1] & 0xff;
        final data = Uint8List.fromList(bytes.sublist(2));
        _log('Received secure handshake response.');
        _onHandshakeResponse(deviceId: deviceId, step: step, data: data);
      case TxNotificationType.unknown:
        return;
    }
  }

  /// Single dispatcher for every mesh packet, regardless of whether it
  /// arrived via an RX-write (we're Peripheral on that link) or a TX-notify
  /// (we're Central) — both directions must be handled identically for
  /// relaying to work no matter which role this device has on a given link.
  void _onMeshPacket(String deviceId, Uint8List bytes) {
    if (bytes.isEmpty) return;
    _notePeerActivity(deviceId);
    meshLog(
      '_onMeshPacket from=$deviceId type=0x${bytes[0].toRadixString(16)} '
      'len=${bytes.length}',
    );
    final payload = bytes.sublist(1);
    switch (bytes[0] & 0xff) {
      case 0x01:
        _handleChunkPacket(deviceId, payload);
      case 0xFF:
        _handleAckPacket(payload);
      case 0x02:
        _handleRoutedHandshakePacket(payload);
      case 0x03:
        _handleAnnouncePacket(payload);
    }
  }

  void _handleChunkPacket(String deviceId, Uint8List payload) {
    try {
      final chunk = FileChunk.fromBytes(payload);
      meshLog(
        '_handleChunkPacket from=$deviceId dedupKey=${chunk.dedupKey} '
        'dup=${_dedupCache.contains(chunk.dedupKey)}',
      );

      // Deduplication — drop if this node has already seen this chunk.
      if (_dedupCache.contains(chunk.dedupKey)) return;
      _dedupCache.put(chunk.dedupKey);

      // Emit to local listeners (transfer manager / message store) — they
      // silently drop it if there's no matching session (i.e. it's not
      // addressed to us and we're just relaying it through).
      _chunkController.add(chunk);

      // Relay onward to every other neighbor if TTL allows.
      if (chunk.ttl > 0) {
        final chunkBytes = chunk.decrementTtl().toBytes();
        final packet = Uint8List(1 + chunkBytes.length);
        packet[0] = 0x01;
        packet.setAll(1, chunkBytes);
        unawaited(_floodSend(packet, excludeDeviceId: deviceId));
      }
    } catch (_) {
      // Malformed packet — silently drop.
    }
  }

  Future<void> _handleAckPacket(Uint8List payload) async {
    final parsed = parseAckPacket(payload);
    if (parsed == null) return;
    final (:ttl, :destPeerId, :srcPeerId, :fileId, :chunkIndex) = parsed;

    final dedupKey = 'ack:$srcPeerId:$fileId:$chunkIndex';
    if (_dedupCache.contains(dedupKey)) return;
    _dedupCache.put(dedupKey);

    final myPeerId = (await _keys.localPeerId()).substring(0, 16);
    if (destPeerId == myPeerId) {
      _ackController.add((
        peerId: srcPeerId,
        fileId: fileId,
        chunkIndex: chunkIndex,
      ));
      return;
    }

    if (ttl > 0) {
      final relayed = buildAckPacket(
        ttl: ttl - 1,
        destPeerId: destPeerId,
        srcPeerId: srcPeerId,
        fileId: fileId,
        chunkIndex: chunkIndex,
      );
      unawaited(_floodSend(relayed));
    }
  }

  // ── Noise_XX handshake (Central / initiator side, direct neighbor) ────────

  // Pending initiator handshakes: deviceId → NoiseInitiator
  final Map<String, NoiseInitiator> _pendingInitiators = {};

  Future<void> _performHandshakeAsInitiator({
    required String deviceId,
    required String peerId,
    required BluetoothCharacteristic rxChar,
  }) async {
    final keyPair = await _keys.getOrCreateStaticKeyPair();
    final initiator = await NoiseInitiator.create(keyPair);
    _pendingInitiators[deviceId] = initiator;

    final msg1 = await initiator.writeMessage1();
    // Send msg1 with handshake type prefix: [0xFE, step=1, ...bytes]
    final packet = Uint8List(2 + msg1.length);
    packet[0] = 0xFE;
    packet[1] = 1;
    packet.setAll(2, msg1);
    await rxChar.write(packet, withoutResponse: false);
    _log('Secure handshake request sent.');
    unawaited(_failHandshakeIfNoResponse(deviceId));
    // msg2 arrives via TX notification → _onHandshakeResponse
  }

  Future<void> _failHandshakeIfNoResponse(String deviceId) async {
    await Future<void>.delayed(const Duration(seconds: 8));
    if (!_pendingInitiators.containsKey(deviceId)) return;

    _pendingInitiators.remove(deviceId);
    _log('Secure handshake response timed out.');
    _peers.removeWhere((_, node) => node.deviceId == deviceId);
    await _connections[deviceId]?.disconnect();
  }

  void _onHandshakeResponse({
    required String deviceId,
    required int step,
    required Uint8List data,
  }) async {
    if (step != 2) return;
    final initiator = _pendingInitiators.remove(deviceId);
    if (initiator == null) return;

    try {
      _log('Finishing secure handshake...');
      final msg3 = await initiator.readMsg2WriteMsg3(data);
      final result = initiator.result;

      // Send msg3 via RX char.
      final rx = _rxChars[deviceId];
      if (rx != null) {
        final packet = Uint8List(2 + msg3.length);
        packet[0] = 0xFE;
        packet[1] = 3;
        packet.setAll(2, msg3);
        await rx.write(packet, withoutResponse: false);
      }

      // Find peer and store session keys.
      final peer = _peers.values
          .where((n) => n.deviceId == deviceId)
          .firstOrNull;
      meshLog(
        'initiator handshake done: deviceId=$deviceId '
        'peerFound=${peer != null} key=${peer?.shortId}',
      );
      if (peer != null) {
        _keys.storeSession(peer.shortId, result.sendKey, result.receiveKey);
        _keys.storePeerStaticKey(peer.shortId, result.remoteStaticPublicKey);
        await _contacts?.saveHandshakePeer(
          peerId: peer.shortId,
          deviceName: peer.displayName,
        );
        _log(
          '${peer.displayName ?? 'Peer ${peer.shortId.substring(0, 8)}'} is ready.',
        );
        _peerController.add(peer);
        _startKeepalive(bytesToHex(peer.identity), deviceId);
      }
    } catch (e, st) {
      developer.log(
        'Secure handshake failed for $deviceId',
        name: 'MeshShare.BLE',
        error: e,
        stackTrace: st,
      );
      // Handshake failed — disconnect peer.
      _log('Secure handshake failed.');
      _peers.removeWhere((_, node) => node.deviceId == deviceId);
      _connections[deviceId]?.disconnect();
      if (_running && _connections.isEmpty) {
        _startScanCycle();
      }
    }
  }

  // ── Noise_XX handshake (Peripheral / responder side, direct neighbor) ─────

  // Pending responder handshakes: deviceId → NoiseResponder
  final Map<String, NoiseResponder> _pendingResponders = {};

  Future<void> _onIncomingHandshakeMessage(HandshakeEvent event) async {
    final deviceId = event.deviceId;
    _notePeerActivity(deviceId);
    meshLog('rx handshake step=${event.step} from=$deviceId');
    if (event.step == 1) {
      // Msg1 received — create responder and send msg2 back.
      _log('Nearby peer requested a secure handshake...');
      final keyPair = await _keys.getOrCreateStaticKeyPair();
      final responder = await NoiseResponder.create(keyPair);
      _pendingResponders[deviceId] = responder;
      try {
        final msg2 = await responder.readMsg1WriteMsg2(event.data);
        await _channel.sendHandshakeMessage(
          deviceId: deviceId,
          step: 2,
          data: msg2,
        );
        _log('Handshake response sent.');
      } catch (_) {
        _log('Could not respond to handshake.');
        _pendingResponders.remove(deviceId);
      }
    } else if (event.step == 3) {
      // Msg3 received — finalise handshake and store keys.
      final responder = _pendingResponders.remove(deviceId);
      if (responder == null) return;
      try {
        await responder.readMessage3(event.data);
        final result = responder.result;
        // Match MeshNode.shortId: first 8 bytes of the 32-byte identity
        // represented as 16 hex characters.
        final peerId = await _keys.identityFor(result.remoteStaticPublicKey);
        final shortPeerId = peerId.substring(0, 16);
        _keys.storeSession(shortPeerId, result.sendKey, result.receiveKey);
        _keys.storePeerStaticKey(shortPeerId, result.remoteStaticPublicKey);
        final node = MeshNode(
          identity: hexToBytes(peerId),
          deviceId: deviceId,
          rssi: 0,
          lastSeenMs: DateTime.now().millisecondsSinceEpoch,
        );
        _peers[peerId] = node;
        meshLog(
          'responder handshake done: session stored key=$shortPeerId '
          'deviceId=$deviceId',
        );
        await _contacts?.saveHandshakePeer(peerId: shortPeerId);
        _log('Secure session ready with peer ${shortPeerId.substring(0, 8)}.');
        // Surface the peer on THIS device too. The Central/initiator side
        // emits it from _onHandshakeResponse; the Peripheral/responder side
        // finishes the exact same handshake but, without this line, never
        // tells its own UI — so the peer shows "Offline" on one phone while
        // showing online on the other. This is the asymmetric-discovery bug.
        _peerController.add(node);
      } catch (_) {
        // Handshake failed — ignore (Central will disconnect).
        _log('Secure handshake failed.');
      }
    }
  }

  // ── Routed Noise_XX handshake (multi-hop, flooded) ─────────────────────────

  // Pending routed handshakes, keyed by the remote peer's shortId.
  final Map<String, NoiseInitiator> _pendingRoutedInitiators = {};
  final Map<String, NoiseResponder> _pendingRoutedResponders = {};
  final Map<String, Timer> _routedHandshakeTimers = {};
  final Map<String, Completer<bool>> _routedHandshakeCompleters = {};

  /// Establish an end-to-end Noise session with [targetPeerId] (a
  /// [MeshNode.shortId]), even if it's not a direct neighbor — the handshake
  /// messages are flooded through the mesh like any other packet.
  ///
  /// Returns true once a session is ready (also delivered through
  /// [discoveredPeers]), or false if no response arrives within
  /// [kRoutedHandshakeTimeoutMs].
  Future<bool> requestSecureSession(String targetPeerId) async {
    if (_keys.hasSession(targetPeerId)) return true;

    final myPeerId = (await _keys.localPeerId()).substring(0, 16);
    final keyPair = await _keys.getOrCreateStaticKeyPair();
    final initiator = await NoiseInitiator.create(keyPair);
    _pendingRoutedInitiators[targetPeerId] = initiator;

    final msg1 = await initiator.writeMessage1();
    final packet = buildRoutedHandshakePacket(
      ttl: kDefaultTtl,
      step: 1,
      srcPeerId: myPeerId,
      dstPeerId: targetPeerId,
      nonce: _randomNonce(),
      msg: msg1,
    );
    _log('Requesting a secure session over the mesh...');
    await _floodSend(packet);

    final completer = Completer<bool>();
    _routedHandshakeCompleters[targetPeerId] = completer;
    _routedHandshakeTimers[targetPeerId]?.cancel();
    _routedHandshakeTimers[targetPeerId] = Timer(
      const Duration(milliseconds: kRoutedHandshakeTimeoutMs),
      () {
        if (_pendingRoutedInitiators.remove(targetPeerId) != null) {
          _log('Secure session request timed out — peer may be out of range.');
        }
        _routedHandshakeCompleters.remove(targetPeerId)?.complete(false);
      },
    );
    return completer.future;
  }

  Future<void> _handleRoutedHandshakePacket(Uint8List payload) async {
    final parsed = parseRoutedHandshakePacket(payload);
    if (parsed == null) return;
    final (:ttl, :step, :srcPeerId, :dstPeerId, :nonce, :msg) = parsed;

    final dedupKey = 'hs:$srcPeerId:$dstPeerId:$step:$nonce';
    if (_dedupCache.contains(dedupKey)) return;
    _dedupCache.put(dedupKey);

    final myPeerId = (await _keys.localPeerId()).substring(0, 16);
    if (dstPeerId != myPeerId) {
      if (ttl > 0) {
        final relayed = buildRoutedHandshakePacket(
          ttl: ttl - 1,
          step: step,
          srcPeerId: srcPeerId,
          dstPeerId: dstPeerId,
          nonce: nonce,
          msg: msg,
        );
        unawaited(_floodSend(relayed));
      }
      return;
    }

    switch (step) {
      case 1:
        await _onRoutedHandshakeStep1(fromPeerId: srcPeerId, msg1: msg);
      case 2:
        await _onRoutedHandshakeStep2(fromPeerId: srcPeerId, msg2: msg);
      case 3:
        await _onRoutedHandshakeStep3(fromPeerId: srcPeerId, msg3: msg);
    }
  }

  Future<void> _onRoutedHandshakeStep1({
    required String fromPeerId,
    required Uint8List msg1,
  }) async {
    try {
      final myPeerId = (await _keys.localPeerId()).substring(0, 16);
      final keyPair = await _keys.getOrCreateStaticKeyPair();
      final responder = await NoiseResponder.create(keyPair);
      final msg2 = await responder.readMsg1WriteMsg2(msg1);
      _pendingRoutedResponders[fromPeerId] = responder;

      final packet = buildRoutedHandshakePacket(
        ttl: kDefaultTtl,
        step: 2,
        srcPeerId: myPeerId,
        dstPeerId: fromPeerId,
        nonce: _randomNonce(),
        msg: msg2,
      );
      _log('Responding to a mesh secure-session request...');
      await _floodSend(packet);
    } catch (_) {
      // Malformed or replayed handshake attempt — ignore.
    }
  }

  Future<void> _onRoutedHandshakeStep2({
    required String fromPeerId,
    required Uint8List msg2,
  }) async {
    final initiator = _pendingRoutedInitiators.remove(fromPeerId);
    if (initiator == null) return;

    var success = false;
    try {
      final myPeerId = (await _keys.localPeerId()).substring(0, 16);
      final msg3 = await initiator.readMsg2WriteMsg3(msg2);
      final result = initiator.result;

      final packet = buildRoutedHandshakePacket(
        ttl: kDefaultTtl,
        step: 3,
        srcPeerId: myPeerId,
        dstPeerId: fromPeerId,
        nonce: _randomNonce(),
        msg: msg3,
      );
      await _floodSend(packet);

      success = await _finishRoutedSession(peerId: fromPeerId, result: result);
    } catch (_) {
      _log('Secure session over the mesh failed.');
    } finally {
      _routedHandshakeTimers.remove(fromPeerId)?.cancel();
      _routedHandshakeCompleters.remove(fromPeerId)?.complete(success);
    }
  }

  Future<void> _onRoutedHandshakeStep3({
    required String fromPeerId,
    required Uint8List msg3,
  }) async {
    final responder = _pendingRoutedResponders.remove(fromPeerId);
    if (responder == null) return;

    try {
      await responder.readMessage3(msg3);
      await _finishRoutedSession(peerId: fromPeerId, result: responder.result);
    } catch (_) {
      _log('Secure session over the mesh failed.');
    }
  }

  Future<bool> _finishRoutedSession({
    required String peerId,
    required HandshakeResult result,
  }) async {
    final fullIdentityHex = await _keys.identityFor(
      result.remoteStaticPublicKey,
    );
    _keys.storeSession(peerId, result.sendKey, result.receiveKey);
    _keys.storePeerStaticKey(peerId, result.remoteStaticPublicKey);
    final node = MeshNode(
      identity: hexToBytes(fullIdentityHex),
      rssi: 0,
      lastSeenMs: DateTime.now().millisecondsSinceEpoch,
    );
    _peers[fullIdentityHex] = node;
    _knownIndirectPeers.remove(peerId);
    await _contacts?.saveHandshakePeer(peerId: peerId);
    _log('Secure session ready over the mesh.');
    _peerController.add(node);
    return true;
  }

  // ── Presence gossip (multi-hop peer discovery, flooded) ────────────────────

  /// peerId → last time we heard a presence announce for it.
  final Map<String, int> _knownIndirectPeers = {};

  void _scheduleAnnounce() {
    _announceTimer?.cancel();
    _announceTimer = Timer.periodic(
      const Duration(milliseconds: kAnnounceIntervalMs),
      (_) => _broadcastPresence(),
    );
    _broadcastPresence();
  }

  void _scheduleIndirectPeerExpiry() {
    _indirectExpiryTimer?.cancel();
    _indirectExpiryTimer = Timer.periodic(
      const Duration(milliseconds: kAnnounceIntervalMs),
      (_) {
        final now = DateTime.now().millisecondsSinceEpoch;
        _knownIndirectPeers.removeWhere(
          (_, lastSeenMs) => now - lastSeenMs > kIndirectPeerExpiryMs,
        );
      },
    );
  }

  Future<void> _broadcastPresence() async {
    if (!_running) return;
    final myPeerId = (await _keys.localPeerId()).substring(0, 16);
    final nonce = _randomNonce();
    meshLog('_broadcastPresence self=$myPeerId nonce=$nonce');
    final packet = buildAnnouncePacket(
      ttl: kDefaultTtl,
      peerId: myPeerId,
      nonce: nonce,
    );
    await _floodSend(packet);
  }

  Future<void> _handleAnnouncePacket(Uint8List payload) async {
    final parsed = parseAnnouncePacket(payload);
    if (parsed == null) {
      meshLog('_handleAnnouncePacket parse FAILED len=${payload.length}');
      return;
    }
    final (:ttl, :peerId, :nonce) = parsed;

    final myPeerId = (await _keys.localPeerId()).substring(0, 16);
    if (peerId == myPeerId) {
      meshLog('announce: own echo peerId=$peerId — ignored');
      return;
    }

    final dedupKey = 'announce:$peerId:$nonce';
    final dup = _dedupCache.contains(dedupKey);
    final direct = _peers.values.any((n) => n.shortId == peerId);
    final knownIndirect = _knownIndirectPeers.containsKey(peerId);
    meshLog(
      'announce RX peerId=$peerId nonce=$nonce ttl=$ttl dup=$dup '
      'direct=$direct knownIndirect=$knownIndirect',
    );
    if (dup) return;
    _dedupCache.put(dedupKey);

    final alreadyKnown = direct || knownIndirect;
    _knownIndirectPeers[peerId] = DateTime.now().millisecondsSinceEpoch;
    if (!alreadyKnown) {
      meshLog('announce -> emitting INDIRECT peer $peerId');
      _indirectPeerController.add(
        MeshNode(
          identity: _placeholderIdentity(peerId),
          rssi: 0,
          lastSeenMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    }

    if (ttl > 0) {
      final relayed = buildAnnouncePacket(
        ttl: ttl - 1,
        peerId: peerId,
        nonce: nonce,
      );
      unawaited(_floodSend(relayed));
    }
  }

  /// A 32-byte placeholder identity whose first 8 bytes match [shortId] —
  /// used only for gossip-only [MeshNode]s (before a real session reveals
  /// the peer's actual static public key). Never used for anything besides
  /// `.shortId` display/lookup.
  Uint8List _placeholderIdentity(String shortId) {
    final identity = Uint8List(32);
    identity.setRange(0, 8, hexToBytes(shortId));
    return identity;
  }

  int _randomNonce() => Random().nextInt(0xFFFFFFFF);

  // ── Helpers ───────────────────────────────────────────────────────────────

  void _log(String message) {
    if (!_discoveryLogController.isClosed) {
      _discoveryLogController.add(message);
    }
  }

  /// Returns a snapshot of currently connected peers.
  List<MeshNode> get connectedPeers => List.unmodifiable(_peers.values);

  /// Whether [peerShortId] currently has a live direct GATT link — used by
  /// the transfer layer to decide whether to keep pushing chunks or park the
  /// transfer until the peer reconnects.
  bool isPeerOnline(String peerShortId) =>
      _peers.values.any((n) => n.shortId == peerShortId && n.deviceId != null);
}
