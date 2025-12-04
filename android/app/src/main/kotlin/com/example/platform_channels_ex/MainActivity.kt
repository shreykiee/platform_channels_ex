package com.example.platform_channels_ex

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.media.MediaRecorder
import android.os.Handler
import android.os.Looper
import android.view.HapticFeedbackConstants
import androidx.annotation.NonNull
import androidx.core.app.ActivityCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel // NEW IMPORT
import java.io.File
import java.io.IOException
import kotlin.math.log10

class MainActivity: FlutterActivity() {
    private val AUDIO_CHANNEL = "com.kinetic.void/audio"
    private val SENSOR_CHANNEL = "com.kinetic.void/sensor" 
    private val HAPTIC_CHANNEL = "com.kinetic.void/haptic" // 1. New Channel

    private var recorder: MediaRecorder? = null
    private var isRecording = false
    private val handler = Handler(Looper.getMainLooper())
    
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
                        val x = -event.values[0] 
                        val y = event.values[1]
                        sensorSink?.success(listOf(x, y))
                    }
                }
                override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
            }
        )

        // --- HAPTIC CHANNEL (NEW) ---
        // This listens for commands from Flutter
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, HAPTIC_CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "impact") {
                // Trigger a crisp vibration
                window.decorView.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
                result.success(null)
            } else {
                result.notImplemented()
            }
        }
    }

    // ... (Permissions and Recorder logic remains same) ...
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 1 && grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
            startRecording()
        } else {
            audioSink?.error("PERMISSION_DENIED", "User denied permission", null)
        }
    }

    private fun startRecording() {
        if (isRecording || audioSink == null) return
        val tempFile = File(cacheDir, "temp_audio_stream.3gp")
        recorder = MediaRecorder().apply {
            setAudioSource(MediaRecorder.AudioSource.MIC)
            setOutputFormat(MediaRecorder.OutputFormat.THREE_GPP)
            setAudioEncoder(MediaRecorder.AudioEncoder.AMR_NB)
            setOutputFile(tempFile.absolutePath) 
            try { prepare(); start(); isRecording = true } 
            catch (e: Exception) { audioSink?.error("RECORDER_ERROR", "Start failed", e.localizedMessage); return }
        }
        val runnable = object : Runnable {
            override fun run() {
                if (isRecording && recorder != null) {
                    try {
                        val maxAmplitude = recorder!!.maxAmplitude.toDouble()
                        if (maxAmplitude > 0) audioSink?.success(20 * log10(maxAmplitude))
                        handler.postDelayed(this, 50) 
                    } catch (e: Exception) { }
                }
            }
        }
        handler.post(runnable)
    }

    private fun stopRecording() {
        isRecording = false
        try { recorder?.stop(); recorder?.release() } catch (e: Exception) { }
        recorder = null
        handler.removeCallbacksAndMessages(null)
    }

    private fun checkPermission(): Boolean {
        if (ActivityCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.RECORD_AUDIO), 1)
            return false
        }
        return true
    }
}