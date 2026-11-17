package com.macoid.terminal

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon
import android.os.IBinder
import android.os.PowerManager

/** Keeps the process (and so every shell session) alive while the app is in the background, like Termux does. */
class TerminalService : Service() {
    companion object {
        private const val CH = "macoid_service"
        private const val ID = 1
        const val ACT_EXIT = "com.macoid.terminal.EXIT"
        const val ACT_WAKE = "com.macoid.terminal.WAKE"
        @Volatile var instance: TerminalService? = null

        fun start(c: Context) { c.startForegroundService(Intent(c, TerminalService::class.java)) }
        fun stop(c: Context) { c.stopService(Intent(c, TerminalService::class.java)) }
        fun wakeHeld(): Boolean = instance?.wl?.isHeld == true
        fun toggleWake(c: Context) { c.startService(Intent(c, TerminalService::class.java).setAction(ACT_WAKE)) }
    }

    internal var wl: PowerManager.WakeLock? = null

    override fun onBind(i: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CH, "Macoid sessions", NotificationManager.IMPORTANCE_LOW))
        startForeground(ID, build())
    }

    override fun onStartCommand(i: Intent?, flags: Int, startId: Int): Int {
        when (i?.action) {
            ACT_EXIT -> {
                Sessions.closeAll()
                stopForeground(true)
                stopSelf()
                return START_NOT_STICKY
            }
            ACT_WAKE -> {
                val w = wl
                if (w != null && w.isHeld) w.release()
                else {
                    val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                    wl = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "macoid:sessions").apply { setReferenceCounted(false); acquire() }
                }
            }
        }
        refresh()
        return START_NOT_STICKY
    }

    fun refresh() {
        getSystemService(NotificationManager::class.java).notify(ID, build())
    }

    private fun build(): Notification {
        val open = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE
        )
        fun act(code: Int, a: String) =
            PendingIntent.getService(this, code, Intent(this, TerminalService::class.java).setAction(a), PendingIntent.FLAG_IMMUTABLE)
        val wake = wl?.isHeld == true
        return Notification.Builder(this, CH)
            .setContentTitle("Macoid")
            .setContentText(Sessions.list.size.toString() + " session(s)" + if (wake) " - wake lock on" else "")
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentIntent(open)
            .setOngoing(true)
            .addAction(Notification.Action.Builder(
                Icon.createWithResource(this, android.R.drawable.ic_lock_idle_lock),
                if (wake) "Wake lock: off" else "Wake lock: on", act(1, ACT_WAKE)).build())
            .addAction(Notification.Action.Builder(
                Icon.createWithResource(this, android.R.drawable.ic_menu_close_clear_cancel),
                "Exit", act(2, ACT_EXIT)).build())
            .build()
    }

    override fun onDestroy() {
        wl?.let { if (it.isHeld) it.release() }
        if (instance === this) instance = null
        super.onDestroy()
    }
}
