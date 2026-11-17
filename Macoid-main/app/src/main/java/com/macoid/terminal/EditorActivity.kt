package com.macoid.terminal

import android.app.Activity
import android.graphics.Color
import android.graphics.Typeface
import android.os.Bundle
import android.text.Editable
import android.text.InputType
import android.text.TextWatcher
import android.view.Gravity
import android.widget.FrameLayout
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import java.io.File

/** Opened by `edit` / `nano` / `vi` / `vim`. Root-aware: files the app cannot read or write go through su. */
class EditorActivity : Activity() {
    private lateinit var et: EditText
    private lateinit var path: String
    private lateinit var nameView: TextView
    private var dirty = false
    private var loaded = false

    override fun onCreate(b: Bundle?) {
        super.onCreate(b)
        path = intent.getStringExtra("path") ?: run { finish(); return }

        window.statusBarColor = Skin.bgTop
        window.navigationBarColor = Skin.bgBottom
        val dp = { v: Int -> Skin.dp(this, v) }

        val col = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = Skin.backdrop()
            setPadding(dp(8), dp(8), dp(8), dp(8))
        }

        // floating header: file name (with an unsaved dot), Close, Save
        val bar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
            background = Skin.rounded(Skin.cSurface, dp(28).toFloat(), Skin.cEdge)
            setPadding(dp(18), dp(5), dp(6), dp(5))
        }
        nameView = TextView(this).apply {
            setTextColor(Skin.cText); typeface = Typeface.MONOSPACE; textSize = 14f
            maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.MIDDLE
        }
        bar.addView(nameView, LinearLayout.LayoutParams(0, -2, 1f))
        val btnLp = { LinearLayout.LayoutParams(-2, dp(42)).apply { leftMargin = dp(4) } }
        bar.addView(Skin.key(this, "Close", 14f, 21) { onBackPressed() }.also { it.setPadding(dp(20), 0, dp(20), 0) }, btnLp())
        bar.addView(Skin.key(this, "Save", 14f, 21) { save(false) }.also {
            it.setPadding(dp(22), 0, dp(22), 0)
            Skin.styleKey(this, it, true, 21)
        }, btnLp())
        col.addView(bar, LinearLayout.LayoutParams(-1, -2))

        // text area on a rounded card
        et = EditText(this).apply {
            typeface = Typeface.MONOSPACE; textSize = 13f; setTextColor(Skin.cText)
            setBackgroundColor(Color.TRANSPARENT)
            setHighlightColor(0x558FA8FF)
            setLineSpacing(0f, 1.15f)
            gravity = Gravity.TOP or Gravity.START
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
            setHorizontallyScrolling(true)
            setPadding(dp(6), dp(4), dp(6), dp(4))
            addTextChangedListener(object : TextWatcher {
                override fun afterTextChanged(s: Editable?) { if (loaded && !dirty) { dirty = true; updateTitle() } }
                override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
                override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            })
        }
        val card = FrameLayout(this).apply {
            background = Skin.rounded(0xFF0E0F15.toInt(), dp(24).toFloat(), Skin.cEdge)
            setClipToOutline(true)
            setPadding(dp(14), dp(12), dp(14), dp(8))
            addView(et, FrameLayout.LayoutParams(-1, -1))
        }
        col.addView(card, LinearLayout.LayoutParams(-1, 0, 1f).apply { topMargin = dp(8) })
        setContentView(col)
        updateTitle()
        load()
    }

    private fun updateTitle() { nameView.text = File(path).name + if (dirty) "  \u25CF" else "" }

    private fun load() {
        Thread {
            val f = File(path)
            val txt: String? = when {
                !f.exists() -> ""
                f.length() > 2_000_000 -> null
                f.canRead() -> try { f.readText() } catch (e: Exception) { rootRead() }
                else -> rootRead()
            }
            runOnUiThread {
                if (txt == null) {
                    Toast.makeText(this, "Cannot open $path (too big, or no permission and no root)", Toast.LENGTH_LONG).show()
                    finish()
                } else { et.setText(txt); loaded = true; dirty = false; updateTitle() }
            }
        }.start()
    }

    private fun rootRead(): String? {
        val (c, o) = RootUtil.run("cat " + shq(path))
        return if (c == 0) o else null
    }

    private fun save(thenClose: Boolean) {
        val text = et.text.toString()
        Thread {
            val f = File(path)
            val msg = try {
                f.parentFile?.mkdirs(); f.writeText(text); dirty = false; "Saved"
            } catch (e: Exception) {
                val tmp = File(cacheDir, "edit.tmp")
                tmp.writeText(text)
                val (c, o) = RootUtil.run("cat " + shq(tmp.absolutePath) + " > " + shq(path))
                tmp.delete()
                if (c == 0) { dirty = false; "Saved (as root)" } else "Failed: " + o.trim().ifEmpty { e.message ?: "unknown error" }
            }
            runOnUiThread {
                updateTitle()
                Toast.makeText(this, msg, Toast.LENGTH_SHORT).show()
                if (thenClose && !dirty) finish()
            }
        }.start()
    }

    override fun onBackPressed() {
        if (!dirty) { finish(); return }
        Skin.dialog(this, "Save changes to " + File(path).name + "?",
            Skin.Act("Cancel"),
            Skin.Act("Discard", Skin.DANGER) { finish() },
            Skin.Act("Save", Skin.PRIMARY) { save(true) })
    }
}
