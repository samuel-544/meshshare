# MeshShare Project Challenges and Fixes

This file contains simple presentation notes about some challenges we faced while building the MeshShare Flutter application, and how we fixed them in the code.

## 1. Peer Was Discovered, But File or Message Sending Failed

One major challenge was that a peer could be discovered over Bluetooth, but sending a file or message still failed.

The reason was that discovery and secure communication are not the same thing. Bluetooth discovery only means that one device has found another nearby device. But before sending files or messages, the two devices must complete the Noise handshake and create session keys.

At one point, the app was adding the discovered peer to the UI before the handshake had completed. So the user could select the peer, but when the app tried to send data, there was no secure session key available.

### How we fixed it in code

In `lib/features/bluetooth/ble_mesh_service.dart`, we changed the discovery flow.

Before, the peer was exposed to the UI immediately after Bluetooth discovery.

Now, the peer is stored internally first, but it is only added to the UI after the handshake succeeds.

The important logic is:

```dart
_keys.storeSession(peer.shortId, result.sendKey, result.receiveKey);
_peerController.add(peer);
```

This means:

- the handshake must complete first
- session keys must be stored first
- only then is the peer shown as ready

So the app no longer allows sending to a peer that has not completed encryption setup.

## 2. Handshake Encryption Was Not Completing Correctly

Another challenge was that the encryption handshake was not always completing correctly.

The app uses a Noise-style handshake. This means both devices exchange handshake messages and then derive shared encryption keys. If this process fails, the devices cannot securely send files or messages.

The issue was mainly around the order of the handshake messages and when the app considered the peer ready.

### How we fixed it in code

In `BleMeshService`, we separated the handshake into two roles:

- initiator: the device that connects first
- responder: the device that receives the connection

The initiator sends message 1:

```dart
final msg1 = await initiator.writeMessage1();
```

The responder receives message 1 and sends message 2:

```dart
final msg2 = await responder.readMsg1WriteMsg2(event.data);
```

The initiator receives message 2 and sends message 3:

```dart
final msg3 = await initiator.readMsg2WriteMsg3(data);
```

After that, both sides store the session keys using:

```dart
_keys.storeSession(peer.shortId, result.sendKey, result.receiveKey);
```

This fixed the issue because session keys are now created and saved only after the full handshake process is complete.

## 3. Device Identity Was Being Mixed Up

Each device has its own identity. This identity helps the app know which peer it is communicating with.

We found a problem where a device could write its identity to the remote device, then read back the wrong identity. In some cases, the app could read back its own identity instead of the other device's identity.

This confused the handshake and session storage because the app could store keys under the wrong peer ID.

### How we fixed it in code

In `android/app/src/main/kotlin/com/meshshare/meshshare/MeshSharePlugin.kt`, we added a separate variable for the local device identity:

```kotlin
private var localIdentity: ByteArray? = null
```

When Dart refreshes advertising, the Android side stores the local identity:

```kotlin
localIdentity = identity
identityCharacteristic?.value = identity
```

Then, when another device reads the identity characteristic, Android returns the local device identity:

```kotlin
val value = if (characteristic.uuid == IDENTITY_CHAR_UUID) {
    localIdentity
} else {
    characteristic.value
}
```

We also stopped overwriting the identity characteristic with the remote peer's written value.

In simple terms, the device now keeps its own identity separate from the remote peer's identity. This made peer identification more reliable.

## 4. Keepalive Messages Were Not Being Answered

Another challenge was connection stability.

The app sends keepalive messages to check whether a connected peer is still available. But the receiving side was not replying to these keepalive packets.

This could make the app think a peer had disconnected, even when the peer was still nearby.

### How we fixed it in code

In `MeshSharePlugin.kt`, we added handling for keepalive packets.

The keepalive packet uses type `0x00`.

When Android receives this packet, it now sends the same keepalive response back:

```kotlin
0x00 -> {
    sendNotification(device.address, byteArrayOf(0x00))
}
```

On the Flutter side, when the app receives this response, it resets the missed keepalive counter:

```dart
if (type == 0x00) {
  _keepaliveMissed[peerId] = 0;
}
```

This made the connection tracking more stable.

## 5. Relayed File Chunks Were Missing a Packet Type

MeshShare supports mesh-style forwarding. This means a device can receive a file chunk and forward it to another peer.

We found that directly sent chunks had a packet type marker, but relayed chunks did not.

Direct chunks were sent like this:

```dart
packet[0] = 0x01;
packet.setAll(1, chunkBytes);
```

But relayed chunks were previously being sent as raw chunk bytes without the `0x01` marker.

This caused the receiver to misread the data because it expects the first byte to tell it what type of packet it is receiving.

### How we fixed it in code

In `lib/features/bluetooth/ble_mesh_service.dart`, we changed the relay logic so that relayed chunks use the same packet format as direct chunks:

```dart
final chunkBytes = chunk.toBytes();
final packet = Uint8List(1 + chunkBytes.length);
packet[0] = 0x01;
packet.setAll(1, chunkBytes);
await rx.write(packet, withoutResponse: true);
```

This means both direct transfers and relayed transfers now use the same packet structure.

## 6. Android Foreground Service Caused Permission Problems

We also had an Android-specific challenge.

The app was designed to use a foreground service so that Bluetooth could continue running in the background. But modern Android versions are strict with Bluetooth permissions and foreground service permissions.

If the foreground service started before the required permissions were fully granted, Android could reject it and crash the app.

### How we fixed it in code

For the demo version, we disabled automatic foreground-service startup in `BleMeshService`.

Instead of starting the foreground service immediately, we kept BLE running only while the app is open.

The code now starts the GATT server and advertising, but does not automatically start the foreground service:

```dart
await _channel.startGattServer();
_scheduleAdvertiseRefresh();
```

This made the demo more stable because it avoided permission crashes during testing.

## 7. Running the Demo on Kali Linux Without an Android Phone

For the presentation, another practical issue was that no Android device was connected to the laptop.

Because the project is built with Flutter, we could still run the app as a Linux desktop application.

### How we solved it

We used the Linux desktop target:

```bash
flutter run -d linux
```

This launches the app as a desktop window on Kali Linux.

This is useful for presenting the UI, navigation, file-sharing flow, messaging screens, and the general project idea even without a connected Android phone.

## Short Summary

The main challenge was that Bluetooth discovery alone was not enough.

We had to make sure the app followed the correct order:

1.  discover peer
2. exchange identities
3. complete Noise handshake
4. store session keys
5. show peer as ready
6. send encrypted file or message

By fixing the handshake flow, identity handling, keepalive response, and relay packet format, the app became more stable and more correct for secure mesh file sharing.

