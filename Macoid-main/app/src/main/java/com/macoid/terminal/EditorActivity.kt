package com.macoid.terminal

import android.app.Activity
import android.app.AlertDialog
import android.graphics.Color
import android.graphics.Typeface
import android.os.Bundle
import android.text.Editable
import android.text.InputType
import android.text.TextWatcher
import android.view.Gravity
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import java.io.File

/** Opened by `edit` / `nano` / `vi` / `vim`. Root-aware: files the app cannot read or write go through su. */
class EditorActivity : Activity() {
    private lateinit var et: EditText
    private lateinit var path: String
    private var dirty = false
    private var loaded = false

    override fun onCreate(b: Bundle?) {
        super.onCreate(b)
        path = intent.getStringExtra("path") ?: run { finish(); return }

        val col = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setBackgroundColor(Color.BLACK) }
        val bar = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL; setBackgroundColor(0xFF1C1C1E.toInt()) }
        bar.addView(TextView(this).apply {
            text = File(path).name; setTextColor(Color.WHITE); typeface = Typeface.MONOSPACE; setPadding(24, 0, 0, 0)
        }, LinearLayout.LayoutParams(0, -2, 1f))
        bar.addView(Button(this).apply { text = "Save"; isAllCaps = false; setOnClickListener { save(false) } })
        bar.addView(Button(this).apply { text = "Close"; isAllCaps = false; setOnClickListener { onBackPressed() } })
        col.addView(bar, LinearLayout.LayoutParams(-1, -2))

        et = EditText(this).apply {
            typeface = Typeface.MONOSPACE; textSize = 13f; setTextColor(Color.WHITE); setBackgroundColor(Color.BLACK)
            gravity = Gravity.TOP or Gravity.START
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
            setHorizontallyScrolling(true)
            addTextChangedListener(object : TextWatcher {
                override fun afterTextChanged(s: Editable?) { if (loaded) dirty = true }
                override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
                override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            })
        }
        col.addView(et, LinearLayout.LayoutParams(-1, 0, 1f))
        setContentView(col)
        load()
    }

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
                } else { et.setText(txt); loaded = true; dirty = false }
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
                Toast.makeText(this, msg, Toast.LENGTH_SHORT).show()
                if (thenClose && !dirty) finish()
            }
        }.start()
    }

    override fun onBackPressed() {
        if (!dirty) { finish(); return }
        AlertDialog.Builder(this).setMessage("Save changes to " + File(path).name + "?")
            .setPositiveButton("Save") { _, _ -> save(true) }
            .setNegativeButton("Discard") { _, _ -> finish() }
            .setNeutralButton("Cancel", null).show()
    }
}
