package com.macoid.terminal

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.SharedPreferences
import android.graphics.Color
import android.graphics.Typeface
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.inputmethod.InputMethodManager
import android.widget.FrameLayout
import android.widget.HorizontalScrollView
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import com.termux.terminal.TerminalSession
import com.termux.view.TerminalView
import com.termux.view.TerminalViewClient

/** Termux-style screen: session tabs on top, a real terminal (PTY + xterm emulation) in the middle, extra keys at the bottom. */
class MainActivity : Activity(), Sessions.Ui {
    private lateinit var tv: TerminalView
    private lateinit var tabs: LinearLayout
    private lateinit var tabScroll: HorizontalScrollView
    private lateinit var ctrlBtn: TextView
    private lateinit var altBtn: TextView
    private lateinit var prefs: SharedPreferences
    private val main = Handler(Looper.getMainLooper())
    private var ctrl = false
    private var alt = false
    private var fontDp = 14

    private val viewClient = proxyOf<TerminalViewClient> { n, a -> viewCall(n, a) }

    private fun viewCall(n: String, a: Array<Any?>): Any? = when (n) {
        "onScale" -> {
            val s = a[0] as Float
            if (s < 0.9f || s > 1.1f) { zoom(s > 1f); 1f } else s
        }
        "onSingleTapUp" -> { showKeyboard(); null }
        "shouldBackButtonBeMappedToEscape" -> false
        "shouldEnforceCharBasedInput" -> true
        "shouldUseCtrlSpaceWorkaround" -> false
        "isTerminalViewSelected" -> true
        "onKeyDown" -> {
            val code = a[0] as Int
            val s = a.getOrNull(2) as? TerminalSession
            if (s != null && !s.isRunning && code == KeyEvent.KEYCODE_ENTER) { Sessions.remove(s); true } else false
        }
        "readControlKey" -> readMod(true)
        "readAltKey" -> readMod(false)
        else -> null
    }

    override fun onCreate(b: Bundle?) {
        super.onCreate(b)
        Sessions.init(this)
        prefs = getSharedPreferences("macoid", MODE_PRIVATE)
        fontDp = prefs.getInt("font", 14)
        buildUi()
        Sessions.ui = this
        if (Sessions.list.isEmpty()) Sessions.create(false)
        show(Sessions.current)
        handleIntent(intent)
    }

    override fun onNewIntent(i: Intent) { super.onNewIntent(i); handleIntent(i) }

