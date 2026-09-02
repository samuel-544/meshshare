package com.meshshare.meshshare

import android.bluetooth.*
import android.bluetooth.le.*
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.util.UUID

/**
 * Native Android plugin for MeshShare.
 *
 * Implements:
 *   - BLE Peripheral (advertising + GATT server) — Android BLE APIs
 *   - Foreground service lifecycle
 *   - EventChannel to push received chunk bytes to Dart
 *
 * Channel names must match those in platform_channel.dart.
 */
class MeshSharePlugin : FlutterPlugin, MethodCallHandler {

    companion object {
        private const val TAG = "MeshSharePlugin"
        const val METHOD_CHANNEL = "com.meshshare/mesh_service"
        const val EVENT_CHANNEL  = "com.meshshare/incoming_chunks"

        val SERVICE_UUID: UUID = UUID.fromString("6e400001-b5a3-f393-e0a9-e50e24dcca9e")
        val RX_CHAR_UUID: UUID = UUID.fromString("6e400002-b5a3-f393-e0a9-e50e24dcca9e")
        val TX_CHAR_UUID: UUID = UUID.fromString("6e400003-b5a3-f393-e0a9-e50e24dcca9e")
        val IDENTITY_CHAR_UUID: UUID = UUID.fromString("6e400004-b5a3-f393-e0a9-e50e24dcca9e")
        val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }

    private lateinit var context: Context
    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel

    private var eventSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    private var bluetoothManager: BluetoothManager? = null
    private var bluetoothAdapter: BluetoothAdapter? = null
    private var gattServer: BluetoothGattServer? = null
    private var advertiser: BluetoothLeAdvertiser? = null
    private var advertiseCallback: AdvertiseCallback? = null

    // Characteristics stored so we can notify connected Centrals.
    private var txCharacteristic: BluetoothGattCharacteristic? = null
    private var identityCharacteristic: BluetoothGattCharacteristic? = null
    private var localIdentity: ByteArray? = null

    // addService() is async — the service isn't actually queryable by a
    // connecting Central until onServiceAdded() confirms it. Advertising
    // must not start before that, or a Central can connect and call
    // discoverServices() into an empty/incomplete GATT table.
    private var serviceReady = false
    private var pendingAdvertiseIdentity: ByteArray? = null

