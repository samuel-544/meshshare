package com.meshshare.meshshare

import android.app.*
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * Foreground service that keeps MeshShare's BLE stack alive when the
 * app is backgrounded or the screen is off.
 *
 * Android kills background apps aggressively; a foreground service with
 * a visible notification is the only reliable way to keep BLE scanning
 * and advertising running during a long file transfer.
 */
class MeshShareService : Service() {

    companion object {
        private const val CHANNEL_ID   = "meshshare_ble"
        private const val CHANNEL_NAME = "MeshShare BLE"
        private const val NOTIF_ID     = 1
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        startForeground(NOTIF_ID, buildNotification())
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Restart if killed by the system.
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        super.onDestroy()
        stopForeground(STOP_FOREGROUND_REMOVE)
    }

    // ── Notification ──────────────────────────────────────────────────────────

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                CHANNEL_NAME,
                NotificationManager.IMPORTANCE_LOW  // silent — no sound/vibration
            ).apply {
                description = "MeshShare is running in the background"
            }
            val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
            nm.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        // Tapping the notification opens the app.
        val openApp = PendingIntent.getActivity(
            this, 0,
            packageManager.getLaunchIntentForPackage(packageName),
            PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("MeshShare active")
            .setContentText("Bluetooth mesh is running")
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setContentIntent(openApp)
            .setOngoing(true)         // cannot be dismissed by the user
            .setSilent(true)
            .build()
    }
}
