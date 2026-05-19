import 'dart:typed_data';

/// Represents a discovered MeshShare peer node.
class MeshNode {
  /// Stable 32-byte identity derived from the peer's Noise static public key.
  final Uint8List identity;

  /// BLE device ID (platform-specific, may rotate — use [identity] for tracking).
  final String deviceId;

  /// Human-readable display name (if advertised).
  final String? displayName;

  /// Signal strength at time of discovery (dBm).
  final int rssi;

  /// Timestamp of last seen (Unix ms).
  final int lastSeenMs;

  const MeshNode({
    required this.identity,
    required this.deviceId,
    this.displayName,
    required this.rssi,
    required this.lastSeenMs,
  });

  /// Hex string of the first 8 bytes of identity — used as short display ID.
  String get shortId =>
      identity.take(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  @override
  String toString() => 'MeshNode($shortId, rssi=$rssi)';
}
