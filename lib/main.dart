import 'dart:async';
import 'dart:math';
import 'dart:ui'; // Needed for Color.lerp
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

  // --- TUNING KNOBS (Fixed) ---
  // 1. SENSITIVITY: Set to 1.0 (100%).
  //    We accept the full volume now to ensure movement.
  final double sensitivity = 1.0;

  // 2. THRESHOLD: Lowered to 0.15.
  //    Everything above 15% volume triggers movement. Silence ignores it.
  final double minThreshold = 0.15;

  // 3. FRICTION: High (0.88).
  //    Stops particles quickly so they don't float around endlessly.
  final double friction = 0.88;

  // --- STATE DATA ---
  double bassLevel = 0.0;
  double trebleLevel = 0.0;
  Offset gravity = Offset.zero;
  DateTime lastHapticTime = DateTime.now();

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
    particles.clear();
    for (int i = 0; i < 150; i++) {
      // 60% Bass (Blue/Cyan), 40% Treble (Orange/Gold)
      bool isBass = _rng.nextDouble() > 0.4;

      particles.add(
        Particle(
          x: _rng.nextDouble() * 300,
          y: _rng.nextDouble() * 500,
          radius: _rng.nextDouble() * 2 + 1,
          isBassType: isBass,
          baseColor: isBass ? Colors.cyanAccent : Colors.orangeAccent,
        ),
      );
    }
  }

  void _startListening() {
    _audioSub = _audioChannel.receiveBroadcastStream().listen((event) {
      final Map<dynamic, dynamic> data = event;
      setState(() {
        // 1. APPLY SENSITIVITY
        double rawBass = (data['bass'] as double) * sensitivity;
        double rawTreble = (data['treble'] as double) * sensitivity;

        // 2. ATTACK / DECAY
        // Instant Attack (rising), Fast Decay (falling)
        if (rawBass > bassLevel) {
          bassLevel = rawBass;
        } else {
          bassLevel -= (bassLevel - rawBass) * 0.15;
        }

        trebleLevel += (rawTreble - trebleLevel) * 0.2;
      });
    }, onError: (e) => print("Audio Error: $e"));

    _sensorSub = _sensorChannel.receiveBroadcastStream().listen((event) {
      final List<dynamic> values = event;
      setState(() {
        // Reduced sensor influence slightly
        gravity = Offset(values[0] * 1.5, values[1] * 1.5);
      });
    });
  }

  void _checkImpact(double velocity) {
    // Only vibrate on hard hits (> 25.0 velocity)
    if (velocity.abs() > 40.0 &&
        DateTime.now().difference(lastHapticTime).inMilliseconds > 100) {
      lastHapticTime = DateTime.now();
      _hapticChannel.invokeMethod('impact');
    }
  }

  void _updatePhysics() {
    setState(() {
      // --- 1. CALCULATE FORCES WITH EXPONENTIAL RAMP ---
      double activeBass = 0.0;

      // Threshold: 0.20 (Ignore quiet room noise)
      if (bassLevel > 0.20) {
        double normalized = (bassLevel - 0.20) / 0.80;
        if (normalized > 1.0) normalized = 1.0;

        // THE MAGIC FIX: Power of 4
        // Input 0.5 (Medium) -> Output 0.06 (Tiny energy)
        // Input 0.8 (Loud)   -> Output 0.40 (40% energy)
        // Input 1.0 (Max)    -> Output 1.00 (100% energy)
        // This creates the "Slow Increase" you asked for.
        activeBass = normalized * normalized * normalized * normalized;
      }

      double activeTreble = 0.0;
      if (trebleLevel > 0.1) {
        activeTreble = (trebleLevel - 0.1) / 0.9;
        if (activeTreble > 1.0) activeTreble = 1.0;
      }

      // Base Gravity
      double baseGravityY = 0.8;

      for (var p in particles) {
        // Gravity
        p.vx += gravity.dx * 0.1;
        p.vy += (gravity.dy * 0.1) + baseGravityY;

        if (p.isBassType) {
          // --- BASS PHYSICS ---
          if (activeBass > 0.001) {
            // 1. VIBRATION (Low Energy Response)
            // At low volume, they just wiggle.
            double shake = activeBass * 2.0;
            p.vx += (_rng.nextDouble() - 0.5) * shake;
            p.vy += (_rng.nextDouble() - 0.5) * shake;

            // 2. THE JUMP (High Energy Response)
            // We use the 'activeBass' multiplier on the Jump Force.
            // Low vol (0.1) -> Jump Force 2.5 (Tiny hop)
            // High vol (1.0) -> Jump Force 25.0 (Huge launch)
            if (activeBass > 0.5 &&
                _rng.nextDouble() < (0.1 + activeBass * 0.0001)) {
              // The force is now DYNAMIC, not fixed.
              p.vy -= (activeBass * 20.0);
            }

            p.targetRadius = (5.0 * activeBass) + 2.0;
          } else {
            p.targetRadius = 1.0;
          }

          p.color = Color.lerp(p.baseColor, Colors.white, activeBass)!;
        } else {
          // --- TREBLE PHYSICS ---
          if (activeTreble > 0.05) {
            p.vx += (_rng.nextDouble() - 0.5) * 1.5;
            p.vy += (_rng.nextDouble() - 0.5) * 1.5;
            p.color = Color.lerp(
              Colors.orangeAccent,
              Colors.purpleAccent,
              activeTreble,
            )!;
            p.targetRadius = (5.0 * activeTreble) + 1.5;
          } else {
            p.color = p.baseColor;
            p.targetRadius = 1.5;
          }
        }

        // --- KINEMATICS ---
        p.x += p.vx;
        p.y += p.vy;
        p.radius += (p.targetRadius - p.radius) * 0.15;

        // FRICTION
        p.vx *= 0.88;
        p.vy *= 0.88;

        // BOUNDARIES
        double width = MediaQuery.of(context).size.width;
        double height = MediaQuery.of(context).size.height;

        if (p.y > height) {
          p.y = height;
          p.vy = -p.vy * 0.3; // Dampen floor bounce
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

// --- DATA CLASSES ---

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
      // 1. Draw Glow (Only if particle is active/large)
      if (p.radius > 2.5) {
        canvas.drawCircle(
          Offset(p.x, p.y),
          p.radius * 2.5,
          Paint()..color = p.color.withOpacity(0.3),
        );
      }
      // 2. Draw Core
      final paint = Paint()
        ..color = p.color
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(p.x, p.y), p.radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
