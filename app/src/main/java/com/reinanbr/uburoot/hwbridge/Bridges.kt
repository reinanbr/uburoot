// SPDX-License-Identifier: GPL-3.0-or-later
package com.reinanbr.uburoot.hwbridge

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.ImageFormat
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CameraMetadata
import android.hardware.camera2.CaptureRequest
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.location.OnNmeaMessageListener
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.ImageReader
import android.media.MediaRecorder
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.Size
import java.io.IOException
import java.util.Locale
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.abs
import kotlin.math.max

/** What each bridge answers. Each request runs on its own thread and may block. */
object Bridges {
    fun handle(ctx: Context, name: String, r: BridgeRequest) = when (name) {
        "audio" -> audio(ctx, r)
        "camera" -> camera(ctx, r)
        "sensors" -> sensors(ctx, r)
        "location" -> location(ctx, r)
        else -> r.err("unknown bridge")
    }

    private fun granted(ctx: Context, perm: String) = ctx.checkSelfPermission(perm) == PackageManager.PERMISSION_GRANTED

    /** Hands queued items to [write] until the client hangs up or nothing comes for [idleSec]. */
    private fun <T> pump(r: BridgeRequest, q: LinkedBlockingQueue<T>, idleSec: Int, write: (T) -> Unit) {
        val gone = AtomicBoolean(false)
        r.onHangup { gone.set(true) }
        var idle = 0
        while (!gone.get()) {
            val item = q.poll(1, TimeUnit.SECONDS)
            if (item == null) {
                if (idleSec > 0 && ++idle >= idleSec) return
                continue
            }
            idle = 0
            write(item)
        }
    }

    // ---- audio: raw s16le PCM ----

    private fun audio(ctx: Context, r: BridgeRequest) {
        val rate = r.args.getOrNull(0)?.toIntOrNull()?.takeIf { it in 8000..192000 } ?: return r.err("bad rate")
        val ch = r.args.getOrNull(1)?.toIntOrNull()?.takeIf { it == 1 || it == 2 }
            ?: return r.err("channels must be 1 or 2")
        when (r.cmd) {
            "play" -> play(r, rate, ch)
            "record" -> record(ctx, r, rate, ch)
            else -> r.err("unknown command: ${r.cmd}")
        }
    }

