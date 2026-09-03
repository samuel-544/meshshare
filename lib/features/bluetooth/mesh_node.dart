import 'dart:typed_data';

/// Represents a discovered MeshShare peer node.
class MeshNode {
  /// Stable 32-byte identity derived from the peer's Noise static public key.
  final Uint8List identity;

  /// BLE device ID (platform-specific, may rotate — use [identity] for tracking).
  ///
  /// Null if this peer is known only via mesh gossip or a routed (multi-hop)
  /// Noise session, with no direct GATT link to this device.
  final String? deviceId;

  /// Human-readable display name (if advertised).
  final String? displayName;

  /// Signal strength at time of discovery (dBm).
  final int rssi;

  /// Timestamp of last seen (Unix ms).
  final int lastSeenMs;

  const MeshNode({
    required this.identity,
    this.deviceId,
    this.displayName,
    required this.rssi,
    required this.lastSeenMs,
  });

  /// Whether this node has a live GATT link (direct neighbor).
  bool get isDirect => deviceId != null;

  /// Whether this is one of the built-in demo peers (see `buildDemoPeers`),
  /// used on platforms with no BLE radio and on a debug emulator. Lets the
  /// send/chat flows fall back to the simulated transfer instead of a real
  /// Noise session that a demo peer never completes.
  bool get isDemo => deviceId?.startsWith('demo-') ?? false;

  /// Hex string of the first 8 bytes of identity — used as short display ID.
  String get shortId =>
      identity.take(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  @override
  String toString() => 'MeshNode($shortId, rssi=$rssi)';
}
