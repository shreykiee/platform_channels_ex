import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(
    const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: KineticVoidPage(),
    ),
  );
}

class KineticVoidPage extends StatefulWidget {
  const KineticVoidPage({super.key});

  @override
  State<KineticVoidPage> createState() => _KineticVoidPageState();
}

class _KineticVoidPageState extends State<KineticVoidPage>
    with SingleTickerProviderStateMixin {
  // --- CHANNELS ---
  static const EventChannel _audioChannel = EventChannel(
    'com.kinetic.void/audio',
  );
  static const EventChannel _sensorChannel = EventChannel(
    'com.kinetic.void/sensor',
  );
  // 1. New Haptic Channel (MethodChannel, not EventChannel)
  static const MethodChannel _hapticChannel = MethodChannel(
    'com.kinetic.void/haptic',
  );

  // --- STATE DATA ---
  double currentVolume = 0.0;
  Offset gravity = Offset.zero;
  DateTime lastHapticTime = DateTime.now(); // To prevent vibration spam

  // --- PHYSICS ENGINE ---
  late Ticker _ticker;
  List<Particle> particles = [];
  final Random _rng = Random();

  StreamSubscription? _audioSub;
  StreamSubscription? _sensorSub;

  @override
  void initState() {
    super.initState();
    _initParticles();
    _startListening();

    _ticker = createTicker((elapsed) {
      _updatePhysics();
    });
    _ticker.start();
  }

  void _initParticles() {
    for (int i = 0; i < 150; i++) {
      particles.add(
        Particle(
          x: _rng.nextDouble() * 300,
          y: _rng.nextDouble() * 500,
          radius: _rng.nextDouble() * 2 + 1,
          color: Colors.primaries[_rng.nextInt(Colors.primaries.length)],
        ),
      );
    }
  }

  void _startListening() {
    _audioSub = _audioChannel.receiveBroadcastStream().listen((event) {
      setState(() {
        currentVolume = (event as double) / 100;
      });
    }, onError: (e) => print("Audio Error: $e"));

    _sensorSub = _sensorChannel.receiveBroadcastStream().listen((event) {
      final List<dynamic> values = event;
      setState(() {
        gravity = Offset(values[0] * 2.0, values[1] * 2.0);
      });
    }, onError: (e) => print("Sensor Error: $e"));
  }

  // 2. Haptic Trigger Function
  void _checkImpact(double velocity) {
    // Only vibrate if velocity is high (hard hit) AND enough time has passed (80ms)
    if (velocity.abs() > 15.0 &&
        DateTime.now().difference(lastHapticTime).inMilliseconds > 80) {
      lastHapticTime = DateTime.now();
      // Send command to Native Android
      _hapticChannel.invokeMethod('impact');
    }
  }

  void _updatePhysics() {
    setState(() {
      double activeVolume = 0.0;
      if (currentVolume > 0.30) {
        activeVolume = (currentVolume - 0.30) / 0.70;
      }

      for (var p in particles) {
        // Gravity
        p.vx += gravity.dx * 0.10;
        p.vy += gravity.dy * 0.10;

        // Audio Physics
        if (activeVolume > 0.0) {
          double shake = activeVolume * activeVolume * 2.5;
          p.vx += (_rng.nextDouble() - 0.5) * shake;
          p.vy += (_rng.nextDouble() - 0.5) * shake;

          if (_rng.nextDouble() < (activeVolume * 0.2)) {
            p.vy -= (activeVolume * 15.0);
            p.vx += (_rng.nextDouble() - 0.5) * (activeVolume * 10.0);
          }
          p.targetRadius = (6.0 * activeVolume) + 2.0;
        } else {
          p.targetRadius = 2.0;
        }

        p.radius += (p.targetRadius - p.radius) * 0.1;

        // Move
        p.x += p.vx;
        p.y += p.vy;

        // Friction
        p.vx *= 0.94;
        p.vy *= 0.94;

        // Boundary Checks & Haptics
        double width = MediaQuery.of(context).size.width;
        double height = MediaQuery.of(context).size.height;

        if (p.x < 0) {
          p.x = 0;
          _checkImpact(p.vx); // Check collision speed
          p.vx = -p.vx * 0.7;
        }
        if (p.x > width) {
          p.x = width;
          _checkImpact(p.vx);
          p.vx = -p.vx * 0.7;
        }

        if (p.y < 0) {
          p.y = 0;
          _checkImpact(p.vy);
          p.vy = -p.vy * 0.7;
        }
        if (p.y > height) {
          p.y = height;
          _checkImpact(p.vy);
          p.vy = -p.vy * 0.7;
        }
      }
    });
  }

  @override
  void dispose() {
    _ticker.dispose();
    _audioSub?.cancel();
    _sensorSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: CustomPaint(painter: VoidPainter(particles), child: Container()),
    );
  }
}

class Particle {
  double x, y, vx = 0, vy = 0, radius, targetRadius;
  Color color;
  Particle({
    required this.x,
    required this.y,
    required this.radius,
    required this.color,
  }) : targetRadius = radius;
}

class VoidPainter extends CustomPainter {
  final List<Particle> particles;
  VoidPainter(this.particles);

  @override
  void paint(Canvas canvas, Size size) {
    for (var p in particles) {
      final paint = Paint()
        ..color = p.color.withOpacity(0.8)
        ..style = PaintingStyle.fill;
      if (p.radius > 3)
        canvas.drawCircle(
          Offset(p.x, p.y),
          p.radius * 2.0,
          Paint()..color = p.color.withOpacity(0.3),
        );
      canvas.drawCircle(Offset(p.x, p.y), p.radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
