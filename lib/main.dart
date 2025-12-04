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
  static const EventChannel _audioChannel = EventChannel(
    'com.kinetic.void/audio',
  );
  static const EventChannel _sensorChannel = EventChannel(
    'com.kinetic.void/sensor',
  );
  static const MethodChannel _hapticChannel = MethodChannel(
    'com.kinetic.void/haptic',
  );

  final List<Color> bandColors = [
    Colors.redAccent,
    Colors.orangeAccent,
    Colors.yellow,
    Colors.cyan,
    Colors.purpleAccent,
  ];

  List<double> prevEnergyLevels = [0.0, 0.0, 0.0, 0.0, 0.0];
  List<double> energyLevels = [0.0, 0.0, 0.0, 0.0, 0.0];
  Offset gravity = Offset.zero;
  DateTime lastHapticTime = DateTime.now();

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
    _ticker = createTicker((elapsed) => _updatePhysics());
    _ticker.start();
  }

  void _initParticles() {
    particles.clear();
    // 800 Particles
    for (int i = 0; i < 800; i++) {
      int band = 0; // Force Red

      particles.add(
        Particle(
          x: _rng.nextDouble() * 300,
          y: 800 + _rng.nextDouble() * 100,
          radius: _rng.nextDouble() * 1.5 + 0.5,
          bandIndex: band,
          baseColor: bandColors[band],
          // Mass variance
          massFactor: 1.0 + _rng.nextDouble() * 3.0,
          randomOffset: _rng.nextDouble() * 100,
        ),
      );
    }
  }

  void _startListening() {
    _audioSub = _audioChannel.receiveBroadcastStream().listen((event) {
      final List<dynamic> rawValues = event;
      setState(() {
        for (int i = 0; i < 5; i++) {
          double raw = (rawValues[i] as double);
          prevEnergyLevels[i] = energyLevels[i];
          if (raw > energyLevels[i]) {
            energyLevels[i] = raw;
          } else {
            energyLevels[i] -= (energyLevels[i] - raw) * 0.4;
          }
        }
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
    if (velocity.abs() > 40.0 &&
        DateTime.now().difference(lastHapticTime).inMilliseconds > 100) {
      lastHapticTime = DateTime.now();
      _hapticChannel.invokeMethod('impact');
    }
  }

  void _updatePhysics() {
    setState(() {
      double width = MediaQuery.of(context).size.width;
      double height = MediaQuery.of(context).size.height;

      // VERY STRONG GRAVITY (Keeps them grouped at bottom)
      double baseGravityY = 5.0;

      for (var p in particles) {
        double myEnergy = energyLevels[p.bandIndex].clamp(0.0, 1.0);
        double transient = (myEnergy - prevEnergyLevels[p.bandIndex]);

        // Gravity
        p.vy += baseGravityY * (0.5 + (p.massFactor * 0.1));

        // --- REACT TO BEAT ---
        if (transient > 0.05) {
          // 1. HEIGHT DAMPING (The "Invisible Rubber Band")
          // Calculate how close the particle is to the bottom (0.0 to 1.0)
          // At bottom (height), ratio is 1.0. At top (0), ratio is 0.0.
          double positionRatio = (p.y / height).clamp(0.0, 1.0);

          // If particle is already high up (low positionRatio),
          // we reduce the kick force significantly.

          // 2. REDUCED KICK FORCE
          // Base kick lowered to 90.0 (was 160.0, 250.0 before)
          // Multiplied by positionRatio^2 to punish high particles
          double kickForce = transient * 90.0 * (positionRatio * positionRatio);

          p.vy -= kickForce / p.massFactor;
          p.vx += (_rng.nextDouble() - 0.5) * (kickForce * 0.15);
        }

        // --- RADIUS & GLOW ---
        p.targetRadius = (3.0 * myEnergy) + 1.0;

        if (myEnergy > 0.6) {
          p.color = Color.lerp(
            p.baseColor,
            Colors.white,
            (myEnergy - 0.6) * 2.5,
          )!;
        } else {
          p.color = p.baseColor;
        }

        // --- KINEMATICS ---
        p.x += p.vx;
        p.y += p.vy;

        p.radius += (p.targetRadius - p.radius) * 0.2;

        // HEAVY AIR RESISTANCE
        // 0.93 creates a "thick" atmosphere, killing upward momentum fast
        p.vx *= 0.93;
        p.vy *= 0.93;

        // --- FLOOR PHYSICS ---
        if (p.y > height) {
          p.y = height;
          p.vy = -p.vy * 0.05; // Almost no bounce
          p.vx *= 0.4; // Very high friction on ground (stops sliding)
        }

        // --- CEILING PHYSICS (Safety Net) ---
        if (p.y < 0) {
          p.y = 0;
          p.vy = p.vy.abs() * 0.5;
        }

        // --- WALLS ---
        if (p.x < 0) {
          p.x = 0;
          p.vx = p.vx.abs() * 0.5;
        }
        if (p.x > width) {
          p.x = width;
          p.vx = -p.vx.abs() * 0.5;
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
  Color baseColor;
  int bandIndex;
  double randomOffset;
  double massFactor;

  Particle({
    required this.x,
    required this.y,
    required this.radius,
    required this.baseColor,
    required this.bandIndex,
    required this.randomOffset,
    required this.massFactor,
  }) : color = baseColor,
       targetRadius = radius;
}

class VoidPainter extends CustomPainter {
  final List<Particle> particles;
  VoidPainter(this.particles);

  @override
  void paint(Canvas canvas, Size size) {
    for (var p in particles) {
      if (p.radius > 2.0) {
        canvas.drawCircle(
          Offset(p.x, p.y),
          p.radius * 2.0,
          Paint()..color = p.color.withOpacity(0.1),
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
