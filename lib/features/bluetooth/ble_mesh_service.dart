import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../../core/constants.dart';
import '../../core/utils.dart';
import '../crypto/key_manager.dart';
import '../crypto/noise_handshake.dart';
import '../file_transfer/chunk_model.dart';
import 'mesh_node.dart';
import 'platform_channel.dart';

/// Central BLE Mesh service — manages discovery, connections, keepalives,
/// chunk transfer, and relay forwarding for all MeshShare peers.
///
/// Every device simultaneously acts as:
///   - **Central** (scanner + GATT client) via flutter_blue_plus
///   - **Peripheral** (advertiser + GATT server) via [MeshPlatformChannel]
///
/// Usage:
/// ```dart
/// final ble = BleMeshService();
/// await ble.start(localIdentity: myIdentityBytes);
/// ble.discoveredPeers.listen((node) { ... });
/// ble.incomingChunks.listen((chunk) { ... });
/// await ble.sendChunk(chunk, targetNode);
/// ```
class BleMeshService {
  final MeshPlatformChannel _channel;
  final KeyManager _keys;

  BleMeshService({MeshPlatformChannel? channel, required KeyManager keys})
      : _channel = channel ?? MeshPlatformChannel(),
        _keys = keys;

  // ── Identity ──────────────────────────────────────────────────────────────

  late Uint8List _localIdentity; // 32-byte Noise public key hash

  // ── Stream controllers ────────────────────────────────────────────────────

  final _peerController  = StreamController<MeshNode>.broadcast();
  final _chunkController = StreamController<FileChunk>.broadcast();
  final _ackController   = StreamController<
      ({String peerId, String fileId, int chunkIndex})>.broadcast();

  /// Emits a [MeshNode] each time a new MeshShare peer is discovered.
  Stream<MeshNode> get discoveredPeers => _peerController.stream;

  /// Emits each encrypted [FileChunk] that arrives at this device (after dedup).
  /// [TransferManager] decrypts and reassembles these.
  Stream<FileChunk> get incomingChunks => _chunkController.stream;

  /// Emits ACK records when the remote peer confirms receipt of a chunk.
  Stream<({String peerId, String fileId, int chunkIndex})> get incomingAcks =>
      _ackController.stream;

  // ── Connection state ──────────────────────────────────────────────────────

  /// deviceId → BluetoothDevice (active GATT connections).
  final Map<String, BluetoothDevice> _connections = {};

  /// peerId (hex identity) → MeshNode (known peers).
  final Map<String, MeshNode> _peers = {};

  /// deviceId → RX characteristic (we write outgoing chunks here).
  final Map<String, BluetoothCharacteristic> _rxChars = {};

  /// deviceId → TX characteristic (we subscribe for ACKs here).
  final Map<String, BluetoothCharacteristic> _txChars = {};

  // ── Keepalive ─────────────────────────────────────────────────────────────

  /// peerId → consecutive missed keepalive count.
  final Map<String, int> _keepaliveMissed = {};

  /// peerId → periodic keepalive timer.
  final Map<String, Timer> _keepaliveTimers = {};

  // ── Relay deduplication ───────────────────────────────────────────────────

  /// LRU cache of `fileId:chunkIndex` keys seen at this node.
  /// Prevents forwarding the same chunk twice (avoids relay loops).
  final LruCache<String> _dedupCache = LruCache(kDedupCacheMaxSize);

  // ── Scanning state ────────────────────────────────────────────────────────

  bool _running = false;
  DateTime? _lastNewPeerAt;
  Timer? _scanCycleTimer;
  Timer? _advertiseRefreshTimer;
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothAdapterState>? _adapterSub;

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  /// Start advertising, scanning, and the GATT server.
  ///
  /// [localIdentity] is the 32-byte SHA-256 hash of the device's Noise
  /// static public key — used as the stable peer identity.
  Future<void> start({required Uint8List localIdentity}) async {
    if (_running) return;
    _localIdentity = localIdentity;
    _running = true;

    // Start Android foreground service (keeps BLE alive with screen off).
    await _channel.startForegroundService();

    // Start GATT server on the Android side; incoming events are
    // forwarded to Dart via the typed event channel.
    await _channel.startGattServer();
    _channel.incomingChunks.listen((e) => _onRawChunkReceived(e.data));
    _channel.incomingAcks.listen((e) {
      // Find the peer identity for this deviceId.
      final peer = _peers.values
          .where((n) => n.deviceId == e.deviceId)
          .firstOrNull;
      if (peer == null) return;
      _ackController.add((
        peerId: peer.shortId,
        fileId: e.fileId,
        chunkIndex: e.chunkIndex,
      ));
    });
    // Responder side: handle incoming handshake messages from Centrals.
    _channel.incomingHandshakeMessages.listen(_onIncomingHandshakeMessage);

    // Watch adapter state — restart scanning if BT is toggled.
    _adapterSub = FlutterBluePlus.adapterState.listen((state) {
      if (state == BluetoothAdapterState.on && _running) {
        _startScanCycle();
        _scheduleAdvertiseRefresh();
      }
    });

    if (await FlutterBluePlus.adapterState.first ==
        BluetoothAdapterState.on) {
      _startScanCycle();
      _scheduleAdvertiseRefresh();
    }
  }

