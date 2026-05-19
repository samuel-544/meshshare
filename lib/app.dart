import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'features/auth/auth_service.dart';
import 'features/bluetooth/ble_mesh_service.dart';
import 'features/crypto/key_manager.dart';
import 'features/file_transfer/transfer_manager.dart';
import 'features/messaging/message_sender.dart';
import 'features/messaging/message_store.dart';
import 'features/ui/home_screen.dart';
import 'features/ui/setup_pin_screen.dart'; // exports both SetupPinScreen and LockScreen

class MeshShareApp extends StatelessWidget {
  final AuthService authService;
  final KeyManager keyManager;
  final BleMeshService bleService;
  final MessageStore messageStore;
  final TransferManager transferManager;
  final MessageSender messageSender;

  const MeshShareApp({
    super.key,
    required this.authService,
    required this.keyManager,
    required this.bleService,
    required this.messageStore,
    required this.transferManager,
    required this.messageSender,
  });

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthService>.value(value: authService),
        Provider<KeyManager>.value(value: keyManager),
        Provider<BleMeshService>.value(value: bleService),
        ChangeNotifierProvider<MessageStore>.value(value: messageStore),
        Provider<TransferManager>.value(value: transferManager),
        Provider<MessageSender>.value(value: messageSender),
      ],
      child: MaterialApp(
        title: 'MeshShare',
        theme: ThemeData(
          colorSchemeSeed: Colors.blue,
          useMaterial3: true,
        ),
        home: const _AppRoot(),
      ),
    );
  }
}

/// Root widget that reacts to [AuthService] state and locks the app when
/// the OS sends a lifecycle pause event.
class _AppRoot extends StatefulWidget {
  const _AppRoot();

  @override
  State<_AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<_AppRoot> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      context.read<AuthService>().lock();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AuthService>(
      builder: (_, auth, _) {
        if (!auth.isPinSet) return const SetupPinScreen();
        if (auth.isLocked) return const LockScreen();
        return const HomeScreen();
      },
    );
  }
}