    // ── FlutterPlugin lifecycle ───────────────────────────────────────────────

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        bluetoothManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        bluetoothAdapter = bluetoothManager?.adapter

        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL)
        methodChannel.setMethodCallHandler(this)

        eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL)
        eventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                eventSink = sink
            }
            override fun onCancel(arguments: Any?) {
                eventSink = null
            }
        })
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        stopGattServer()
        stopAdvertising()
    }

    private fun sendEvent(event: Map<String, Any>) {
        mainHandler.post {
            eventSink?.success(event)
        }
    }

    // ── MethodCallHandler ────────────────────────────────────────────────────

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "startForegroundService" -> {
                val intent = Intent(context, MeshShareService::class.java)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
                result.success(null)
            }
            "stopForegroundService" -> {
                context.stopService(Intent(context, MeshShareService::class.java))
                result.success(null)
            }
            "startGattServer" -> {
                startGattServer()
                result.success(null)
            }
            "stopGattServer" -> {
                stopGattServer()
                result.success(null)
            }
            "refreshAdvertising" -> {
                val identity = call.argument<ByteArray>("identity")
                localIdentity = identity
                identityCharacteristic?.value = identity
                stopAdvertising()
                if (identity != null) {
                    if (serviceReady) {
                        startAdvertising(identity)
                    } else {
                        // GATT service not confirmed yet — advertise as soon as
                        // onServiceAdded() fires instead of racing it.
                        pendingAdvertiseIdentity = identity
                    }
                }
                result.success(null)
            }
            "sendRawNotification" -> {
                val deviceId = call.argument<String>("deviceId")
                val data     = call.argument<ByteArray>("data")
                if (deviceId != null && data != null) {
                    sendNotification(deviceId, data)
                }
                result.success(null)
            }
            "sendHandshakeMessage" -> {
                val deviceId = call.argument<String>("deviceId")
                val step     = call.argument<Int>("step")
                val data     = call.argument<ByteArray>("data")
                if (deviceId != null && step != null && data != null) {
                    sendNotification(deviceId, buildHandshakePayload(step, data))
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    // ── GATT server ───────────────────────────────────────────────────────────

    private fun startGattServer() {
        serviceReady = false
        pendingAdvertiseIdentity = null
        gattServer = bluetoothManager?.openGattServer(context, gattServerCallback)

        // Build service
        val service = BluetoothGattService(SERVICE_UUID, BluetoothGattService.SERVICE_TYPE_PRIMARY)

        // RX: Centrals write chunk bytes here (WRITE + WRITE_NO_RESPONSE)
        val rxChar = BluetoothGattCharacteristic(
            RX_CHAR_UUID,
            BluetoothGattCharacteristic.PROPERTY_WRITE or
                    BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE,
            BluetoothGattCharacteristic.PERMISSION_WRITE
        )

        // TX: We notify Centrals of ACKs / keepalive echoes (NOTIFY)
        val txChar = BluetoothGattCharacteristic(
            TX_CHAR_UUID,
            BluetoothGattCharacteristic.PROPERTY_NOTIFY,
            BluetoothGattCharacteristic.PERMISSION_READ
        )
        // CCCD descriptor — required for notifications
        val cccd = BluetoothGattDescriptor(
            CCCD_UUID,
            BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE
        )
        txChar.addDescriptor(cccd)
        txCharacteristic = txChar

        // Identity: Centrals read/write their 32-byte identity hash here
        val identityChar = BluetoothGattCharacteristic(
            IDENTITY_CHAR_UUID,
            BluetoothGattCharacteristic.PROPERTY_READ or
                    BluetoothGattCharacteristic.PROPERTY_WRITE,
            BluetoothGattCharacteristic.PERMISSION_READ or
                    BluetoothGattCharacteristic.PERMISSION_WRITE
        )
        identityChar.value = localIdentity
        identityCharacteristic = identityChar

        service.addCharacteristic(rxChar)
        service.addCharacteristic(txChar)
        service.addCharacteristic(identityChar)
        gattServer?.addService(service)
    }

    private fun stopGattServer() {
        gattServer?.close()
        gattServer = null
        serviceReady = false
        pendingAdvertiseIdentity = null
    }

    // Connected devices: address → BluetoothDevice (so we can notify them).
    private val connectedCentrals = mutableMapOf<String, BluetoothDevice>()

    private val gattServerCallback = object : BluetoothGattServerCallback() {

        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            val connected = newState == BluetoothProfile.STATE_CONNECTED
            if (connected) {
                connectedCentrals[device.address] = device
            } else {
                connectedCentrals.remove(device.address)
            }
            // Tell Dart about the link-state change on this (Peripheral-side)
            // GATT link. Without the disconnect signal, a peer that completed a
            // handshake against our GATT server stays "online" in the UI forever
            // because the Central-side connectionState stream never sees it.
            sendEvent(mapOf(
                "type"      to "peripheralLink",
                "deviceId"  to device.address,
                "connected" to connected
            ))
        }

        override fun onServiceAdded(status: Int, service: BluetoothGattService) {
            if (status != BluetoothGatt.GATT_SUCCESS || service.uuid != SERVICE_UUID) return
            serviceReady = true
            pendingAdvertiseIdentity?.let { startAdvertising(it) }
            pendingAdvertiseIdentity = null
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray
        ) {
            if (responseNeeded) {
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
            }

            when (characteristic.uuid) {
                RX_CHAR_UUID -> {
                    if (value.isEmpty()) return
                    val typeByte = value[0].toInt() and 0xFF
                    val payload  = value.drop(1).toByteArray()
                    when (typeByte) {
                        0x00 -> {
                            // Keepalive: echo back to the Central via notification.
                            sendNotification(device.address, byteArrayOf(0x00))
                        }
                        0xFE -> {
                            // Handshake message: [0xFE, step(1), ...bytes]
                            val step = (payload.firstOrNull()?.toInt() ?: 0) and 0xFF
                            val msgBytes = payload.drop(1).toByteArray()
                            Log.d(TAG, "RX handshake step=$step bytes=${msgBytes.size} from=${device.address} eventSink=${eventSink != null}")
                            sendEvent(mapOf(
                                "type"     to "handshake",
                                "deviceId" to device.address,
                                "step"     to step,
                                "data"     to msgBytes.toList()
                            ))
                        }
                        else -> {
                            // Generic mesh packet: chunk (0x01), ack (0xFF), routed
                            // handshake (0x02), presence announce (0x03), etc. The
                            // full bytes (including the leading type byte) are
                            // forwarded as-is so Dart does all classification —
                            // new packet types never need a native code change.
                            sendEvent(mapOf(
                                "type"     to "packet",
                                "deviceId" to device.address,
                                "data"     to value.toList()
                            ))
                        }
                    }
                }
                IDENTITY_CHAR_UUID -> {
                    // Remote peer identity is written by the Central, but this
                    // readable characteristic must continue exposing our local
                    // identity so the Central does not read its own value back.
                }
            }
        }

        override fun onCharacteristicReadRequest(
            device: BluetoothDevice,
            requestId: Int,
            offset: Int,
            characteristic: BluetoothGattCharacteristic
        ) {
            // Return the current value (e.g. local identity stored by Dart call).
            val value = if (characteristic.uuid == IDENTITY_CHAR_UUID) {
                localIdentity
            } else {
                characteristic.value
            }
            gattServer?.sendResponse(
                device, requestId, BluetoothGatt.GATT_SUCCESS, offset,
                value
            )
        }

        override fun onDescriptorWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray
        ) {
            descriptor.value = value
            if (responseNeeded) {
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
            }
        }
    }

    // ── BLE Advertising ───────────────────────────────────────────────────────

    private fun startAdvertising(identity: ByteArray) {
        advertiser = bluetoothAdapter?.bluetoothLeAdvertiser ?: return

        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setConnectable(true)
            .setTimeout(0) // advertise indefinitely
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
            .build()

        // Include service UUID so scanning peers can filter for us.
        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .addServiceUuid(ParcelUuid(SERVICE_UUID))
            .build()

        val scanResponse = AdvertiseData.Builder()
            .setIncludeDeviceName(true)
            .build()

        advertiseCallback = object : AdvertiseCallback() {
            override fun onStartFailure(errorCode: Int) {
                // Log failure — non-fatal, scanning peers will still find us.
            }
        }

        advertiser?.startAdvertising(settings, data, scanResponse, advertiseCallback)
    }

    private fun stopAdvertising() {
        advertiseCallback?.let { advertiser?.stopAdvertising(it) }
        advertiseCallback = null
    }

    // ── Notification helpers ──────────────────────────────────────────────────

    /** Notify a connected Central via the TX characteristic. */
    private fun sendNotification(deviceId: String, payload: ByteArray) {
        val type = payload.firstOrNull()?.toInt()?.and(0xFF) ?: -1
        val device = connectedCentrals[deviceId]
        if (device == null) {
            Log.d(TAG, "TX notify skipped type=$type bytes=${payload.size}; device not connected: $deviceId")
            return
        }
        val tx = txCharacteristic
        if (tx == null) {
            Log.d(TAG, "TX notify skipped type=$type bytes=${payload.size}; TX characteristic missing")
            return
        }
        Log.d(TAG, "TX notify type=$type bytes=${payload.size} to=$deviceId")
        tx.value = payload
        gattServer?.notifyCharacteristicChanged(device, tx, false)
    }

    /** Build handshake payload: [0xFE, step(1 byte), ...data] */
    private fun buildHandshakePayload(step: Int, data: ByteArray): ByteArray {
        val buf = ByteArray(2 + data.size)
        buf[0] = 0xFE.toByte()
        buf[1] = (step and 0xFF).toByte()
        data.copyInto(buf, 2)
        return buf
    }
}