  /// Stop all BLE activity and release resources.
  Future<void> stop() async {
    _running = false;
    _scanCycleTimer?.cancel();
    _advertiseRefreshTimer?.cancel();
    _scanSub?.cancel();
    _adapterSub?.cancel();
    await FlutterBluePlus.stopScan();

    for (final timer in _keepaliveTimers.values) {
      timer.cancel();
    }
    _keepaliveTimers.clear();

    for (final device in _connections.values) {
      await device.disconnect();
    }
    _connections.clear();
    _rxChars.clear();
    _txChars.clear();

    await _channel.stopGattServer();
    await _channel.stopForegroundService();

    await _peerController.close();
    await _chunkController.close();
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
    await FlutterBluePlus.stopScan();
    await _scanSub?.cancel();

    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      for (final result in results) {
        _onScanResult(result);
      }
    });

    await FlutterBluePlus.startScan(
      withServices: [Guid(kServiceUuid)],
      timeout: const Duration(seconds: 4),
    );
  }

  void _onScanResult(ScanResult result) {
    final deviceId = result.device.remoteId.str;
    if (_connections.containsKey(deviceId)) return; // already connected

    _lastNewPeerAt = DateTime.now();
    _connectToDevice(result.device, result.rssi);
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

  Future<void> _connectToDevice(BluetoothDevice device, int rssi) async {
    final deviceId = device.remoteId.str;
    try {
      await device.connect(timeout: const Duration(seconds: 10));
      _connections[deviceId] = device;

      // Negotiate a larger MTU so full chunk packets fit in one write.
      // A chunk packet is ~100 bytes; request 256 to have headroom.
      await device.requestMtu(256);

      // Listen for disconnection.
      device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _onDeviceDisconnected(deviceId);
        }
      });

      final services = await device.discoverServices();
      final meshService = services.firstWhere(
        (s) => s.serviceUuid == Guid(kServiceUuid),
        orElse: () => throw Exception('MeshShare service not found on $deviceId'),
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
      await identityChar.write(_localIdentity, withoutResponse: false);
      final peerIdentityBytes = await identityChar.read();
      final peerIdentity = Uint8List.fromList(peerIdentityBytes);
      final peerId = _bytesToHex(peerIdentity);

      final node = MeshNode(
        identity: peerIdentity,
        deviceId: deviceId,
        rssi: rssi,
        lastSeenMs: DateTime.now().millisecondsSinceEpoch,
      );
      _peers[peerId] = node;
      _peerController.add(node);

      // Subscribe to TX notifications: keepalive echoes, ACKs, handshake responses.
      await txChar.setNotifyValue(true);
      txChar.lastValueStream.listen((bytes) {
        if (bytes.isEmpty) return;
        final type = bytes[0] & 0xff;
        if (type == 0x00) {
          // Keepalive echo — reset missed counter.
          _keepaliveMissed[peerId] = 0;
        } else if (type == 0xFF && bytes.length >= 41) {
          // ACK: [0xFF, fileId(36), chunkIndex(4)]
          final fileId = String.fromCharCodes(bytes.sublist(1, 37));
          final bd = ByteData.sublistView(Uint8List.fromList(bytes));
          final chunkIndex = bd.getUint32(37, Endian.big);
          _ackController.add((
            peerId: peerId,
            fileId: fileId,
            chunkIndex: chunkIndex,
          ));
        } else if (type == 0xFE && bytes.length >= 2) {
          // Handshake response (msg2 from responder): process as initiator.
          final step = bytes[1] & 0xff;
          final data = Uint8List.fromList(bytes.sublist(2));
          _onHandshakeResponse(deviceId: deviceId, step: step, data: data);
        }
      });

      // ── Noise_XX handshake (initiator side) ────────────────────────────────
      await _performHandshakeAsInitiator(
        deviceId: deviceId,
        peerId: peerId,
        rxChar: rxChar,
      );

      // Start keepalive for this peer.
      _startKeepalive(peerId, deviceId);
    } catch (e) {
      _connections.remove(deviceId);
      _rxChars.remove(deviceId);
      _txChars.remove(deviceId);
    }
  }

  void _onDeviceDisconnected(String deviceId) {
    _connections.remove(deviceId);
    _rxChars.remove(deviceId);
    _txChars.remove(deviceId);

    // Find and remove the peer entry for this device.
    _peers.removeWhere((peerId, node) {
      if (node.deviceId == deviceId) {
        _keepaliveTimers[peerId]?.cancel();
        _keepaliveTimers.remove(peerId);
        _keepaliveMissed.remove(peerId);
        return true;
      }
      return false;
    });
  }

  // ── Keepalive ─────────────────────────────────────────────────────────────

  void _startKeepalive(String peerId, String deviceId) {
    _keepaliveMissed[peerId] = 0;
    _keepaliveTimers[peerId]?.cancel();

    _keepaliveTimers[peerId] = Timer.periodic(
      const Duration(milliseconds: kKeepaliveIntervalMs),
      (_) async {
        final rx = _rxChars[deviceId];
        if (rx == null) return;

        try {
          await rx.write([0x00], withoutResponse: true);
          _keepaliveMissed[peerId] = (_keepaliveMissed[peerId] ?? 0) + 1;

          if ((_keepaliveMissed[peerId] ?? 0) >= kKeepaliveMaxMissed) {
            // Peer has gone silent — disconnect.
            _connections[deviceId]?.disconnect();
          }
        } catch (_) {
          _onDeviceDisconnected(deviceId);
        }
      },
    );
  }

  // ── Sending ───────────────────────────────────────────────────────────────

  /// Write a single encrypted [chunk] to [target]'s RX characteristic.
  ///
  /// Prepends type byte `0x01` so the receiver can distinguish chunks from
  /// handshake messages and ACKs.
  Future<void> sendChunk(FileChunk chunk, MeshNode target) async {
    final rx = _rxChars[target.deviceId];
    if (rx == null) {
      throw StateError('No active connection to ${target.shortId}');
    }
    final chunkBytes = chunk.toBytes();
    final packet = Uint8List(1 + chunkBytes.length);
    packet[0] = 0x01; // type: chunk
    packet.setAll(1, chunkBytes);
    await rx.write(packet, withoutResponse: true);
  }

  /// Send an ACK for [chunkIndex] of transfer [fileId] back to [target].
  ///
  /// ACKs flow from Peripheral (receiver) back to Central (sender).
  /// If [target] is null (peer not found), the ACK is silently dropped.
  Future<void> sendAck({
    required String fileId,
    required int chunkIndex,
    required MeshNode? target,
  }) async {
    if (target == null) return;
    await _channel.sendAckToDevice(
      deviceId: target.deviceId,
      fileId: fileId,
      chunkIndex: chunkIndex,
    );
  }

  // ── Receiving ─────────────────────────────────────────────────────────────

  // ── Noise_XX handshake (Central / initiator side) ─────────────────────────

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
    // msg2 arrives via TX notification → _onHandshakeResponse
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
      final peer = _peers.values.where((n) => n.deviceId == deviceId).firstOrNull;
      if (peer != null) {
        _keys.storeSession(peer.shortId, result.sendKey, result.receiveKey);
      }
    } catch (_) {
      // Handshake failed — disconnect peer.
      _connections[deviceId]?.disconnect();
    }
  }

  // ── Noise_XX handshake (Peripheral / responder side) ──────────────────────

  // Pending responder handshakes: deviceId → NoiseResponder
  final Map<String, NoiseResponder> _pendingResponders = {};

  Future<void> _onIncomingHandshakeMessage(HandshakeEvent event) async {
    final deviceId = event.deviceId;
    if (event.step == 1) {
      // Msg1 received — create responder and send msg2 back.
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
      } catch (_) {
        _pendingResponders.remove(deviceId);
      }
    } else if (event.step == 3) {
      // Msg3 received — finalise handshake and store keys.
      final responder = _pendingResponders.remove(deviceId);
      if (responder == null) return;
      try {
        await responder.readMessage3(event.data);
        final result = responder.result;
        // Derive a stable shortId for the initiator from their static key.
        final peerId = await _keys.identityFor(result.remoteStaticPublicKey);
        _keys.storeSession(peerId.substring(0, 8), result.sendKey, result.receiveKey);
      } catch (_) {
        // Handshake failed — ignore (Central will disconnect).
      }
    }
  }

  // ── Receiving ─────────────────────────────────────────────────────────────

  /// Called by the platform channel when the Android GATT server receives
  /// raw bytes on the RX characteristic from a remote Central.
  void _onRawChunkReceived(Uint8List bytes) {
    try {
      final chunk = FileChunk.fromBytes(bytes);

      // Deduplication — drop if this node has already seen this chunk.
      if (_dedupCache.contains(chunk.dedupKey)) return;
      _dedupCache.put(chunk.dedupKey);

      // Emit to local listeners (transfer manager / message store).
      _chunkController.add(chunk);

      // Relay: forward to all other connected peers if TTL allows.
      if (chunk.ttl > 0) {
        _relayChunk(chunk.decrementTtl());
      }
    } catch (_) {
      // Malformed packet — silently drop.
    }
  }

  Future<void> _relayChunk(FileChunk chunk) async {
    for (final entry in _peers.entries) {
      final peer = entry.value;
      final rx = _rxChars[peer.deviceId];
      if (rx == null) continue;
      try {
        await rx.write(chunk.toBytes(), withoutResponse: true);
      } catch (_) {
        // Best-effort relay — ignore per-peer failures.
      }
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  String _bytesToHex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// Returns a snapshot of currently connected peers.
  List<MeshNode> get connectedPeers => List.unmodifiable(_peers.values);
}
