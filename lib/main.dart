import 'dart:async';
import 'dart:math';
import 'dart:ui';
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
  static const MethodChannel _hapticChannel = MethodChannel(
    'com.kinetic.void/haptic',
  );

  // --- STATE ---
  double bassLevel = 0.0;
  double trebleLevel = 0.0;
  Offset gravity = Offset.zero;
  DateTime lastHapticTime = DateTime.now();

  // --- PHYSICS ---
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
    particles.clear();
    for (int i = 0; i < 150; i++) {
      // 60% Bass (Blue), 40% Treble (Gold)
      bool isBass = _rng.nextDouble() > 0.4;
      particles.add(
        Particle(
          x: _rng.nextDouble() * 300,
          y: _rng.nextDouble() * 500,
          radius: _rng.nextDouble() * 2 + 1,
          isBassType: isBass,
          baseColor: isBass ? Colors.cyanAccent : Colors.amberAccent,
        ),
      );
    }
  }

  void _startListening() {
    _audioSub = _audioChannel.receiveBroadcastStream().listen((event) {
      final Map<dynamic, dynamic> data = event;
      setState(() {
        // TARGET VALUES
        double targetBass = data['bass'] as double;
        double targetTreble = data['treble'] as double;

        // ATTACK/DECAY LOGIC
        // If new beat is louder, jump instantly (Attack).
        // If quieter, fade out fast (Decay).
        if (targetBass > bassLevel) {
          bassLevel = targetBass; // Instant hit
        } else {
          bassLevel -= (bassLevel - targetBass) * 0.1; // Fast fade
        }

        // Treble can stay smooth
        trebleLevel += (targetTreble - trebleLevel) * 0.2;
      });
    }, onError: (e) => print("Audio Error: $e"));

    _sensorSub = _sensorChannel.receiveBroadcastStream().listen((event) {
      final List<dynamic> values = event;
      setState(() {
        gravity = Offset(values[0] * 1.5, values[1] * 1.5);
      });
    });
  }

  void _checkImpact(double velocity) {
    // Only vibrate on hard hits
    if (velocity.abs() > 25.0 &&
        DateTime.now().difference(lastHapticTime).inMilliseconds > 100) {
      lastHapticTime = DateTime.now();
      _hapticChannel.invokeMethod('impact');
    }
  }

  void _updatePhysics() {
    setState(() {
      // 1. THE "SNAP" CURVE
      // We raise the floor to 0.45. Anything below this is SILENCE.
      double activeBass = 0.0;
      if (bassLevel > 0.45) {
        double normalized = (bassLevel - 0.45) / 0.55;
        // CUBIC CURVE: This is the secret.
        // Input 0.1 -> Output 0.001 (Basically zero)
        // Input 0.9 -> Output 0.72 (Huge)
        // This separates "Noise" from "Beats"
        activeBass = normalized * normalized * normalized;
      }

      double activeTreble = 0.0;
      if (trebleLevel > 0.2) {
        activeTreble = (trebleLevel - 0.2) / 0.8;
      }

      // 2. HEAVY GRAVITY (Pulls them down fast after a jump)
      double baseGravityY = 0.8;

      for (var p in particles) {
        // Sensor Gravity + Base Gravity
        p.vx += gravity.dx * 0.1;
        p.vy += (gravity.dy * 0.1) + baseGravityY;

        // --- BASS PARTICLES ---
        if (p.isBassType) {
          // STRICT GATE: If activeBass is weak, force it to zero
          if (activeBass > 0.05) {
            // JITTER: Random shaking
            double shake = activeBass * 4.0;
            p.vx += (_rng.nextDouble() - 0.5) * shake;
            p.vy += (_rng.nextDouble() - 0.5) * shake;

            // EXPLOSION: Only apply huge upward force on peak beats
            // 20.0 is a massive force, but it only happens at peak volume
            if (_rng.nextDouble() < 0.2) {
              p.vy -= (activeBass * 20.0);
            }

            p.targetRadius = (10.0 * activeBass) + 2.0;
          } else {
            // Dead still if no beat
            p.targetRadius = 2.0;
          }

          // Flash Color
          p.color = Color.lerp(p.baseColor, Colors.white, activeBass)!;
        }
        // --- TREBLE PARTICLES ---
        else {
          // (Keep existing treble logic, it's fine)
          if (activeTreble > 0.1) {
            p.vx += (_rng.nextDouble() - 0.5) * 1.5;
            p.vy += (_rng.nextDouble() - 0.5) * 1.5;
            p.color = Color.lerp(
              Colors.orange,
              Colors.purpleAccent,
              activeTreble,
            )!;
            p.targetRadius = (3.0 * activeTreble) + 1.5;
          } else {
            p.color = p.baseColor;
            p.targetRadius = 1.5;
          }
        }

        // Apply Velocity
        p.x += p.vx;
        p.y += p.vy;

        // Radius Spring
        p.radius += (p.targetRadius - p.radius) * 0.2;

        // 3. HIGH FRICTION (The "Stop" Mechanism)
        // Changed from 0.92 to 0.85
        // This makes them lose speed VERY fast. They jump, then freeze.
        p.vx *= 0.85;
        p.vy *= 0.85;

        // Boundaries (Floor Bounce)
        double width = MediaQuery.of(context).size.width;
        double height = MediaQuery.of(context).size.height;

        if (p.y > height) {
          p.y = height;
          p.vy = -p.vy * 0.4; // Low bounce factor (heavy particles)
        }
        if (p.y < 0) {
          p.y = 0;
          p.vy = abs(p.vy) * 0.1; // Kill energy at ceiling
          _checkImpact(p.vy);
        }
        if (p.x < 0) {
          p.x = 0;
          p.vx = -p.vx * 0.5;
        }
        if (p.x > width) {
          p.x = width;
          p.vx = -p.vx * 0.5;
        }
      }
    });
  }

  // Helper for absolute value
  double abs(double v) => v > 0 ? v : -v;

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
  Color baseColor;
  bool isBassType;

  Particle({
    required this.x,
    required this.y,
    required this.radius,
    required this.baseColor,
    required this.isBassType,
  }) : color = baseColor,
       targetRadius = radius;
}

class VoidPainter extends CustomPainter {
  final List<Particle> particles;
  VoidPainter(this.particles);

  @override
  void paint(Canvas canvas, Size size) {
    for (var p in particles) {
      if (p.radius > 2.5) {
        canvas.drawCircle(
          Offset(p.x, p.y),
          p.radius * 2.0,
          Paint()..color = p.color.withOpacity(0.3),
        );
      }
      canvas.drawCircle(
        Offset(p.x, p.y),
        p.radius,
        Paint()
          ..color = p.color
          ..style = PaintingStyle.fill,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
