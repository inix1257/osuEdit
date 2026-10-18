package com.osuedit.osu_edit

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTimestamp
import android.media.AudioTrack
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * The editor's audio session over the `osuedit/audio` channel: while the
 * editor plays (Dart calls `acquire` / `release`) it holds audio focus and
 * listens for headphones being unplugged. Losing focus (a call, another app
 * playing) or "becoming noisy" is reported to Dart as `interrupted` with the
 * reason, and Dart pauses. Ducking requests (notification sounds) are left
 * to the system; focus coming back does not resume (an editor shouldn't
 * start playing by itself).
 */
class AudioSession(private val context: Context, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "osuedit/audio")
    private val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private var held = false

    private val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
        when (change) {
            AudioManager.AUDIOFOCUS_LOSS, AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> interrupted("focusLoss")
        }
    }

    /** Headphones unplugged / Bluetooth audio gone: sound would move to the speaker. */
    internal val noisyReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) interrupted("noisy")
        }
    }

    private val focusRequest: AudioFocusRequest? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build()
                )
                .setOnAudioFocusChangeListener(focusListener)
                .build()
        } else {
            null
        }

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "acquire" -> result.success(acquire())
                "release" -> {
                    release()
                    result.success(null)
                }
                "outputLatency" -> {
                    // Blocking writes for ~1 s: off the main thread.
                    val main = Handler(Looper.getMainLooper())
                    Thread {
                        val ms = try {
                            measureOutputLatencyMs()
                        } catch (e: Exception) {
                            android.util.Log.w("osuEdit", "Output latency measurement failed", e)
                            null
                        }
                        main.post { result.success(ms) }
                    }.start()
                }
                else -> result.notImplemented()
            }
        }
    }

    /** Takes audio focus and starts listening for unplugging. False if focus was refused (e.g. during a call). */
    fun acquire(): Boolean {
        val granted = if (focusRequest != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            audio.requestAudioFocus(focusRequest)
        } else {
            @Suppress("DEPRECATION")
            audio.requestAudioFocus(focusListener, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN)
        } == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        if (granted && !held) {
            held = true
            context.registerReceiver(noisyReceiver, IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY))
        }
        return granted
    }

    fun release() {
        if (!held) return
        held = false
        try {
            context.unregisterReceiver(noisyReceiver)
        } catch (e: IllegalArgumentException) {
            // Not registered: nothing to do.
        }
        if (focusRequest != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            audio.abandonAudioFocusRequest(focusRequest)
        } else {
            @Suppress("DEPRECATION")
            audio.abandonAudioFocus(focusListener)
        }
    }

    /**
     * The device's output latency in ms: how long a sample written to a
     * low-latency media stream takes to reach the speaker, from the
     * stream's presentation timestamps (frames written − frames presented,
     * at the moment of reading). Silence is played, so nothing is heard.
     * The median of the readings after the stream settled; null if the
     * device gave no timestamps.
     */
    private fun measureOutputLatencyMs(): Double? {
        val rate = AudioTrack.getNativeOutputSampleRate(AudioManager.STREAM_MUSIC)
        val minBytes = AudioTrack.getMinBufferSize(rate, AudioFormat.CHANNEL_OUT_STEREO, AudioFormat.ENCODING_PCM_16BIT)
        val builder = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build()
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setSampleRate(rate)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                    .build()
            )
            .setBufferSizeInBytes(minBytes)
            .setTransferMode(AudioTrack.MODE_STREAM)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            builder.setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
        }
        val track = builder.build()
        try {
            val chunk = ShortArray(256 * 2) // 256 stereo frames of silence
            val ts = AudioTimestamp()
            var written = 0L
            val readings = mutableListOf<Double>()
            track.play()
            val start = System.nanoTime()
            while (System.nanoTime() - start < 1_000_000_000L) {
                val n = track.write(chunk, 0, chunk.size)
                if (n <= 0) break
                written += n / 2
                // Skip the start-up while the stream fills.
                if (System.nanoTime() - start < 300_000_000L || !track.getTimestamp(ts)) continue
                val presentedNow = ts.framePosition + (System.nanoTime() - ts.nanoTime) * rate / 1e9
                readings.add((written - presentedNow) * 1000.0 / rate)
            }
            if (readings.isEmpty()) return null
            readings.sort()
            return readings[readings.size / 2]
        } finally {
            track.stop()
            track.release()
        }
    }

    private fun interrupted(reason: String) {
        channel.invokeMethod("interrupted", reason)
    }
}
