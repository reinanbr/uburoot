// SPDX-License-Identifier: GPL-3.0-or-later
package com.reinanbr.uburoot.hwbridge

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import com.reinanbr.uburoot.R
import com.reinanbr.uburoot.root.RootShell
import com.reinanbr.uburoot.root.UbuPaths
import com.reinanbr.uburoot.terminal.SessionService
import com.reinanbr.uburoot.ui.HardwareActivity
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Serves Android's audio, camera, sensors and location to Ubuntu (uburoot-audio,
 * -camera, -sensors, -gps) while at least one bridge is on. Started from the Hardware
 * screen (the app is in front, so Android lets a camera/microphone/location foreground
 * service start); Stop all and Repair mounts turn every bridge off.
 */
class BridgeService : Service() {
    private val scope = MainScope()
    private val lock = Mutex()
    private val servers = mutableMapOf<String, BridgeServer>()
    private val hw = UbuPaths.script("hardware.sh")

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL, getString(R.string.hwbridge_channel), NotificationManager.IMPORTANCE_LOW),
        )
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Started with startForegroundService: go foreground at once, whatever comes next.
        goForeground()
        val name = intent?.getStringExtra(EXTRA_NAME)
        when (intent?.action) {
            ACTION_ON -> if (name in NAMES) scope.launch { enable(name!!) }
            ACTION_OFF -> if (name in NAMES) scope.launch { disable(name!!) }
            else -> scope.launch { disableAll() }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        servers.values.forEach { it.stop() }
        servers.clear()
        _active.value = emptySet()
        scope.cancel()
        super.onDestroy()
    }

    private suspend fun enable(name: String) = lock.withLock {
        if (name in servers) return@withLock
        if (SessionService.stopping.value) {
            _error.value = getString(R.string.hwbridge_stopping)
            return@withLock settle()
        }
        val srv = BridgeServer(name) { Bridges.handle(applicationContext, name, it) }
        // mount.sh is idempotent: Ubuntu must be mounted for /run/uburoot-bridge. The
        // token goes through echo, a shell builtin, so it never shows up in a process's argv.
        val r = RootShell.run(
            "${UbuPaths.script("mount.sh")} >/dev/null 2>&1; " +
                "echo ${srv.token} | $hw bridge publish $name ${srv.socketName}",
        )
        if (r.ok) {
            servers[name] = srv
            _error.value = ""
        } else {
            srv.stop()
            _error.value = r.text.trim()
        }
        settle()
    }

    private suspend fun disable(name: String) = lock.withLock {
        servers.remove(name)?.stop()
        RootShell.run("$hw bridge unpublish $name")
        settle()
    }

    private suspend fun disableAll() = lock.withLock {
        if (servers.isNotEmpty()) {
            servers.values.forEach { it.stop() }
            servers.clear()
            RootShell.run("$hw bridge unpublish all")
        }
        settle()
    }

    /** Publishes the state, then updates the notification or stops. */
    private fun settle() {
        _active.value = servers.keys.toSet()
        if (servers.isEmpty()) {
            ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
            stopSelf()
        } else {
            goForeground()
        }
    }

    private fun has(perm: String) = checkSelfPermission(perm) == PackageManager.PERMISSION_GRANTED

    /** Only the types whose permission is held: Android 14+ refuses the others. */
    private fun goForeground() {
        val on = servers.keys
        var type = 0
        if (Build.VERSION.SDK_INT >= 30) {
            if ("camera" in on &&
                has(Manifest.permission.CAMERA)
            ) {
                type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
            }
            if ("audio" in on && has(Manifest.permission.RECORD_AUDIO)) {
                type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            }
        }
        if (Build.VERSION.SDK_INT >= 29 && "location" in on && has(Manifest.permission.ACCESS_FINE_LOCATION)) {
            type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION
        }
        // Sensors and playback have no type of their own.
        if (Build.VERSION.SDK_INT >= 34 && (type == 0 || "sensors" in on || "audio" in on)) {
            type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
        }
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, HardwareActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val stop = PendingIntent.getService(
            this,
            1,
            Intent(this, BridgeService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val n = NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(getString(R.string.hwbridge_title))
            .setContentText(if (on.isEmpty()) getString(R.string.hwbridge_starting) else on.sorted().joinToString(", "))
            .setContentIntent(open)
            .setOngoing(true)
            .setShowWhen(false)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .addAction(0, getString(R.string.hwbridge_stop), stop)
            .build()
        ServiceCompat.startForeground(this, NOTIFICATION_ID, n, type)
    }

    companion object {
        val NAMES = listOf("audio", "camera", "sensors", "location")
        private const val CHANNEL = "bridges"
        private const val NOTIFICATION_ID = 3
        private const val ACTION_ON = "com.reinanbr.uburoot.action.BRIDGE_ON"
        private const val ACTION_OFF = "com.reinanbr.uburoot.action.BRIDGE_OFF"
        private const val ACTION_STOP = "com.reinanbr.uburoot.action.BRIDGE_STOP"
        private const val EXTRA_NAME = "name"

        private val _active = MutableStateFlow<Set<String>>(emptySet())

        /** The bridges being served. */
        val active: StateFlow<Set<String>> = _active.asStateFlow()

        private val _error = MutableStateFlow("")

        /** Why the last bridge could not start (hardware.sh's message); empty = none. */
        val error: StateFlow<String> = _error.asStateFlow()

        /** On: from the Hardware screen only (the app in front may start this service). */
        fun set(context: Context, name: String, on: Boolean) {
            val i = Intent(context, BridgeService::class.java).putExtra(EXTRA_NAME, name)
            if (on) {
                context.startForegroundService(i.setAction(ACTION_ON))
            } else if (name in _active.value) {
                // Already a foreground service: a plain start is allowed even from the background.
                runCatching { context.startService(i.setAction(ACTION_OFF)) }
            }
        }

        /** Stop all / Repair mounts / Reset: the token files go with Ubuntu's /run anyway. */
        fun stopAll(context: Context) {
            if (_active.value.isEmpty()) return
            runCatching { context.startService(Intent(context, BridgeService::class.java).setAction(ACTION_STOP)) }
        }
    }
}