    private fun play(r: BridgeRequest, rate: Int, ch: Int) {
        val mask = if (ch == 1) AudioFormat.CHANNEL_OUT_MONO else AudioFormat.CHANNEL_OUT_STEREO
        val min = AudioTrack.getMinBufferSize(rate, mask, AudioFormat.ENCODING_PCM_16BIT)
        if (min <= 0) return r.err("the phone can't play $rate Hz")
        val track = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build(),
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setSampleRate(rate)
                    .setChannelMask(mask)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .build(),
            )
            .setBufferSizeInBytes(max(min * 2, 32768))
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
        try {
            if (track.state != AudioTrack.STATE_INITIALIZED) return r.err("cannot open the audio output")
            r.ok()
            track.play()
            val frame = 2 * ch
            val buf = ByteArray(16384)
            var have = 0
            var frames = 0L
            while (true) {
                val n = r.input.read(buf, have, buf.size - have)
                if (n < 0) break
                have += n
                val whole = have - have % frame
                var off = 0
                while (off < whole) {
                    val w = track.write(buf, off, whole - off)
                    if (w < 0) throw IOException("AudioTrack.write: $w")
                    off += w
                }
                frames += whole / frame
                System.arraycopy(buf, whole, buf, 0, have - whole)
                have -= whole
            }
            // Wait for the buffered tail to play (the position stops moving at the end).
            val target = frames and 0xffffffffL
            var last = -1L
            var still = 0
            while (still < 15) {
                val pos = track.playbackHeadPosition.toLong() and 0xffffffffL
                if (pos == target) break
                if (pos == last) still++ else still = 0
                last = pos
                Thread.sleep(20)
            }
            track.stop()
        } finally {
            track.release()
        }
    }

    @SuppressLint("MissingPermission")
    private fun record(ctx: Context, r: BridgeRequest, rate: Int, ch: Int) {
        if (!granted(ctx, Manifest.permission.RECORD_AUDIO)) {
            return r.err("UbuRoot has no microphone permission: turn the audio bridge off and on again")
        }
        val mask = if (ch == 1) AudioFormat.CHANNEL_IN_MONO else AudioFormat.CHANNEL_IN_STEREO
        val min = AudioRecord.getMinBufferSize(rate, mask, AudioFormat.ENCODING_PCM_16BIT)
        if (min <= 0) return r.err("the microphone can't record $rate Hz")
        val rec =
            AudioRecord(MediaRecorder.AudioSource.MIC, rate, mask, AudioFormat.ENCODING_PCM_16BIT, max(min * 2, 32768))
        try {
            if (rec.state != AudioRecord.STATE_INITIALIZED) return r.err("cannot open the microphone")
            rec.startRecording()
            if (rec.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
                return r.err("the microphone is busy (another app records)")
            }
            r.ok()
            val buf = ByteArray(8192)
            while (true) {
                val n = rec.read(buf, 0, buf.size)
                if (n < 0) throw IOException("AudioRecord.read: $n")
                r.out.write(buf, 0, n)
            }
        } finally {
            runCatching { rec.stop() }
            rec.release()
        }
    }

    // ---- camera: Camera2 → JPEG frames ----

    private fun jpegSizes(c: CameraCharacteristics): List<Size> =
        c.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            ?.getOutputSizes(ImageFormat.JPEG)
            ?.sortedByDescending { it.width.toLong() * it.height }
            .orEmpty()

    /**
     * Some HALs hand over the whole JPEG buffer, padding included: on the S9 the front
     * camera's 640x480 frames came as ~1.6 MB, zeros after the image. Cut after the
     * last EOI marker (FF D9); the padding has none.
     */
    internal fun jpegOnly(a: ByteArray): ByteArray {
        val n = a.size
        if (n >= 2 && a[n - 2] == 0xFF.toByte() && a[n - 1] == 0xD9.toByte()) return a
        for (i in n - 2 downTo 2) {
            if (a[i] == 0xFF.toByte() && a[i + 1] == 0xD9.toByte()) return a.copyOf(i + 2)
        }
        return a
    }

    private fun camera(ctx: Context, r: BridgeRequest) {
        val cm = ctx.getSystemService(CameraManager::class.java)
        when (r.cmd) {
            "list" -> {
                val text = cm.cameraIdList.joinToString("") { id ->
                    val c = cm.getCameraCharacteristics(id)
                    val facing = when (c.get(CameraCharacteristics.LENS_FACING)) {
                        CameraMetadata.LENS_FACING_FRONT -> "front"
                        CameraMetadata.LENS_FACING_BACK -> "back"
                        else -> "external"
                    }
                    "$id $facing ${jpegSizes(c).take(12).joinToString(",") { "${it.width}x${it.height}" }}\n"
                }
                r.ok()
                r.out.write(text.toByteArray())
            }

            "snap", "mjpeg" -> capture(ctx, cm, r, r.cmd == "mjpeg")

            else -> r.err("unknown command: ${r.cmd}")
        }
    }

    @SuppressLint("MissingPermission")
    private fun capture(ctx: Context, cm: CameraManager, r: BridgeRequest, stream: Boolean) {
        if (!granted(ctx, Manifest.permission.CAMERA)) {
            return r.err("UbuRoot has no camera permission: turn the camera bridge off and on again")
        }
        val id = r.args.getOrNull(0) ?: "0"
        if (id !in cm.cameraIdList) return r.err("no camera $id (uburoot-camera list)")
        val sizes = jpegSizes(cm.getCameraCharacteristics(id))
        if (sizes.isEmpty()) return r.err("camera $id has no JPEG output")
        val want = r.args.getOrNull(1)?.split('x')?.mapNotNull { it.toIntOrNull() }
        val area = if (want?.size == 2) want[0].toLong() * want[1] else 1280L * 720
        val size = sizes.firstOrNull { want?.size == 2 && it.width == want[0] && it.height == want[1] }
            ?: sizes.minBy { abs(it.width.toLong() * it.height - area) }

        val ht = HandlerThread("bridge-camera").apply { start() }
        val h = Handler(ht.looper)
        val frames = LinkedBlockingQueue<ByteArray>(2)
        val dead = AtomicBoolean(false)
        val reader = ImageReader.newInstance(size.width, size.height, ImageFormat.JPEG, 3)
        reader.setOnImageAvailableListener({ rd ->
            rd.acquireLatestImage()?.use { img ->
                val b = img.planes[0].buffer
                val a = jpegOnly(ByteArray(b.remaining()).also { b.get(it) })
                if (!frames.offer(a)) {
                    frames.poll()
                    frames.offer(a)
                }
            }
        }, h)
        var device: CameraDevice? = null
        var session: CameraCaptureSession? = null
        try {
            val opened = LinkedBlockingQueue<Any>(1)
            cm.openCamera(
                id,
                object : CameraDevice.StateCallback() {
                    override fun onOpened(d: CameraDevice) {
                        opened.offer(d)
                    }

                    override fun onDisconnected(d: CameraDevice) {
                        dead.set(true)
                        d.close()
                        opened.offer("taken by another app")
                    }

                    override fun onError(d: CameraDevice, error: Int) {
                        dead.set(true)
                        d.close()
                        opened.offer("error $error")
                    }
                },
                h,
            )
            val o = opened.poll(10, TimeUnit.SECONDS) ?: return r.err("camera $id did not open")
            if (o !is CameraDevice) return r.err("camera $id: $o")
            device = o
            val configured = LinkedBlockingQueue<Any>(1)
            @Suppress("DEPRECATION") // the SessionConfiguration form needs API 28; minSdk is 26
            o.createCaptureSession(
                listOf(reader.surface),
                object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(s: CameraCaptureSession) {
                        configured.offer(s)
                    }

                    override fun onConfigureFailed(s: CameraCaptureSession) {
                        configured.offer("failed")
                    }
                },
                h,
            )
            val c = configured.poll(10, TimeUnit.SECONDS) as? CameraCaptureSession
                ?: return r.err("cannot configure camera $id")
            session = c
            val req = o.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW).apply {
                addTarget(reader.surface)
                set(CaptureRequest.CONTROL_MODE, CameraMetadata.CONTROL_MODE_AUTO)
                set(CaptureRequest.JPEG_QUALITY, (if (stream) 80 else 95).toByte())
            }.build()
            c.setRepeatingRequest(req, null, h)
            if (!stream) {
                // Frames for 1.5 s, so exposure and focus settle; the last one is the photo.
                val until = SystemClock.elapsedRealtime() + 1500
                var last: ByteArray? = null
                while (!dead.get() && (last == null || SystemClock.elapsedRealtime() < until)) {
                    last = frames.poll(10, TimeUnit.SECONDS) ?: break
                }
                if (last == null) return r.err("camera $id sent no frame")
                r.ok("${size.width}x${size.height}")
                r.out.write(last)
                return
            }
            r.ok("${size.width}x${size.height}")
            r.onHangup { dead.set(true) }
            var idle = 0
            while (!dead.get()) {
                val f = frames.poll(1, TimeUnit.SECONDS)
                if (f == null) {
                    if (++idle >= 10) break
                    continue
                }
                idle = 0
                r.out.write(f)
            }
        } finally {
            runCatching { session?.close() }
            runCatching { device?.close() }
            reader.close()
            ht.quitSafely()
        }
    }

    // ---- sensors: SensorManager ----

    /** "android.sensor.accelerometer" → "accelerometer". */
    private fun key(s: Sensor) = s.stringType.substringAfterLast('.').ifEmpty { "type${s.type}" }

    private fun sensors(ctx: Context, r: BridgeRequest) {
        val sm = ctx.getSystemService(SensorManager::class.java)
        val all = sm.getSensorList(Sensor.TYPE_ALL)
        if (r.cmd == "list") {
            r.ok()
            val text = all.joinToString("") {
                "${key(it)}\t${it.name}\t${it.vendor}" + (if (it.isWakeUpSensor) "\twakeup" else "") + "\n"
            }
            r.out.write(text.toByteArray())
            return
        }
        if (r.cmd != "read" && r.cmd != "stream") return r.err("unknown command: ${r.cmd}")
        val q = r.args.getOrNull(0) ?: return r.err("which sensor? (uburoot-sensors list)")
        val s = all.firstOrNull { key(it) == q && !it.isWakeUpSensor }
            ?: all.firstOrNull { key(it) == q }
            ?: all.firstOrNull { it.name.equals(q, ignoreCase = true) }
            ?: return r.err("no sensor $q (uburoot-sensors list)")
        // Above 200 Hz Android 12+ wants HIGH_SAMPLING_RATE_SENSORS.
        val hz = r.args.getOrNull(1)?.toIntOrNull()?.coerceIn(1, 200) ?: 10
        val events = LinkedBlockingQueue<String>(512)
        val listener = object : SensorEventListener {
            override fun onSensorChanged(e: SensorEvent) {
                events.offer("${e.timestamp} ${e.values.joinToString(" ")}\n")
            }

            override fun onAccuracyChanged(sensor: Sensor, accuracy: Int) = Unit
        }
        val ht = HandlerThread("bridge-sensors").apply { start() }
        try {
            if (!sm.registerListener(listener, s, 1_000_000 / hz, Handler(ht.looper))) return r.err("cannot read $q")
            if (r.cmd == "read") {
                val e = events.poll(10, TimeUnit.SECONDS)
                    ?: return r.err("no reading from $q in 10 s (some sensors report only on a change)")
                r.ok()
                r.out.write(e.toByteArray())
            } else {
                r.ok(s.name)
                pump(r, events, 0) { r.out.write(it.toByteArray()) }
            }
        } finally {
            sm.unregisterListener(listener)
            ht.quitSafely()
        }
    }

    // ---- location: LocationManager (GNSS NMEA, one fix) ----

    @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
    private class Listener(val onFix: (Location) -> Unit) : LocationListener {
        override fun onLocationChanged(location: Location) = onFix(location)

        // Abstract before API 30: implemented so older Androids find them.
        override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) = Unit
        override fun onProviderEnabled(provider: String) = Unit
        override fun onProviderDisabled(provider: String) = Unit
    }

    @SuppressLint("MissingPermission")
    private fun location(ctx: Context, r: BridgeRequest) {
        if (!granted(ctx, Manifest.permission.ACCESS_FINE_LOCATION)) {
            return r.err("UbuRoot has no location permission: turn the location bridge off and on again")
        }
        val lm = ctx.getSystemService(LocationManager::class.java)
        val ht = HandlerThread("bridge-location").apply { start() }
        try {
            when (r.cmd) {
                "nmea" -> {
                    if (!lm.isProviderEnabled(LocationManager.GPS_PROVIDER)) {
                        return r.err("location (GPS) is off in Android's settings")
                    }
                    val lines = LinkedBlockingQueue<String>(512)
                    val nmea = OnNmeaMessageListener { msg, _ -> lines.offer(msg.trimEnd() + "\r\n") }
                    // NMEA flows only while someone asks for positions.
                    val keepOn = Listener {}
                    lm.addNmeaListener(nmea, Handler(ht.looper))
                    lm.requestLocationUpdates(LocationManager.GPS_PROVIDER, 1000L, 0f, keepOn, ht.looper)
                    try {
                        r.ok()
                        pump(r, lines, 0) { r.out.write(it.toByteArray()) }
                    } finally {
                        lm.removeNmeaListener(nmea)
                        lm.removeUpdates(keepOn)
                    }
                }

                "fix" -> {
                    val provider = listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)
                        .firstOrNull { it in lm.allProviders && lm.isProviderEnabled(it) }
                        ?: return r.err("location is off in Android's settings")
                    val fixes = LinkedBlockingQueue<Location>(1)
                    val l = Listener { fixes.offer(it) }
                    lm.requestLocationUpdates(provider, 0L, 0f, l, ht.looper)
                    try {
                        val f = fixes.poll(90, TimeUnit.SECONDS)
                            ?: return r.err("no position in 90 s from $provider (GNSS needs the open sky)")
                        r.ok()
                        val line = String.format(
                            Locale.ROOT,
                            "%.7f %.7f %.1f %.1f %d %s\n",
                            f.latitude,
                            f.longitude,
                            f.altitude,
                            f.accuracy,
                            f.time,
                            provider,
                        )
                        r.out.write(line.toByteArray())
                    } finally {
                        lm.removeUpdates(l)
                    }
                }

                else -> r.err("unknown command: ${r.cmd}")
            }
        } finally {
            ht.quitSafely()
        }
    }
}