    private fun handleIntent(i: Intent?) {
        if (i?.action == "macoid.SETUP_STORAGE") {
            requestPermissions(arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE, Manifest.permission.READ_EXTERNAL_STORAGE), 1)
        }
    }

    override fun onResume() {
        super.onResume()
        Sessions.ui = this
        renderTabs()
        tv.onScreenUpdated()
    }

    override fun onBackPressed() { moveTaskToBack(true) }   // sessions keep running in the service

    override fun onDestroy() {
        if (Sessions.ui === this) Sessions.ui = null
        super.onDestroy()
    }

    // ---------------------------------------------------------------- Sessions.Ui

    override fun onScreen(s: TerminalSession) {
        if (Sessions.list.getOrNull(Sessions.current) === s) tv.onScreenUpdated()
    }
    override fun onTabs() = renderTabs()
    override fun onCurrent() = show(Sessions.current)
    override fun onEmpty() { finish() }

    // ---------------------------------------------------------------- UI

    private fun dp(v: Int) = Skin.dp(this, v)

    private fun keyLp(w: Int, weight: Float = 0f) =
        LinearLayout.LayoutParams(w, dp(40), weight).apply { setMargins(dp(2), dp(2), dp(2), dp(2)) }

    private fun buildUi() {
        window.statusBarColor = Skin.bgTop
        window.navigationBarColor = Skin.bgBottom

        val col = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = Skin.backdrop()
            setPadding(dp(8), dp(8), dp(8), dp(8))
        }

        // floating tab bar: session chips on the left, round action buttons on the right
        val bar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
            background = Skin.rounded(Skin.cSurface, dp(28).toFloat(), Skin.cEdge)
            setPadding(dp(6), dp(5), dp(6), dp(5))
        }
        tabs = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        tabScroll = HorizontalScrollView(this).apply { isHorizontalScrollBarEnabled = false; overScrollMode = View.OVER_SCROLL_NEVER; addView(tabs) }
        bar.addView(tabScroll, LinearLayout.LayoutParams(0, dp(42), 1f))
        val round = { w: Int -> LinearLayout.LayoutParams(w, dp(42)).apply { leftMargin = dp(4) } }
        bar.addView(Skin.key(this, "+", 20f, 21) { newSession(false) }, round(dp(42)))
        bar.addView(Skin.key(this, "#", 17f, 21) { newSession(true) }.also { it.setTextColor(Skin.cRoot) }, round(dp(42)))
        bar.addView(Skin.key(this, "\u22EE", 20f, 21) {}.also { b -> b.setOnClickListener { menu(b) } }, round(dp(42)))
        col.addView(bar, LinearLayout.LayoutParams(-1, -2))

        // terminal sits on its own rounded, softly outlined card
        val card = FrameLayout(this).apply {
            background = Skin.rounded(Color.BLACK, dp(24).toFloat(), Skin.cEdge)
            setClipToOutline(true)
            setPadding(dp(10), dp(8), dp(10), dp(6))
        }
        tv = TerminalView(this, null).apply { isFocusable = true; isFocusableInTouchMode = true }
        tv.setTerminalViewClient(viewClient)
        tv.setTextSize(dp(fontDp))
        card.addView(tv, FrameLayout.LayoutParams(-1, -1))
        col.addView(card, LinearLayout.LayoutParams(-1, 0, 1f).apply { topMargin = dp(8) })

        // extra keys live on a floating panel
        val keys = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = Skin.rounded(Skin.cSurface, dp(26).toFloat(), Skin.cEdge)
            setPadding(dp(5), dp(4), dp(5), dp(4))
        }

        val r1 = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        r1.addView(Skin.key(this, "ESC") { sendText("\u001b", raw = true) }, keyLp(0, 1f))
        r1.addView(Skin.key(this, "TAB") { sendText("\t", raw = true) }, keyLp(0, 1f))
        ctrlBtn = Skin.key(this, "CTRL") { ctrl = !ctrl; updateMods() }
        altBtn = Skin.key(this, "ALT") { alt = !alt; updateMods() }
        r1.addView(ctrlBtn, keyLp(0, 1f)); r1.addView(altBtn, keyLp(0, 1f))
        r1.addView(Skin.key(this, "\u2190", 16f) { sendKey(KeyEvent.KEYCODE_DPAD_LEFT) }, keyLp(0, 1f))
        r1.addView(Skin.key(this, "\u2193", 16f) { sendKey(KeyEvent.KEYCODE_DPAD_DOWN) }, keyLp(0, 1f))
        r1.addView(Skin.key(this, "\u2191", 16f) { sendKey(KeyEvent.KEYCODE_DPAD_UP) }, keyLp(0, 1f))
        r1.addView(Skin.key(this, "\u2192", 16f) { sendKey(KeyEvent.KEYCODE_DPAD_RIGHT) }, keyLp(0, 1f))
        keys.addView(r1, LinearLayout.LayoutParams(-1, -2))

        val r2 = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        r2.addView(Skin.key(this, "HOME") { sendKey(KeyEvent.KEYCODE_MOVE_HOME) }, keyLp(-2))
        r2.addView(Skin.key(this, "END") { sendKey(KeyEvent.KEYCODE_MOVE_END) }, keyLp(-2))
        r2.addView(Skin.key(this, "PGUP") { sendKey(KeyEvent.KEYCODE_PAGE_UP) }, keyLp(-2))
        r2.addView(Skin.key(this, "PGDN") { sendKey(KeyEvent.KEYCODE_PAGE_DOWN) }, keyLp(-2))
        "/ - | ~ $ * ' \" \\ ; = & < > _ . : ! # % ^ @ ` , ( ) { } [ ] +".split(" ").forEach { k ->
            r2.addView(Skin.key(this, k, 15f) { sendText(k) }, keyLp(dp(40)))
        }
        keys.addView(HorizontalScrollView(this).apply {
            isHorizontalScrollBarEnabled = false; overScrollMode = View.OVER_SCROLL_NEVER; addView(r2)
        }, LinearLayout.LayoutParams(-1, -2))
        col.addView(keys, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(8) })

        setContentView(col)
        updateMods()
    }

    private fun renderTabs() {
        tabs.removeAllViews()
        Sessions.list.forEachIndexed { i, s ->
            val root = Sessions.isRoot(s)
            val title = s.title?.takeIf { it.isNotBlank() }?.let { ": " + it.take(14) } ?: ""
            val active = i == Sessions.current
            val tone = if (root) Skin.cRoot else Skin.cAccent
            val t = TextView(this).apply {
                text = (i + 1).toString() + (if (root) " #" else " \$") + title
                textSize = 13f; gravity = Gravity.CENTER; typeface = Skin.medium
                setTextColor(if (active) Skin.cOnAccent else if (root) Skin.cRoot else Skin.cMuted)
                setPadding(dp(16), 0, dp(16), 0)
                background = Skin.ripple(Skin.rounded(if (active) tone else Skin.cKey, dp(21).toFloat()))
                setOnClickListener { Sessions.current = i; show(i) }
                setOnLongClickListener { confirmClose(s); true }
            }
            tabs.addView(t, LinearLayout.LayoutParams(-2, dp(42)).apply { setMargins(dp(2), 0, dp(2), 0) })
        }
        main.post { tabScroll.fullScroll(View.FOCUS_RIGHT) }
    }

    private fun show(i: Int) {
        if (Sessions.list.isEmpty()) return
        Sessions.current = i.coerceIn(0, Sessions.list.size - 1)
        tv.attachSession(Sessions.list[Sessions.current])
        tv.onScreenUpdated()
        tv.requestFocus()
        renderTabs()
    }

    private fun cur(): TerminalSession? = Sessions.list.getOrNull(Sessions.current)

    private fun newSession(root: Boolean) {
        if (Sessions.create(root) == null) {
            Toast.makeText(this, "su not found - this device is not rooted (Magisk / KernelSU / APatch)", Toast.LENGTH_LONG).show()
        }
    }

    private fun confirmClose(s: TerminalSession) {
        Skin.dialog(this, "Close this session?",
            Skin.Act("Cancel"),
            Skin.Act("Close", Skin.DANGER) { Sessions.remove(s) })
    }

    private fun menu(anchor: View) {
        Skin.popup(this, anchor, listOf(
            Skin.Item("Paste") { Sessions.paste(cur()) },
            Skin.Item("New session", divider = true) { newSession(false) },
            Skin.Item("New root session (su)") { newSession(true) },
            Skin.Item("Close this session") { cur()?.let { s -> Sessions.remove(s) } },
            Skin.Item("Font bigger", divider = true) { zoom(true) },
            Skin.Item("Font smaller") { zoom(false) },
            Skin.Item(if (TerminalService.wakeHeld()) "Wake lock: turn off" else "Wake lock: turn on", divider = true) { TerminalService.toggleWake(this) },
            Skin.Item("Check root access") { checkRoot() },
            Skin.Item("Exit (close all sessions)", danger = true, divider = true) { Sessions.closeAll() }
        ))
    }

    private fun checkRoot() {
        Toast.makeText(this, "Checking root (approve the su prompt if one appears)...", Toast.LENGTH_SHORT).show()
        Thread {
            val (code, out) = RootUtil.check()
            runOnUiThread {
                val msg = if (code == 0) "Root OK: " + out.trim() else "No root access: " + out.trim()
                Toast.makeText(this, msg, Toast.LENGTH_LONG).show()
            }
        }.start()
    }

    // ---------------------------------------------------------------- keys

    private fun zoom(bigger: Boolean) {
        fontDp = (fontDp + if (bigger) 1 else -1).coerceIn(8, 32)
        prefs.edit().putInt("font", fontDp).apply()
        tv.setTextSize(dp(fontDp))
    }

    private fun showKeyboard() {
        val imm = getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager
        imm.showSoftInput(tv, InputMethodManager.SHOW_IMPLICIT)
    }

    private fun readMod(isCtrl: Boolean): Boolean {
        val v = if (isCtrl) ctrl else alt
        if (v) {
            if (isCtrl) ctrl = false else alt = false
            main.post { updateMods() }
        }
        return v
    }

    private fun updateMods() {
        Skin.styleKey(this, ctrlBtn, ctrl)
        Skin.styleKey(this, altBtn, alt)
    }

    /** Arrows / Home / End / PgUp / PgDn go through the terminal view so application-cursor mode (vim, less, ...) is respected. */
    private fun sendKey(code: Int) {
        val now = SystemClock.uptimeMillis()
        tv.onKeyDown(code, KeyEvent(now, now, KeyEvent.ACTION_DOWN, code, 0))
        tv.onKeyUp(code, KeyEvent(now, now, KeyEvent.ACTION_UP, code, 0))
        ctrl = false; alt = false; updateMods()
    }

    /** Literal text from the extra-key row, honouring the CTRL / ALT toggles. */
    private fun sendText(s: String, raw: Boolean = false) {
        val sess = cur() ?: return
        var t = s
        if (!raw && ctrl && s.length == 1) {
            val c = s[0]
            val code = when {
                c in 'a'..'z' -> c - 'a' + 1
                c in 'A'..'Z' -> c - 'A' + 1
                c in '@'..'_' -> c - '@'
                c == '?' -> 127
                else -> -1
            }
            if (code >= 0) t = code.toChar().toString()
        }
        if (alt) t = "\u001b" + t
        sess.write(t)
        ctrl = false; alt = false; updateMods()
    }
}
