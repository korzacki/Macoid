package com.macoid.terminal

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.media.MediaPlayer
import android.os.VibrationEffect
import android.os.Vibrator
import android.speech.tts.TextToSpeech
import java.io.File

/** Lets shell scripts reach Android APIs: `am broadcast -n com.macoid.terminal/.BridgeReceiver -a macoid.X --es key K ...` */
class BridgeReceiver : BroadcastReceiver() {
    companion object {
        private val lock = Any()
        private var tts: TextToSpeech? = null
        private var ready = false
        private val queue = ArrayList<String>()
    }

    override fun onReceive(c: Context, i: Intent) {
        val root = File(c.filesDir, "macoid")
        val key = try { File(root, ".key").readText().trim() } catch (e: Exception) { "" }
        if (key.isEmpty() || i.getStringExtra("key") != key) return
        val home = File(root, "home")
        try {
            when (i.action) {
                "macoid.CLIP_SET" -> {
                    val cm = c.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                    cm.setPrimaryClip(ClipData.newPlainText("macoid", File(home, ".pasteboard").readText()))
                }
                "macoid.CLIP_GET" -> {
                    val cm = c.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                    val t = cm.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(c)?.toString() ?: ""
                    File(home, ".pasteboard_out").writeText(t)
                }
                "macoid.SAY" -> say(c, i.getStringExtra("text") ?: "")
                "macoid.NOTIFY" -> {
                    val nm = c.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                    nm.createNotificationChannel(NotificationChannel("macoid", "Macoid", NotificationManager.IMPORTANCE_DEFAULT))
                    val n = Notification.Builder(c, "macoid")
                        .setContentTitle(i.getStringExtra("title") ?: "Macoid")
                        .setContentText(i.getStringExtra("text") ?: "")
                        .setSmallIcon(android.R.drawable.ic_dialog_info).build()
                    nm.notify((System.currentTimeMillis() % 100000).toInt(), n)
                }
                "macoid.PLAY" -> {
                    val mp = MediaPlayer()
                    mp.setDataSource(i.getStringExtra("path") ?: return)
                    mp.setOnCompletionListener { it.release() }
                    mp.prepare(); mp.start()
                }
                "macoid.VIBRATE" -> {
                    @Suppress("DEPRECATION")
                    val v = c.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
                    v.vibrate(VibrationEffect.createOneShot(300, VibrationEffect.DEFAULT_AMPLITUDE))
                }
            }
        } catch (e: Exception) {
            try { File(home, ".bridge_error").writeText(e.toString()) } catch (x: Exception) { }
        }
    }

    private fun say(c: Context, text: String) = synchronized(lock) {
        val t = tts
        if (t == null) {
            queue.add(text)
            tts = TextToSpeech(c.applicationContext) { st ->
                synchronized(lock) {
                    ready = st == TextToSpeech.SUCCESS
                    if (ready) { queue.forEach { x -> tts?.speak(x, TextToSpeech.QUEUE_ADD, null, "macoid") }; queue.clear() }
                }
            }
        } else if (ready) t.speak(text, TextToSpeech.QUEUE_ADD, null, "macoid") else queue.add(text)
        Unit
    }
}
