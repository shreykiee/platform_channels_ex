package com.example.platform_channels_ex // CHANGE THIS TO YOUR ACTUAL PACKAGE NAME

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Handler
import android.os.Looper
import android.view.HapticFeedbackConstants
import androidx.annotation.NonNull
import androidx.core.app.ActivityCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import kotlin.math.*

class MainActivity: FlutterActivity() {
    private val AUDIO_CHANNEL = "com.kinetic.void/audio"
    private val SENSOR_CHANNEL = "com.kinetic.void/sensor"
    private val HAPTIC_CHANNEL = "com.kinetic.void/haptic"

    // --- AUDIO STATE ---
    private var audioRecord: AudioRecord? = null
    private var recordingThread: Thread? = null
    private var isRecording = false
    private val SAMPLE_RATE = 44100
    private val BUFFER_SIZE = 1024 // Must be power of 2 for FFT

    private var audioSink: EventChannel.EventSink? = null
    private var sensorSink: EventChannel.EventSink? = null
    private lateinit var sensorManager: SensorManager

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // 1. AUDIO CHANNEL (Streams 5-Band Spectrum)
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, AUDIO_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    audioSink = events
                    if (checkPermission()) startRecording()
                }
                override fun onCancel(arguments: Any?) {
                    stopRecording()
                    audioSink = null
                }
            }
        )

        // 2. SENSOR CHANNEL (Streams Accelerometer)
        sensorManager = getSystemService(Context.SENSOR_SERVICE) as SensorManager
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, SENSOR_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler, SensorEventListener {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    sensorSink = events
                    val accelerometer = sensorManager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
                    sensorManager.registerListener(this, accelerometer, SensorManager.SENSOR_DELAY_GAME)
                }
                override fun onCancel(arguments: Any?) {
                    sensorManager.unregisterListener(this)
                    sensorSink = null
                }
                override fun onSensorChanged(event: SensorEvent?) {
                    if (event?.sensor?.type == Sensor.TYPE_ACCELEROMETER) {
                        // Invert X for natural tilt feel
                        sensorSink?.success(listOf(-event.values[0], event.values[1]))
                    }
                }
                override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
            }
        )

        // 3. HAPTIC CHANNEL (Triggers Physical Feedback)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, HAPTIC_CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "impact") {
                // Crisp vibration for collisions
                window.decorView.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
                result.success(null)
            } else {
                result.notImplemented()
            }
        }
    }

    private fun startRecording() {
        if (isRecording || audioSink == null) return

        val minBufferSize = AudioRecord.getMinBufferSize(SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        
        try {
            audioRecord = AudioRecord(
                MediaRecorder.AudioSource.MIC,
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                maxOf(minBufferSize, BUFFER_SIZE * 2)
            )
            audioRecord?.startRecording()
            isRecording = true
        } catch (e: Exception) {
            audioSink?.error("RECORDER_ERROR", "Init failed", e.message)
            return
        }

        val fft = SimpleFFT(BUFFER_SIZE)
        val buffer = ShortArray(BUFFER_SIZE)

        recordingThread = Thread {
            while (isRecording) {
                val readSize = audioRecord?.read(buffer, 0, BUFFER_SIZE) ?: 0
                if (readSize > 0) {
                    // Calculate 5 Bands
                    val bands = fft.calculate(buffer)
                    
                    // NORMALIZE & SCALING
                    // Higher frequencies need higher multipliers to be visible
                    val processed = listOf(
                        log10(bands[0] + 1) * 0.8, // Band 0: Sub-Bass (Red)
                        log10(bands[1] + 1) * 1.0, // Band 1: Bass (Orange)
                        log10(bands[2] + 1) * 1.2, // Band 2: Mids (Yellow)
                        log10(bands[3] + 1) * 1.8, // Band 3: High Mids (Cyan)
                        log10(bands[4] + 1) * 3.0  // Band 4: Treble (Purple) - Huge Boost
                    )

                    runOnUiThread {
                        // Send List<Double> to Flutter
                        audioSink?.success(processed)
                    }
                }
            }
        }
        recordingThread?.start()
    }

    private fun stopRecording() {
        isRecording = false
        try {
            audioRecord?.stop()
            audioRecord?.release()
        } catch (e: Exception) {}
        audioRecord = null
        recordingThread = null
    }

    // --- PERMISSIONS ---
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 1 && grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
            startRecording()
        } else {
            audioSink?.error("PERMISSION_DENIED", "User denied permission", null)
        }
    }

    private fun checkPermission(): Boolean {
        if (ActivityCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.RECORD_AUDIO), 1)
            return false
        }
        return true
    }
}

// --- 5-BAND FFT HELPER ---
class SimpleFFT(val n: Int) {
    val real = DoubleArray(n)
    val imag = DoubleArray(n)

    fun calculate(buffer: ShortArray): List<Double> {
        // 1. Normalize
        for (i in 0 until n) {
            real[i] = buffer[i].toDouble() / 32768.0
            imag[i] = 0.0
        }

        // 2. FFT Math (Cooley-Tukey)
        var i = 0; var j = 0; var k = 0; var tx = 0.0; var ty = 0.0
        j = 0
        for (i in 0 until n - 1) {
            if (i < j) {
                tx = real[i]; real[i] = real[j]; real[j] = tx
                ty = imag[i]; imag[i] = imag[j]; imag[j] = ty
            }
            k = n / 2
            while (k <= j) { j -= k; k /= 2 }
            j += k
        }
        var l = 1
        while (l < n) {
            val step = l * 2
            for (m in 0 until l) {
                val angle = -Math.PI * m / l
                val wReal = cos(angle)
                val wImag = sin(angle)
                var i = m
                while (i < n) {
                    j = i + l
                    tx = wReal * real[j] - wImag * imag[j]
                    ty = wReal * imag[j] + wImag * real[j]
                    real[j] = real[i] - tx
                    imag[j] = imag[i] - ty
                    real[i] += tx
                    imag[i] += ty
                    i += step
                }
            }
            l = step
        }

        // 3. AGGREGATE BINS INTO 5 BANDS
        // Sample Rate 44100 / Buffer 1024 = ~43Hz per bin
        
        // Band 0: Sub-Bass (0 - 86Hz) -> Bins 0-2
        var b0 = 0.0
        for (k in 0..2) b0 += mag(k)
        
        // Band 1: Bass (86 - 250Hz) -> Bins 3-6
        var b1 = 0.0
        for (k in 3..6) b1 += mag(k)
        
        // Band 2: Low Mids (250 - 600Hz) -> Bins 7-14
        var b2 = 0.0
        for (k in 7..14) b2 += mag(k)
        
        // Band 3: High Mids (600 - 2000Hz) -> Bins 15-46
        var b3 = 0.0
        for (k in 15..46) b3 += mag(k)
        
        // Band 4: Treble (2000Hz +) -> Bins 47-150
        var b4 = 0.0
        for (k in 47..150) b4 += mag(k)

        return listOf(b0, b1, b2, b3, b4)
    }

    private fun mag(i: Int): Double {
        return sqrt(real[i].pow(2) + imag[i].pow(2))
    }
}