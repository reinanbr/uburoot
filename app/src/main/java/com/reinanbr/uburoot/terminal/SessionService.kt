// SPDX-License-Identifier: GPL-3.0-or-later
package com.reinanbr.uburoot.terminal

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.widget.Toast
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import com.reinanbr.uburoot.R
import com.reinanbr.uburoot.hwbridge.BridgeService
import com.reinanbr.uburoot.root.RootShell
import com.reinanbr.uburoot.root.UbuPaths
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch

/**
 * Foreground service that keeps the process, and so the terminal sessions,
 * alive while the app is in the background. It holds no sessions itself
 * ([SessionManager] does); it starts with the first one and stops after the last.
 */
class SessionService : Service() {
    private val scope = MainScope()
    private var stopping
        get() = _stopping.value
        set(value) {
            _stopping.value = value
        }
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL, getString(R.string.notif_channel), NotificationManager.IMPORTANCE_LOW),
        )
        goForeground()
        scope.launch {
            SessionManager.state.combine(_wakeLockHeld) { s, _ -> s }.collect { s ->
                if (s.sessions.isEmpty()) {
                    if (!stopping) stopSelf()
                } else {
                    nm.notify(NOTIFICATION_ID, buildNotification())
                }
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        goForeground()
        when (intent?.action) {
            ACTION_STOP_ALL -> stopAll()
            ACTION_TOGGLE_WAKE_LOCK -> if (wakeLock == null) acquireLocks() else releaseLocks()
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        releaseLocks()
        scope.cancel()
        super.onDestroy()
    }

    private fun goForeground() {
        val type = if (Build.VERSION.SDK_INT >= 34) ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE else 0
        ServiceCompat.startForeground(this, NOTIFICATION_ID, buildNotification(), type)
    }

    /**
     * Close every session, release the mounts (killing anything left in the chroot), then
     * revert the kernel changes recorded by uburoot-kernel (after the kill, so modules
     * are no longer in use).
     */
    private fun stopAll() {
        if (stopping) return
        stopping = true
        SessionManager.closeAll()
        BridgeService.stopAll(this)
        // umount.sh --kill can take a while (tens of seconds on slow devices).
        getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, buildNotification())
        scope.launch {
            val r = RootShell.run(
                "${UbuPaths.script("umount.sh")} --kill; u=\$?; ${UbuPaths.script("kernel.sh")} -y revert; " +
                    "k=\$?; [ \$u = 0 ] && [ \$k = 0 ]",
            )
            val msg = if (r.ok) getString(R.string.stopped_all) else getString(R.string.stop_all_failed, r.text)
            Toast.makeText(applicationContext, msg, Toast.LENGTH_LONG).show()
            stopping = false
            if (SessionManager.sessions.isEmpty()) stopSelf()
        }
    }

    // Same pair Termux uses: CPU stays on and Wi-Fi keeps full performance with the screen off.
    @SuppressLint("WakelockTimeout")
    @Suppress("DEPRECATION")
    private fun acquireLocks() {
        wakeLock = getSystemService(PowerManager::class.java)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "uburoot:sessions")
            .apply { acquire() }
        wifiLock = applicationContext.getSystemService(WifiManager::class.java)
            .createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "uburoot:sessions")
            .apply { acquire() }
        _wakeLockHeld.value = true
    }

    private fun releaseLocks() {
        wakeLock?.takeIf { it.isHeld }?.release()
        wifiLock?.takeIf { it.isHeld }?.release()
        wakeLock = null
        wifiLock = null
        _wakeLockHeld.value = false
    }

    private fun buildNotification(): Notification {
        val running = SessionManager.state.value.running
        val held = _wakeLockHeld.value
        val text = if (stopping) {
            getString(R.string.notif_stopping)
        } else {
            buildString {
                // Not a plural: in Portuguese, CLDR puts 0 in "one" ("0 sessão").
                if (running == 0) {
                    append(getString(R.string.notif_no_sessions))
                } else {
                    append(resources.getQuantityString(R.plurals.notif_sessions, running, running))
                }
                if (held) append(" · ").append(getString(R.string.notif_wake_lock_held))
            }
        }
        val open = PendingIntent.getActivity(
            this,
            0,
            TerminalActivity.intent(this, newSession = false),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val newSession = PendingIntent.getActivity(
            this,
            1,
            TerminalActivity.intent(this, newSession = true),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val builder = NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(getString(R.string.app_name))
            .setContentText(text)
            .setContentIntent(open)
            .setOngoing(true)
            .setShowWhen(false)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
        // No tap target while stopping: a new session would mount.sh while umount.sh runs.
        if (stopping) return builder.setContentIntent(null).setProgress(0, 0, true).build()
        return builder
            .addAction(0, getString(R.string.action_new_session), newSession)
            .addAction(0, getString(R.string.action_stop_all), servicePending(ACTION_STOP_ALL, 2))
            .addAction(
                0,
                getString(if (held) R.string.action_release_wake_lock else R.string.action_acquire_wake_lock),
                servicePending(ACTION_TOGGLE_WAKE_LOCK, 3),
            )
            .build()
    }

    private fun servicePending(action: String, code: Int) = PendingIntent.getService(
        this,
        code,
        Intent(this, SessionService::class.java).setAction(action),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    companion object {
        private const val CHANNEL = "sessions"
        private const val NOTIFICATION_ID = 1
        const val ACTION_STOP_ALL = "com.reinanbr.uburoot.action.STOP_ALL"
        const val ACTION_TOGGLE_WAKE_LOCK = "com.reinanbr.uburoot.action.TOGGLE_WAKE_LOCK"

        private val _stopping = MutableStateFlow(false)

        /** "Stop all" is releasing the mounts; the preflight waits for it. */
        val stopping: StateFlow<Boolean> = _stopping.asStateFlow()

        private val _wakeLockHeld = MutableStateFlow(false)
        val wakeLockHeld: StateFlow<Boolean> = _wakeLockHeld.asStateFlow()

        fun intent(context: Context, action: String? = null): Intent =
            Intent(context, SessionService::class.java).setAction(action)
    }
}
