import 'package:flutter/material.dart';

import 'app.dart';
import 'features/auth/auth_service.dart';
import 'features/bluetooth/ble_mesh_service.dart';
import 'features/crypto/key_manager.dart';
import 'features/file_transfer/transfer_manager.dart';
import 'features/messaging/message_sender.dart';
import 'features/messaging/message_store.dart';
import 'features/peers/peer_contact_store.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final authService = AuthService();
  await authService.init();

  final keyManager = await KeyManager.instance();
  final peerContacts = PeerContactStore();
  await peerContacts.init();
  final messageStore = MessageStore();
  final bleService = BleMeshService(keys: keyManager, contacts: peerContacts);
  final transferManager = TransferManager(
    ble: bleService,
    keys: keyManager,
    messageStore: messageStore,
  );
  final localPeerId = await keyManager.localPeerId();
  final messageSender = MessageSender(
    transferManager: transferManager,
    store: messageStore,
    localPeerId: localPeerId,
  );

  runApp(
    MeshShareApp(
      authService: authService,
      keyManager: keyManager,
      bleService: bleService,
      messageStore: messageStore,
      transferManager: transferManager,
      messageSender: messageSender,
      peerContacts: peerContacts,
    ),
  );
}
