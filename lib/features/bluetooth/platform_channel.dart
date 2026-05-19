import 'dart:async';

import 'package:flutter/services.dart';

// ── Typed events from Android → Dart ──────────────────────────────────────

sealed class MeshEvent {}

/// A raw file/message chunk was written to our GATT RX characteristic.
class ChunkEvent extends MeshEvent {
  final String deviceId;
  final Uint8List data;
  ChunkEvent(this.deviceId, this.data);
}

/// A Noise_XX handshake message arrived on our GATT RX characteristic.
class HandshakeEvent extends MeshEvent {
  final String deviceId;
  final int step; // 1 or 3
  final Uint8List data;
  HandshakeEvent(this.deviceId, this.step, this.data);
}

/// An ACK notification arrived on our TX characteristic (as Central).
class AckEvent extends MeshEvent {
  final String deviceId;
  final String fileId;
  final int chunkIndex;
  AckEvent(this.deviceId, this.fileId, this.chunkIndex);
}

/// A handshake response (msg2) arrived via TX characteristic notification.
class HandshakeResponseEvent extends MeshEvent {
  final String deviceId;
  final int step; // 2
  final Uint8List data;
  HandshakeResponseEvent(this.deviceId, this.step, this.data);
}

// ── Channel ────────────────────────────────────────────────────────────────

/// Dart-side bridge to the native Android [MeshSharePlugin].
///
/// All events from Android arrive through a single [EventChannel] as typed
/// [MeshEvent] objects. Commands to Android go through [MethodChannel] calls.
class MeshPlatformChannel {
  static const MethodChannel _method =
      MethodChannel('com.meshshare/mesh_service');

  static const EventChannel _event =
      EventChannel('com.meshshare/incoming_chunks');

  // Decoded typed event stream (broadcast so multiple listeners are fine).
  late final Stream<MeshEvent> _events = _event
      .receiveBroadcastStream()
      .map(_decode)
      .where((e) => e != null)
      .cast<MeshEvent>()
      .asBroadcastStream();

  Stream<MeshEvent> get events => _events;

  // Convenience filtered views.
  Stream<ChunkEvent> get incomingChunks =>
      _events.where((e) => e is ChunkEvent).cast<ChunkEvent>();

  Stream<HandshakeEvent> get incomingHandshakeMessages =>
      _events.where((e) => e is HandshakeEvent).cast<HandshakeEvent>();

  Stream<AckEvent> get incomingAcks =>
      _events.where((e) => e is AckEvent).cast<AckEvent>();

  Stream<HandshakeResponseEvent> get handshakeResponses =>
      _events.where((e) => e is HandshakeResponseEvent).cast<HandshakeResponseEvent>();

  // ── Foreground service ──────────────────────────────────────────────────

  Future<void> startForegroundService() =>
      _method.invokeMethod('startForegroundService');

  Future<void> stopForegroundService() =>
      _method.invokeMethod('stopForegroundService');

  // ── GATT server ─────────────────────────────────────────────────────────

  Future<void> startGattServer() =>
      _method.invokeMethod('startGattServer');

  Future<void> stopGattServer() =>
      _method.invokeMethod('stopGattServer');

  // ── Advertising ─────────────────────────────────────────────────────────

  Future<void> refreshAdvertising(Uint8List localIdentity) =>
      _method.invokeMethod('refreshAdvertising', {'identity': localIdentity});

  // ── Chunk sending (Central → Peripheral) ────────────────────────────────

  // Chunks are sent directly via flutter_blue_plus in BleMeshService.
  // No method channel call needed.

  // ── ACK sending (Peripheral → Central notification) ─────────────────────

  /// Notify a connected Central that we received their chunk.
  ///
  /// Called by the receiver side (Peripheral / GATT server) after successfully
  /// decrypting and storing a chunk. The Central's TX-characteristic listener
  /// picks this up and marks the chunk as ACKed.
  Future<void> sendAckToDevice({
    required String deviceId,
    required String fileId,
    required int chunkIndex,
  }) =>
      _method.invokeMethod('sendAck', {
        'deviceId': deviceId,
        'fileId': fileId,
        'chunkIndex': chunkIndex,
      });

  // ── Handshake messaging (Peripheral → Central notification) ─────────────

  /// Send a Noise_XX handshake message (msg2) from Peripheral to Central.
  ///
  /// Called by the responder (Peripheral / GATT server) after processing msg1.
  Future<void> sendHandshakeMessage({
    required String deviceId,
    required int step,
    required Uint8List data,
  }) =>
      _method.invokeMethod('sendHandshakeMessage', {
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
      case 'chunk':
        return ChunkEvent(
          map['deviceId'] as String,
          Uint8List.fromList(List<int>.from(map['data'] as List)),
        );

      case 'handshake':
        return HandshakeEvent(
          map['deviceId'] as String,
          map['step'] as int,
          Uint8List.fromList(List<int>.from(map['data'] as List)),
        );

      case 'ack':
        return AckEvent(
          map['deviceId'] as String,
          map['fileId'] as String,
          map['chunkIndex'] as int,
        );

      case 'handshakeResponse':
        return HandshakeResponseEvent(
          map['deviceId'] as String,
          map['step'] as int,
          Uint8List.fromList(List<int>.from(map['data'] as List)),
        );

      default:
        return null;
    }
  }
}
