package com.macoid.terminal

import android.app.Dialog
import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.View
import android.view.ViewGroup
import android.view.Window
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.PopupWindow
import android.widget.TextView

/**
 * Shared look for Macoid: deep graphite backdrop, soft floating panels, pill-shaped chips and keys.
 * Everything is drawn in code (no XML resources), so it works with the existing project layout.
 */
object Skin {
    // palette
    val bgTop = 0xFF16171F.toInt()      // backdrop, top of the gradient
    val bgBottom = 0xFF0B0C10.toInt()   // backdrop, bottom of the gradient
    val cSurface = 0xFF1B1D27.toInt()   // floating panels (tab bar, key panel)
    val cSurfaceHi = 0xFF242736.toInt() // dialogs and menus sit one step higher
    val cKey = 0xFF2A2D3E.toInt()       // idle keys and chips
    val cText = 0xFFE8EAF2.toInt()
    val cMuted = 0xFF9EA3B8.toInt()
    val cAccent = 0xFF8FA8FF.toInt()    // normal session / primary action
    val cRoot = 0xFFFF8478.toInt()      // root session / destructive action
    val cOnAccent = 0xFF0C0D14.toInt()  // text drawn on top of accent or root fills
    val cEdge = 0x14FFFFFF              // 8% white hairline around panels

    fun dp(c: Context, v: Int): Int = (v * c.resources.displayMetrics.density).toInt()

    fun rounded(color: Int, radius: Float, edge: Int = 0): GradientDrawable = GradientDrawable().apply {
        setShape(GradientDrawable.RECTANGLE)
        cornerRadius = radius
        setColor(color)
        if (edge != 0) setStroke(1, edge)
    }

    fun backdrop(): GradientDrawable =
        GradientDrawable(GradientDrawable.Orientation.TOP_BOTTOM, intArrayOf(bgTop, bgBottom))

    fun ripple(content: Drawable): RippleDrawable =
        RippleDrawable(ColorStateList.valueOf(0x30FFFFFF), content, null)

    val medium: Typeface get() = Typeface.create("sans-serif-medium", Typeface.NORMAL)

    /** Paint a key / chip as idle or active. */
    fun styleKey(c: Context, t: TextView, on: Boolean, radius: Int = 14) {
        t.background = ripple(rounded(if (on) cAccent else cKey, dp(c, radius).toFloat()))
        t.setTextColor(if (on) cOnAccent else cText)
    }

    /** A rounded key. Not focusable, so the terminal keeps the keyboard focus while it is tapped. */
    fun key(c: Context, label: String, size: Float = 13f, radius: Int = 14, onClick: () -> Unit): TextView =
        TextView(c).apply {
            text = label
            textSize = size
            gravity = Gravity.CENTER
            typeface = medium
            setPadding(dp(c, 10), 0, dp(c, 10), 0)
            isClickable = true
            isFocusable = false
            styleKey(c, this, false, radius)
            setOnClickListener { performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP); onClick() }
        }

    // ------------------------------------------------------------------ dialog

    const val GHOST = 0
    const val PRIMARY = 1
    const val DANGER = 2

    class Act(val label: String, val kind: Int = GHOST, val run: () -> Unit = {})

    /** Rounded replacement for AlertDialog: a message and up to three buttons. */
    fun dialog(c: Context, message: String, vararg acts: Act) {
        val d = Dialog(c)
        d.requestWindowFeature(Window.FEATURE_NO_TITLE)

        val box = LinearLayout(c).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(c, 24), dp(c, 24), dp(c, 14), dp(c, 14))
            background = rounded(cSurfaceHi, dp(c, 28).toFloat(), cEdge)
        }
        box.addView(TextView(c).apply {
            text = message; textSize = 16f; setTextColor(cText); setLineSpacing(0f, 1.15f)
            setPadding(0, 0, dp(c, 10), 0)
        })

        val row = LinearLayout(c).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.END }
        acts.forEach { a ->
            val fill = when (a.kind) { PRIMARY -> cAccent; DANGER -> cRoot; else -> Color.TRANSPARENT }
            row.addView(TextView(c).apply {
                text = a.label; textSize = 14f; typeface = medium; gravity = Gravity.CENTER
                setTextColor(if (a.kind == GHOST) cMuted else cOnAccent)
                setPadding(dp(c, 18), 0, dp(c, 18), 0)
                background = ripple(rounded(fill, dp(c, 20).toFloat()))
                isClickable = true
                setOnClickListener { d.dismiss(); a.run() }
            }, LinearLayout.LayoutParams(-2, dp(c, 40)).apply { leftMargin = dp(c, 4) })
        }
        box.addView(row, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(c, 18) })

        d.setContentView(box)
        d.window?.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
        d.show()
        val w = (c.resources.displayMetrics.widthPixels * 0.88).toInt().coerceAtMost(dp(c, 420))
        d.window?.setLayout(w, ViewGroup.LayoutParams.WRAP_CONTENT)
    }

    // ------------------------------------------------------------------ popup menu

    class Item(val label: String, val danger: Boolean = false, val divider: Boolean = false, val run: () -> Unit)

    /** Floating rounded menu anchored to the right edge of [anchor]. */
    fun popup(c: Context, anchor: View, items: List<Item>) {
        val pad = dp(c, 12)   // room around the card so its shadow is not clipped
        val card = LinearLayout(c).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(c, 6), dp(c, 6), dp(c, 6), dp(c, 6))
            background = rounded(cSurfaceHi, dp(c, 22).toFloat(), cEdge)
            elevation = dp(c, 10).toFloat()
        }
        val wrap = FrameLayout(c).apply { setPadding(pad, pad, pad, pad); addView(card) }
        val pw = PopupWindow(wrap, dp(c, 248) + pad * 2, ViewGroup.LayoutParams.WRAP_CONTENT, true)
        pw.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
        pw.isOutsideTouchable = true

        items.forEach { it0 ->
            if (it0.divider) {
                card.addView(View(c).apply { setBackgroundColor(cEdge) },
                    LinearLayout.LayoutParams(-1, 1).apply { setMargins(dp(c, 10), dp(c, 4), dp(c, 10), dp(c, 4)) })
            }
            card.addView(TextView(c).apply {
                text = it0.label; textSize = 15f; gravity = Gravity.CENTER_VERTICAL
                setTextColor(if (it0.danger) cRoot else cText)
                setPadding(dp(c, 14), 0, dp(c, 14), 0)
                background = ripple(rounded(Color.TRANSPARENT, dp(c, 16).toFloat()))
                isClickable = true
                setOnClickListener { pw.dismiss(); it0.run() }
            }, LinearLayout.LayoutParams(-1, dp(c, 46)))
        }
        pw.showAsDropDown(anchor, pad, 0, Gravity.END)
    }
}
