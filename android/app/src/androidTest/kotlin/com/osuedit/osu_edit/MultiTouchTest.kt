package com.osuedit.osu_edit

import android.content.Context
import android.content.Intent
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import androidx.test.uiautomator.By
import androidx.test.uiautomator.BySelector
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.UiObject2
import androidx.test.uiautomator.Until
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.regex.Pattern

/**
 * Real multi-finger taps on the playfield (two fingers = undo, three = redo),
 * injected through the system input pipeline with UiAutomation: adb's `input`
 * only sends one pointer, and `sendevent` is blocked by SELinux.
 *
 * Needs the "osuEdit - Sync Test" set from the device test set
 * (tool/test_set) in the app's library. Leaves the map unchanged.
 *
 * The runner classes ship in the *debug* app (integration_test pulls them
 * in), so the debug build must be installed. Debug and release are signed
 * with the same key, so `install -r` swaps them and keeps the app's data:
 *   flutter build apk --debug
 *   adb install -r build/app/outputs/flutter-apk/app-debug.apk
 *   cd android && ./gradlew :app:assembleDebugAndroidTest && cd ..
 *   adb install -r -t build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk
 *   adb shell am instrument -w com.osuedit.osu_edit.test/androidx.test.runner.AndroidJUnitRunner
 *   adb install -r build/app/outputs/flutter-apk/app-release.apk   # back to release
 * Don't use `connectedAndroidTest`: it uninstalls the app, and with it the
 * library.
 */
