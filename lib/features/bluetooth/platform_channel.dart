import 'dart:async';

import 'package:flutter/services.dart';

// ── Typed events from Android → Dart ──────────────────────────────────────

sealed class MeshEvent {}

/// A generic mesh packet was written to our GATT RX characteristic — the
/// leading type byte (chunk 0x01, ack 0xFF, routed handshake 0x02, presence
/// announce 0x03, ...) is included in [data] so [BleMeshService] can dispatch
/// on it without needing native-side classification for every new type.
class MeshPacketEvent extends MeshEvent {
  final String deviceId;
  final Uint8List data;
  MeshPacketEvent(this.deviceId, this.data);
}

/// A Noise_XX handshake message arrived on our GATT RX characteristic.
class HandshakeEvent extends MeshEvent {
  final String deviceId;
  final int step; // 1 or 3
  final Uint8List data;
  HandshakeEvent(this.deviceId, this.step, this.data);
}

/// A Central connected to or disconnected from our GATT server — i.e. the
/// link on which this device is the Peripheral. The disconnect signal lets
/// [BleMeshService] tear down peer state for a peer that handshaked against
/// our server; the Central-side `connectionState` stream never sees that
/// link, so without this the peer stays "online" until the app restarts.
class PeripheralLinkEvent extends MeshEvent {
  final String deviceId;
  final bool connected;
  PeripheralLinkEvent(this.deviceId, this.connected);
}

// ── Channel ────────────────────────────────────────────────────────────────

/// Dart-side bridge to the native Android [MeshSharePlugin].
///
/// All events from Android arrive through a single [EventChannel] as typed
/// [MeshEvent] objects. Commands to Android go through [MethodChannel] calls.
class MeshPlatformChannel {
  static const MethodChannel _method = MethodChannel(
    'com.meshshare/mesh_service',
  );

  static const EventChannel _event = EventChannel(
    'com.meshshare/incoming_chunks',
  );

  // Decoded typed event stream (broadcast so multiple listeners are fine).
  late final Stream<MeshEvent> _events = _event
      .receiveBroadcastStream()
      .map(_decode)
      .where((e) => e != null)
      .cast<MeshEvent>()
      .asBroadcastStream();

  Stream<MeshEvent> get events => _events;

  // Convenience filtered views.
  Stream<MeshPacketEvent> get incomingPackets =>
      _events.where((e) => e is MeshPacketEvent).cast<MeshPacketEvent>();

  Stream<HandshakeEvent> get incomingHandshakeMessages =>
      _events.where((e) => e is HandshakeEvent).cast<HandshakeEvent>();

  Stream<PeripheralLinkEvent> get peripheralLinkEvents =>
      _events.where((e) => e is PeripheralLinkEvent).cast<PeripheralLinkEvent>();

  // ── Foreground service ──────────────────────────────────────────────────

  Future<void> startForegroundService() =>
      _method.invokeMethod('startForegroundService');

  Future<void> stopForegroundService() =>
      _method.invokeMethod('stopForegroundService');

  // ── GATT server ─────────────────────────────────────────────────────────

  Future<void> startGattServer() => _method.invokeMethod('startGattServer');

  Future<void> stopGattServer() => _method.invokeMethod('stopGattServer');

  // ── Advertising ─────────────────────────────────────────────────────────

  Future<void> refreshAdvertising(Uint8List localIdentity) =>
      _method.invokeMethod('refreshAdvertising', {'identity': localIdentity});

  // ── Chunk sending (Central → Peripheral) ────────────────────────────────

  // Direct GATT writes are sent via flutter_blue_plus in BleMeshService.
  // No method channel call needed for that direction.

  // ── Generic notification (Peripheral → connected Central) ───────────────

  /// Notify a connected Central with an arbitrary mesh packet ([data]
  /// includes the leading type byte).
  ///
  /// This is how a device relays or originates traffic (chunks, ACKs, routed
  /// handshake envelopes, presence announces) over a link where it is the
  /// Peripheral side — the only outbound mechanism available on that side of
  /// a GATT connection is a characteristic notification.
  Future<void> sendRawNotification({
    required String deviceId,
    required Uint8List data,
  }) => _method.invokeMethod('sendRawNotification', {
    'deviceId': deviceId,
    'data': data,
  });

  // ── Handshake messaging (Peripheral → Central notification) ─────────────

  /// Send a Noise_XX handshake message (msg2) from Peripheral to Central.
  ///
  /// Called by the responder (Peripheral / GATT server) after processing msg1.
  Future<void> sendHandshakeMessage({
    required String deviceId,
    required int step,
    required Uint8List data,
  }) => _method.invokeMethod('sendHandshakeMessage', {
    'deviceId': deviceId,
    'step': step,
    'data': data,
  });

  // ── Event decoding ───────────────────────────────────────────────────────

  static MeshEvent? _decode(dynamic raw) {
    if (raw is! Map) return null;
    final map = Map<String, dynamic>.from(raw);
    final type = map['type'] as String?;

    switch (type) {
      case 'packet':
        return MeshPacketEvent(
          map['deviceId'] as String,
          Uint8List.fromList(List<int>.from(map['data'] as List)),
        );

      case 'handshake':
        return HandshakeEvent(
          map['deviceId'] as String,
          map['step'] as int,
          Uint8List.fromList(List<int>.from(map['data'] as List)),
        );

      case 'peripheralLink':
        return PeripheralLinkEvent(
          map['deviceId'] as String,
          map['connected'] as bool,
        );

      default:
        return null;
    }
  }
}
