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

    // Audio State
    private var audioRecord: AudioRecord? = null
    private var recordingThread: Thread? = null
    private var isRecording = false
    private val SAMPLE_RATE = 44100
    private val BUFFER_SIZE = 1024 // Power of 2 for FFT

    private var audioSink: EventChannel.EventSink? = null
    private var sensorSink: EventChannel.EventSink? = null
    private lateinit var sensorManager: SensorManager

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // --- AUDIO CHANNEL ---
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

        // --- SENSOR CHANNEL ---
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

        // --- HAPTIC CHANNEL ---
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, HAPTIC_CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "impact") {
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
                    // Calculate Bass and Treble
                    val (bass, treble) = fft.calculate(buffer)
                    
                    // Logarithmic scaling for better visualization response
                    // Bass needs a lower multiplier, Treble needs higher to be visible
                    val finalBass = log10(bass + 1) * 0.8
                    val finalTreble = log10(treble + 1) * 4.0

                    runOnUiThread {
                        audioSink?.success(mapOf(
                            "bass" to finalBass,
                            "treble" to finalTreble
                        ))
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

    // Permission Logic
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

// --- FFT HELPER CLASS ---
// Calculates Frequency Magnitude from raw PCM data
class SimpleFFT(val n: Int) {
    val real = DoubleArray(n)
    val imag = DoubleArray(n)

    fun calculate(buffer: ShortArray): Pair<Double, Double> {
        // 1. Normalize
        for (i in 0 until n) {
            real[i] = buffer[i].toDouble() / 32768.0
            imag[i] = 0.0
        }

        // 2. FFT (Simple implementation)
        var i = 0
        var j = 0
        var k = 0
        var tx = 0.0
        var ty = 0.0
        
        // Bit reversal
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

        // Computation
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

        // 3. Aggregate Bins
        // Bass (Low Freq): Bins 1-5 (~40Hz - 200Hz)
        var bassSum = 0.0
        for (k in 1..3) { 
            bassSum += sqrt(real[k].pow(2) + imag[k].pow(2)) 
        }

        // Treble (High Freq): Bins 60-150 (~2.5kHz - 6kHz)
        var trebleSum = 0.0
        for (k in 40 until min(120, n/2)) { // Shifted range down slightly to catch snare drums
            trebleSum += sqrt(real[k].pow(2) + imag[k].pow(2))
        }

        return Pair(bassSum, trebleSum)
    }
}