import 'package:flutter_test/flutter_test.dart';
import 'package:meshshare/features/bluetooth/ble_mesh_service.dart';

void main() {
  group('BLE TX notification classification', () {
    test('recognises handshake response notifications', () {
      expect(
        classifyTxNotification([0xFE, 0x02, 0xAA, 0xBB]),
        TxNotificationType.handshakeResponse,
      );
    });

    test('recognises keepalive notifications', () {
      expect(classifyTxNotification([0x00]), TxNotificationType.keepalive);
    });

    test(
      'recognises mesh packets (chunk, ack, routed handshake, announce) '
      'regardless of arrival direction',
      () {
        // Chunk (0x01).
        expect(
          classifyTxNotification([0x01, 0x02, 0x03]),
          TxNotificationType.meshPacket,
        );
        // ACK (0xFF).
        final ack = <int>[
          0xFF,
          ...List<int>.filled(36, 0x61),
          0x00,
          0x00,
          0x00,
          0x01,
        ];
        expect(classifyTxNotification(ack), TxNotificationType.meshPacket);
        // Routed handshake (0x02).
        expect(
          classifyTxNotification([0x02, 0x07, 0x01]),
          TxNotificationType.meshPacket,
        );
        // Presence announce (0x03).
        expect(
          classifyTxNotification([0x03, 0x07]),
          TxNotificationType.meshPacket,
        );
      },
    );

    test('does not confuse a bare handshake byte or empty bytes', () {
      expect(classifyTxNotification([0xFE]), TxNotificationType.unknown);
      expect(classifyTxNotification([]), TxNotificationType.empty);
    });
  });
}
