// Wire-format tests for the flooded mesh packet types added for multi-hop
// relay (routed handshake, ACK, presence announce). These don't touch BLE at
// all — they only prove the byte layout is self-consistent: whatever a
// build* function produces, the matching parse* function must read back
// exactly. This is the one part of the new relay code that can be verified
// without real hardware.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshshare/features/bluetooth/ble_mesh_service.dart';

const _peerA = 'aaaaaaaaaaaaaaaa'; // 16 hex chars = 8 bytes
const _peerB = 'bbbbbbbbbbbbbbbb';

void main() {
  group('ACK packet', () {
    test('round-trips all fields', () {
      final packet = buildAckPacket(
        ttl: 5,
        destPeerId: _peerA,
        srcPeerId: _peerB,
        fileId: 'f' * 36,
        chunkIndex: 42,
      );

      // Type byte (0xFF) is stripped by the dispatcher before parsing.
      final parsed = parseAckPacket(packet.sublist(1));

      expect(parsed, isNotNull);
      expect(parsed!.ttl, equals(5));
      expect(parsed.destPeerId, equals(_peerA));
      expect(parsed.srcPeerId, equals(_peerB));
      expect(parsed.fileId, equals('f' * 36));
      expect(parsed.chunkIndex, equals(42));
    });

    test('leading byte is the ACK type marker 0xFF', () {
      final packet = buildAckPacket(
        ttl: 7,
        destPeerId: _peerA,
        srcPeerId: _peerB,
        fileId: 'f' * 36,
        chunkIndex: 0,
      );
      expect(packet[0], equals(0xFF));
    });

    test('rejects a payload shorter than a valid ACK', () {
      expect(parseAckPacket(Uint8List(10)), isNull);
    });

    test('chunkIndex above 16 bits still round-trips (uses a 4-byte field)', () {
      final packet = buildAckPacket(
        ttl: 1,
        destPeerId: _peerA,
        srcPeerId: _peerB,
        fileId: 'f' * 36,
        chunkIndex: 100000,
      );
      final parsed = parseAckPacket(packet.sublist(1));
      expect(parsed!.chunkIndex, equals(100000));
    });
  });

  group('Routed handshake packet', () {
    test('round-trips all fields including a multi-byte Noise message', () {
      final msg = Uint8List.fromList(List.generate(80, (i) => i % 256));
      final packet = buildRoutedHandshakePacket(
        ttl: 6,
        step: 2,
        srcPeerId: _peerA,
        dstPeerId: _peerB,
        nonce: 123456789,
        msg: msg,
      );

      final parsed = parseRoutedHandshakePacket(packet.sublist(1));

      expect(parsed, isNotNull);
      expect(parsed!.ttl, equals(6));
      expect(parsed.step, equals(2));
      expect(parsed.srcPeerId, equals(_peerA));
      expect(parsed.dstPeerId, equals(_peerB));
      expect(parsed.nonce, equals(123456789));
      expect(parsed.msg, equals(msg));
    });

    test('leading byte is the routed-handshake type marker 0x02', () {
      final packet = buildRoutedHandshakePacket(
        ttl: 7,
        step: 1,
        srcPeerId: _peerA,
        dstPeerId: _peerB,
        nonce: 1,
        msg: Uint8List(32),
      );
      expect(packet[0], equals(0x02));
    });

    test('handles an empty Noise message without corrupting length', () {
      final packet = buildRoutedHandshakePacket(
        ttl: 7,
        step: 3,
        srcPeerId: _peerA,
        dstPeerId: _peerB,
        nonce: 1,
        msg: Uint8List(0),
      );
      final parsed = parseRoutedHandshakePacket(packet.sublist(1));
      expect(parsed!.msg, isEmpty);
    });

    test('rejects a truncated payload (msgLen says more than is present)', () {
      expect(parseRoutedHandshakePacket(Uint8List(20)), isNull);
    });
  });

  group('Presence announce packet', () {
    test('round-trips all fields', () {
      final packet = buildAnnouncePacket(ttl: 4, peerId: _peerA, nonce: 999);
      final parsed = parseAnnouncePacket(packet.sublist(1));

      expect(parsed, isNotNull);
      expect(parsed!.ttl, equals(4));
      expect(parsed.peerId, equals(_peerA));
      expect(parsed.nonce, equals(999));
    });

    test('leading byte is the announce type marker 0x03', () {
      final packet = buildAnnouncePacket(ttl: 7, peerId: _peerA, nonce: 1);
      expect(packet[0], equals(0x03));
    });

    test('rejects a payload shorter than a valid announce', () {
      expect(parseAnnouncePacket(Uint8List(5)), isNull);
    });
  });

  group('Cross-packet-type safety', () {
    test('the three packet types have distinct leading type bytes', () {
      final ack = buildAckPacket(
        ttl: 1,
        destPeerId: _peerA,
        srcPeerId: _peerB,
        fileId: 'f' * 36,
        chunkIndex: 0,
      );
      final handshake = buildRoutedHandshakePacket(
        ttl: 1,
        step: 1,
        srcPeerId: _peerA,
        dstPeerId: _peerB,
        nonce: 1,
        msg: Uint8List(0),
      );
      final announce = buildAnnouncePacket(ttl: 1, peerId: _peerA, nonce: 1);

      expect({ack[0], handshake[0], announce[0]}.length, equals(3));
    });

    test(
      'classifyTxNotification recognises every built packet as meshPacket',
      () {
        final ack = buildAckPacket(
          ttl: 1,
          destPeerId: _peerA,
          srcPeerId: _peerB,
          fileId: 'f' * 36,
          chunkIndex: 0,
        );
        final handshake = buildRoutedHandshakePacket(
          ttl: 1,
          step: 1,
          srcPeerId: _peerA,
          dstPeerId: _peerB,
          nonce: 1,
          msg: Uint8List(0),
        );
        final announce = buildAnnouncePacket(ttl: 1, peerId: _peerA, nonce: 1);

        for (final packet in [ack, handshake, announce]) {
          expect(
            classifyTxNotification(packet),
            TxNotificationType.meshPacket,
          );
        }
      },
    );
  });
}