@RunWith(AndroidJUnit4::class)
class MultiTouchTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val device = UiDevice.getInstance(instrumentation)

    /**
     * Flutter exposes labels as content descriptions (sometimes as text).
     * Row labels span lines ("title
subtitle"), which `descContains` can't
     * match (its pattern has no DOTALL), hence the explicit pattern.
     */
    private fun find(label: String, timeout: Long = 10_000): UiObject2? {
        val pattern = Pattern.compile(".*" + Pattern.quote(label) + ".*", Pattern.DOTALL)
        val deadline = SystemClock.uptimeMillis() + timeout
        while (SystemClock.uptimeMillis() < deadline) {
            for (sel: BySelector in listOf(By.desc(pattern), By.text(pattern))) {
                device.findObject(sel)?.let { return it }
            }
            SystemClock.sleep(200)
        }
        return null
    }

    private fun need(label: String): UiObject2 = find(label) ?: error("\"$label\" not on screen; seen: ${seen()}")

    /** Every label currently exposed, for failure messages. */
    private fun seen(): List<String> =
        device.findObjects(By.pkg(instrumentation.targetContext.packageName))
            .mapNotNull { it.contentDescription ?: it.text }
            .filter { it.isNotBlank() }

    /** Taps with [n] fingers around the screen centre (inside the playfield). */
    private fun multiTap(n: Int) {
        val cx = device.displayWidth / 2f
        val cy = device.displayHeight / 2f
        val props = Array(n) { i ->
            MotionEvent.PointerProperties().apply {
                id = i
                toolType = MotionEvent.TOOL_TYPE_FINGER
            }
        }
        val coords = Array(n) { i ->
            MotionEvent.PointerCoords().apply {
                x = cx + (i - (n - 1) / 2f) * 90f
                y = cy
                pressure = 1f
                size = 1f
            }
        }
        val down = SystemClock.uptimeMillis()
        fun send(time: Long, action: Int, count: Int) {
            val ev = MotionEvent.obtain(
                down, time, action, count, props, coords,
                0, 0, 1f, 1f, 0, 0, InputDevice.SOURCE_TOUCHSCREEN, 0,
            )
            assertTrue("inject $action", instrumentation.uiAutomation.injectInputEvent(ev, true))
            ev.recycle()
        }
        val shift = MotionEvent.ACTION_POINTER_INDEX_SHIFT
        send(down, MotionEvent.ACTION_DOWN, 1)
        for (i in 1 until n) send(down + 10L * i, MotionEvent.ACTION_POINTER_DOWN or (i shl shift), i + 1)
        val up = down + 80
        for (i in n - 1 downTo 1) send(up + 10L * (n - 1 - i), MotionEvent.ACTION_POINTER_UP or (i shl shift), i + 1)
        send(up + 10L * n, MotionEvent.ACTION_UP, 1)
        SystemClock.sleep(600)
    }

    /** Two fingers around the screen centre move from [from] to [to] px apart. */
    private fun pinch(from: Float, to: Float, steps: Int = 12) {
        val cx = device.displayWidth / 2f
        val cy = device.displayHeight / 2f
        val props = Array(2) { i ->
            MotionEvent.PointerProperties().apply {
                id = i
                toolType = MotionEvent.TOOL_TYPE_FINGER
            }
        }
        val coords = Array(2) { MotionEvent.PointerCoords().apply { pressure = 1f; size = 1f; y = cy } }
        fun spread(d: Float) {
            coords[0].x = cx - d / 2
            coords[1].x = cx + d / 2
        }
        val down = SystemClock.uptimeMillis()
        var time = down
        fun send(action: Int, count: Int) {
            val ev = MotionEvent.obtain(
                down, time, action, count, props, coords,
                0, 0, 1f, 1f, 0, 0, InputDevice.SOURCE_TOUCHSCREEN, 0,
            )
            assertTrue("inject $action", instrumentation.uiAutomation.injectInputEvent(ev, true))
            ev.recycle()
        }
        val shift = MotionEvent.ACTION_POINTER_INDEX_SHIFT
        spread(from)
        send(MotionEvent.ACTION_DOWN, 1)
        time += 10
        send(MotionEvent.ACTION_POINTER_DOWN or (1 shl shift), 2)
        for (i in 1..steps) {
            time += 16
            spread(from + (to - from) * i / steps)
            send(MotionEvent.ACTION_MOVE, 2)
        }
        time += 10
        send(MotionEvent.ACTION_POINTER_UP or (1 shl shift), 2)
        time += 10
        send(MotionEvent.ACTION_UP, 1)
        SystemClock.sleep(600)
    }

    /** The zoom pill ("3.0×"; not the toolbox's "Dist 1.0×"), or null. */
    private fun zoomPill(timeout: Long = 3_000): UiObject2? {
        val pattern = Pattern.compile("""\d+\.\d×.*""", Pattern.DOTALL)
        val deadline = SystemClock.uptimeMillis() + timeout
        while (SystemClock.uptimeMillis() < deadline) {
            for (sel: BySelector in listOf(By.desc(pattern), By.text(pattern))) {
                device.findObject(sel)?.let { return it }
            }
            SystemClock.sleep(200)
        }
        return null
    }

    /** Saved where `adb pull` can reach: /sdcard/Android/data/<app>/files/. */
    private fun screenshot(name: String) {
        val dir = instrumentation.targetContext.getExternalFilesDir(null)!!
        device.takeScreenshot(File(dir, "$name.png"))
    }

    /**
     * Back closes the editor. The library may be scrolled (openShapes), so
     * its title can be off screen; the Import button is always there.
     */
    private fun closeEditor() {
        device.pressBack()
        assertNotNull("back in the library; seen: ${seen()}", find("Import .osz"))
    }

    private fun undoEnabled() = need("Undo").isEnabled
    private fun redoEnabled() = need("Redo").isEnabled

    private fun openShapes() {
        val context = instrumentation.targetContext
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)!!
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        context.startActivity(launch)
        device.wait(Until.hasObject(By.pkg(context.packageName).depth(0)), 10_000)
        // A debug build's first frame can take a while (JIT, asset loading).
        assertNotNull("library shown", find("Library", 30_000))

        // The set may still be expanded from an earlier run, and its
        // difficulties may be below the end of the list.
        fun scrolledTo(label: String): UiObject2? {
            repeat(4) {
                find(label, 1_000)?.let { return it }
                val w = device.displayWidth / 2
                device.swipe(w, device.displayHeight * 3 / 4, w, device.displayHeight / 4, 20)
            }
            return find(label, 1_000)
        }
        (scrolledTo("Shapes") ?: run { need("Sync Test").click(); scrolledTo("Shapes") ?: need("Shapes") }).click()
        assertNotNull("editor opened", find("Undo", 15_000))
    }

    /**
     * Pinching out zooms the playfield: the zoom pill and the 1x overview in
     * the bottom-right corner appear; tapping the overview moves the view
     * (zoom kept). Screenshots: pinch-1-zoomed, pinch-2-moved, pinch-3-reset.
     */
    @Test
    fun pinchZoomShowsOverview() {
        openShapes()
        pinch(200f, 600f)
        val pill = zoomPill() ?: error("no zoom pill; seen: ${seen()}")
        val label = pill.contentDescription ?: pill.text
        screenshot("pinch-1-zoomed")

        // Towards the overview's lower-right corner (the playfield's).
        val box = need("Zoom overview").visibleBounds
        device.click(box.left + box.width() * 4 / 5, box.top + box.height() * 4 / 5)
        SystemClock.sleep(600)
        screenshot("pinch-2-moved")
        val after = zoomPill() ?: error("zoom lost; seen: ${seen()}")
        assertTrue("zoom kept", (after.contentDescription ?: after.text) == label)
        assertFalse("no edit", undoEnabled())

        after.click()
        SystemClock.sleep(600)
        screenshot("pinch-3-reset")
        assertTrue("zoom reset", zoomPill(1_000) == null)
        assertTrue("overview gone", find("Zoom overview", 1_000) == null)
        closeEditor()
    }

    /**
     * One finger held still at ([sx], [sy]) while the other moves from
     * ([fx], [fy]) to ([tx], [ty]) in [steps] moves.
     */
    private fun pinchOneStill(sx: Float, sy: Float, fx: Float, fy: Float, tx: Float, ty: Float, steps: Int = 15) {
        val props = Array(2) { i ->
            MotionEvent.PointerProperties().apply {
                id = i
                toolType = MotionEvent.TOOL_TYPE_FINGER
            }
        }
        val coords = Array(2) { MotionEvent.PointerCoords().apply { pressure = 1f; size = 1f } }
        coords[0].x = sx
        coords[0].y = sy
        coords[1].x = fx
        coords[1].y = fy
        val down = SystemClock.uptimeMillis()
        var time = down
        fun send(action: Int, count: Int) {
            val ev = MotionEvent.obtain(
                down, time, action, count, props, coords,
                0, 0, 1f, 1f, 0, 0, InputDevice.SOURCE_TOUCHSCREEN, 0,
            )
            assertTrue("inject $action", instrumentation.uiAutomation.injectInputEvent(ev, true))
            ev.recycle()
        }
        val shift = MotionEvent.ACTION_POINTER_INDEX_SHIFT
        send(MotionEvent.ACTION_DOWN, 1)
        time += 10
        send(MotionEvent.ACTION_POINTER_DOWN or (1 shl shift), 2)
        for (i in 1..steps) {
            time += 16
            coords[1].x = fx + (tx - fx) * i / steps
            coords[1].y = fy + (ty - fy) * i / steps
            send(MotionEvent.ACTION_MOVE, 2)
            SystemClock.sleep(16)
        }
        time += 10
        send(MotionEvent.ACTION_POINTER_UP or (1 shl shift), 2)
        time += 10
        send(MotionEvent.ACTION_UP, 1)
        SystemClock.sleep(600)
    }

    /**
     * A pinch with one finger held still keeps the map under that finger:
     * compare what is at the still finger (screen centre, minus 300 px x) in
     * still-1-before and still-2-after (zoomed about 3x around it).
     */
    @Test
    fun pinchWithOneFingerStillKeepsItsPoint() {
        openShapes()
        val cx = device.displayWidth / 2f - 300
        val cy = device.displayHeight / 2f
        screenshot("still-1-before")
        pinchOneStill(cx, cy, cx + 150, cy, cx + 450, cy)
        screenshot("still-2-after")
        assertNotNull("zoomed; seen: ${seen()}", zoomPill())
        assertFalse("no edit", undoEnabled())
        zoomPill()!!.click() // back to 1x
        SystemClock.sleep(400)
        closeEditor()
    }

    /**
     * Whether the app's AudioSession holds the audio focus, i.e. the editor is
     * playing (it holds focus exactly while playing). Read from the system
     * because UiAutomator's view of the screen goes stale while the playfield
     * animates (it never becomes idle).
     */
    private fun sessionHoldsFocus(): Boolean {
        val pfd = instrumentation.uiAutomation.executeShellCommand("dumpsys audio")
        val text = android.os.ParcelFileDescriptor.AutoCloseInputStream(pfd).bufferedReader().use { it.readText() }
        val stack = text.substringAfter("Audio Focus stack entries", "").substringBefore("Notify on duck", "")
        return stack.lines().any { "AudioSession" in it && "loss: none" in it }
    }

    private fun waitFocus(held: Boolean, timeout: Long = 5_000): Boolean {
        val deadline = SystemClock.uptimeMillis() + timeout
        while (SystemClock.uptimeMillis() < deadline) {
            if (sessionHoldsFocus() == held) return true
            SystemClock.sleep(200)
        }
        return false
    }

    /** Starts playback with the Play button (the editor must be idle). */
    private fun play() {
        need("Play (Space)").click()
        assertTrue("playing (focus held)", waitFocus(true))
    }

    private fun paused() = waitFocus(false)

    /**
     * Audio interruptions pause playback: another app taking the audio focus
     * (here the test itself, as a second focus owner), and headphones being
     * unplugged (the becoming-noisy broadcast is protected, so it is handed to
     * the app's receiver directly). Screenshots: audio-1-focus, audio-2-noisy.
     */
    @Test
    fun audioInterruptionsPause() {
        openShapes()
        play()
        val am = instrumentation.context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val other = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
            .setOnAudioFocusChangeListener { }
            .build()
        assertEquals(AudioManager.AUDIOFOCUS_REQUEST_GRANTED, am.requestAudioFocus(other))
        assertTrue("paused on focus loss; seen: ${seen()}", paused())
        screenshot("audio-1-focus")
        am.abandonAudioFocusRequest(other)

        play()
        instrumentation.runOnMainSync {
            val activity = ActivityLifecycleMonitorRegistry.getInstance()
                .getActivitiesInStage(Stage.RESUMED).single() as MainActivity
            activity.audioSession!!.noisyReceiver.onReceive(activity, Intent(AudioManager.ACTION_AUDIO_BECOMING_NOISY))
        }
        assertTrue("paused on unplug; seen: ${seen()}", paused())
        screenshot("audio-2-noisy")
        assertFalse("no edit", undoEnabled())
        closeEditor()
    }

    /**
     * Two fingers around the screen centre, [radius] px from it, turned by
     * [degrees] and spread to [toRadius] in [steps] moves.
     */
    private fun twoFingerTwist(radius: Float, toRadius: Float, degrees: Float, steps: Int = 15) {
        val cx = device.displayWidth / 2f
        val cy = device.displayHeight / 2f
        val props = Array(2) { i ->
            MotionEvent.PointerProperties().apply {
                id = i
                toolType = MotionEvent.TOOL_TYPE_FINGER
            }
        }
        val coords = Array(2) { MotionEvent.PointerCoords().apply { pressure = 1f; size = 1f } }
        fun place(r: Float, a: Double) {
            coords[0].x = cx - r * Math.cos(a).toFloat()
            coords[0].y = cy - r * Math.sin(a).toFloat()
            coords[1].x = cx + r * Math.cos(a).toFloat()
            coords[1].y = cy + r * Math.sin(a).toFloat()
        }
        val down = SystemClock.uptimeMillis()
        var time = down
        fun send(action: Int, count: Int) {
            val ev = MotionEvent.obtain(
                down, time, action, count, props, coords,
                0, 0, 1f, 1f, 0, 0, InputDevice.SOURCE_TOUCHSCREEN, 0,
            )
            assertTrue("inject $action", instrumentation.uiAutomation.injectInputEvent(ev, true))
            ev.recycle()
        }
        val shift = MotionEvent.ACTION_POINTER_INDEX_SHIFT
        place(radius, 0.0)
        send(MotionEvent.ACTION_DOWN, 1)
        time += 10
        send(MotionEvent.ACTION_POINTER_DOWN or (1 shl shift), 2)
        for (i in 1..steps) {
            time += 16
            place(radius + (toRadius - radius) * i / steps, Math.toRadians(degrees * i / steps.toDouble()))
            send(MotionEvent.ACTION_MOVE, 2)
            SystemClock.sleep(16)
        }
        time += 10
        send(MotionEvent.ACTION_POINTER_UP or (1 shl shift), 2)
        time += 10
        send(MotionEvent.ACTION_UP, 1)
        SystemClock.sleep(600)
    }

    /**
     * Two fingers on the selection box rotate and scale the selection
     * (one undo step, no zoom). Screenshots: box-1-selected, box-2-twisted.
     */
    @Test
    fun twoFingersOnSelectionBoxTransform() {
        openShapes()
        need("Menu").click()
        need("Edit").click()
        need("Select all").click()
        SystemClock.sleep(600)
        screenshot("box-1-selected")
        assertFalse("nothing to undo yet", undoEnabled())
        twoFingerTwist(120f, 170f, 40f)
        screenshot("box-2-twisted")
        assertTrue("transformed: one undo step; seen: ${seen()}", undoEnabled())
        assertTrue("not zoomed", zoomPill(1_000) == null)
        need("Undo").click()
        SystemClock.sleep(400)
        assertFalse("undone in one step", undoEnabled())
        closeEditor()
    }

    /**
     * All of Shapes selected, one finger held still and the other moved
     * (positions from the instrumentation arguments sx sy fx fy tx ty, px;
     * pick them on the box in box-1-selected). Compare the box in
     * boxstill-1-before and boxstill-2-after: it should scale around the
     * still finger by the fingers' spread. Undone afterwards.
     */
    @Test
    fun twoFingersOnSelectionBoxFollowTheBox() {
        val args = InstrumentationRegistry.getArguments()
        val sx = args.getString("sx")?.toFloat() ?: return // run by name with the arguments only
        openShapes()
        need("Menu").click()
        need("Edit").click()
        need("Select all").click()
        SystemClock.sleep(600)
        screenshot("boxstill-1-before")
        pinchOneStill(
            sx, args.getString("sy")!!.toFloat(),
            args.getString("fx")!!.toFloat(), args.getString("fy")!!.toFloat(),
            args.getString("tx")!!.toFloat(), args.getString("ty")!!.toFloat(),
        )
        screenshot("boxstill-2-after")
        assertTrue("transformed; seen: ${seen()}", undoEnabled())
        need("Undo").click()
        SystemClock.sleep(400)
        assertFalse("undone in one step", undoEnabled())
        closeEditor()
    }

    /**
     * The selection box's lock button unlocks the aspect; then two fingers
     * spread side by side stretch only the width (no turn even though they
     * twist a little). One undo step; the lock is restored afterwards.
     * Screenshots: stretch-1-unlocked, stretch-2-stretched.
     */
    @Test
    fun twoFingersStretchWidthWhenUnlocked() {
        openShapes()
        need("Menu").click()
        need("Edit").click()
        need("Select all").click()
        SystemClock.sleep(600)
        need("Unlock width / height").click()
        SystemClock.sleep(400)
        assertNotNull("lock shows unlocked", find("Lock width / height", 2_000))
        screenshot("stretch-1-unlocked")
        twoFingerTwist(120f, 200f, 8f)
        screenshot("stretch-2-stretched")
        assertTrue("stretched: one undo step; seen: ${seen()}", undoEnabled())
        assertTrue("not zoomed", zoomPill(1_000) == null)
        need("Undo").click()
        SystemClock.sleep(400)
        assertFalse("undone in one step", undoEnabled())
        need("Lock width / height").click()
        SystemClock.sleep(300)
        assertNotNull("locked again", find("Unlock width / height", 2_000))
        closeEditor()
    }

    @Test
    fun twoFingerTapUndoesAndThreeFingerTapRedoes() {
        openShapes()
        assertFalse("fresh map: nothing to undo", undoEnabled())

        // One edit: a circle placed with the Circle tool.
        need("Circle").click()
        device.click(device.displayWidth / 2, device.displayHeight / 2)
        SystemClock.sleep(600)
        assertTrue("circle placed", undoEnabled())
        assertFalse(redoEnabled())

        // Two fingers: undo (and, with the Circle tool, no new circle).
        multiTap(2)
        assertFalse("two-finger tap undid the circle", undoEnabled())
        assertTrue(redoEnabled())

        // Three fingers: redo.
        multiTap(3)
        assertTrue("three-finger tap redid it", undoEnabled())
        assertFalse(redoEnabled())

        // Back to the saved state, then close the editor (no unsaved changes).
        multiTap(2)
        assertFalse(undoEnabled())
        closeEditor()
    }
}
