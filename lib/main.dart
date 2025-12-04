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
    Colors.redAccent, // 0: Sub-Bass
    Colors.deepOrange, // 1: Bass
    Colors.yellow, // 2: Mids (SMALLER NOW)
    Colors.cyanAccent, // 3: High Mids
    Colors.purpleAccent, // 4: Treble
  ];

  List<double> prevEnergyLevels = [0.0, 0.0, 0.0, 0.0, 0.0];
  List<double> energyLevels = [0.0, 0.0, 0.0, 0.0, 0.0];
  Offset gravity = Offset.zero;

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
    for (int i = 0; i < 1000; i++) {
      int band = _rng.nextInt(5);
      double mass;
      double startRadius;

      if (band <= 1) {
        // Red/Orange: Heavy & Large
        mass = 1.0 + _rng.nextDouble() * 3.0;
        startRadius = _rng.nextDouble() * 1.5 + 0.5; // 0.5 to 2.0
      } else if (band == 2) {
        // Yellow: Medium Mass, SMALLER SIZE
        mass = 1.5 + _rng.nextDouble() * 1.5;
        // Range reduced to 0.3 - 1.0 (Was 0.5 - 2.0)
        startRadius = _rng.nextDouble() * 0.7 + 0.3;
      } else {
        // Cyan/Purple: Light
        mass = 0.5 + _rng.nextDouble();
        startRadius = _rng.nextDouble() * 1.5 + 0.5;
      }

      particles.add(
        Particle(
          x: _rng.nextDouble() * 300,
          y: 1000,
          radius: startRadius,
          bandIndex: band,
          baseColor: bandColors[band],
          massFactor: mass,
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
            double decay = (i == 2) ? 0.4 : 0.4;
            energyLevels[i] -= (energyLevels[i] - raw) * decay;
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

  void _updatePhysics() {
    setState(() {
      double width = MediaQuery.of(context).size.width;
      double height = MediaQuery.of(context).size.height;

      for (var p in particles) {
        double myEnergy = energyLevels[p.bandIndex].clamp(0.0, 1.0);
        double transient = (myEnergy - prevEnergyLevels[p.bandIndex]);

        // ============================================================
        //  PHYSICS
        // ============================================================

        // --- GROUP 1: RED & ORANGE ---
        if (p.bandIndex <= 1) {
          p.vy += 5.0 * (0.5 + (p.massFactor * 0.1));

          if (transient > 0.05) {
            double posRatio = (p.y / height).clamp(0.0, 1.0);
            double kick = transient * 200.0 * (posRatio * posRatio);
            p.vy -= kick / p.massFactor;
            p.vx += (_rng.nextDouble() - 0.5) * (kick * 0.1);
          }
          p.vx *= 0.93;
          p.vy *= 0.93;
        }
        // --- GROUP 2: YELLOW (High Gate, Low Bounce) ---
        else if (p.bandIndex == 2) {
          p.vy += 4.0;

          if (transient > 0.08) {
            double posRatio = (p.y / height).clamp(0.0, 1.0);
            double kick = transient * 150.0 * (posRatio * posRatio);

            p.vy -= kick / p.massFactor;
            p.vx += (_rng.nextDouble() - 0.5) * (kick * 0.3);
          }

          p.vx *= 0.94;
          p.vy *= 0.94;
        }
        // --- GROUP 3: CYAN & PURPLE ---
        else {
          p.vy += 2.0;
          if (transient > 0.02) {
            double posRatio = (p.y / height).clamp(0.0, 1.0);
            double kick = transient * 300.0 * posRatio;
            p.vy -= kick / p.massFactor;
            p.vx += (_rng.nextDouble() - 0.5) * (kick * 0.8);
          }
          p.vx *= 0.96;
          p.vy *= 0.96;
        }

        // ============================================================
        //  VISUALS (SIZE TUNING)
        // ============================================================

        if (p.bandIndex == 2) {
          // YELLOW: Grows much less. Max size ~2.5
          p.targetRadius = (2.0 * myEnergy) + 0.5;
        } else {
          // OTHERS: Standard growth. Max size ~4.5
          p.targetRadius = (3.5 * myEnergy) + 1.0;
        }

        p.color = p.baseColor;

        p.x += p.vx;
        p.y += p.vy;
        p.radius += (p.targetRadius - p.radius) * 0.2;

        // --- FLOOR ---
        if (p.y > height) {
          p.y = height;
          if (p.bandIndex <= 1) {
            p.vy = -p.vy * 0.05;
            p.vx *= 0.4;
          } else if (p.bandIndex == 2) {
            p.vy = -p.vy * 0.1;
            p.vx *= 0.5;
          } else {
            p.vy = -p.vy * 0.3;
            p.vx *= 0.8;
          }
        }

        // --- CEILING ---
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
          Paint()..color = p.color.withOpacity(0.15),
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
