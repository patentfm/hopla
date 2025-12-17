import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:sensors_plus/sensors_plus.dart';

class MoleSmashRhythmScreen extends StatefulWidget {
  const MoleSmashRhythmScreen({super.key});

  @override
  State<MoleSmashRhythmScreen> createState() => _MoleSmashRhythmScreenState();
}

class _MoleSmashRhythmScreenState extends State<MoleSmashRhythmScreen>
    with SingleTickerProviderStateMixin {
  static const int _gridSize = 3;
  static const Duration _initialSpawnInterval = Duration(milliseconds: 1500);
  static const Duration _minSpawnInterval = Duration(milliseconds: 550);
  static const Duration _moleLifetime = Duration(milliseconds: 1300);
  static const double _impactDeltaThreshold = 5.2; // m/s^2 step change
  static const double _impactAbsoluteThreshold = 15.0; // m/s^2 absolute z
  static const double _tiltRange = 8.0;

  final Random _random = Random();
  late final Ticker _ticker;
  StreamSubscription<AccelerometerEvent>? _accelerometerSub;

  final Map<int, _Mole> _activeMoles = {};
  Duration _elapsed = Duration.zero;
  Duration _nextSpawnAt = _initialSpawnInterval;
  int _score = 0;
  int _streak = 0;
  int _lives = 3;
  bool _isPaused = false;
  bool _isGameOver = false;
  double _difficulty = 1.0;

  double _tiltX = 0;
  double _tiltY = 0;
  double _lastZ = 0;
  DateTime _lastImpactAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
    _accelerometerSub = accelerometerEvents.listen(_onAccelerometerEvent);
  }

  @override
  void dispose() {
    _accelerometerSub?.cancel();
    _ticker.dispose();
    super.dispose();
  }

  void _onAccelerometerEvent(AccelerometerEvent event) {
    if (_isPaused || _isGameOver) return;
    if (!mounted) return;

    setState(() {
      _tiltX = event.x;
      _tiltY = event.y;
    });

    final deltaZ = (event.z - _lastZ).abs();
    final now = DateTime.now();
    if (deltaZ > _impactDeltaThreshold &&
        event.z > _impactAbsoluteThreshold &&
        now.difference(_lastImpactAt) > const Duration(milliseconds: 300)) {
      _registerImpact();
      _lastImpactAt = now;
    }

    _lastZ = event.z;
  }

  void _onTick(Duration elapsed) {
    if (_isPaused || _isGameOver) return;

    setState(() {
      _elapsed = elapsed;
      _spawnMolesIfNeeded();
      _expireMoles();
      _adjustDifficulty();
    });
  }

  void _spawnMolesIfNeeded() {
    if (_elapsed < _nextSpawnAt) return;

    final freeHoles = List.generate(_gridSize * _gridSize, (i) => i)
        .where((index) => !_activeMoles.containsKey(index))
        .toList();

    if (freeHoles.isEmpty) {
      _nextSpawnAt += _currentSpawnInterval;
      return;
    }

    final holeIndex = freeHoles[_random.nextInt(freeHoles.length)];
    _activeMoles[holeIndex] = _Mole(spawnedAt: _elapsed);
    _nextSpawnAt = _elapsed + _currentSpawnInterval;
  }

  void _expireMoles() {
    final expired = _activeMoles.entries
        .where((entry) => _elapsed - entry.value.spawnedAt > _moleLifetime)
        .map((entry) => entry.key)
        .toList();

    for (final index in expired) {
      _activeMoles.remove(index);
      _registerMiss();
    }
  }

  void _registerImpact() {
    final targetIndex = _selectedHoleIndex;
    final mole = _activeMoles[targetIndex];
    if (mole != null) {
      final reactionTime = _elapsed - mole.spawnedAt;
      final timingBonus =
          (1.0 - (reactionTime.inMilliseconds / _moleLifetime.inMilliseconds))
              .clamp(0.3, 1.0);
      final baseScore = 100 + (_difficulty * 25).round();
      _score += (baseScore * timingBonus).round();
      _streak += 1;
      _activeMoles.remove(targetIndex);
    } else {
      _registerMiss();
    }
  }

  void _registerMiss() {
    _streak = 0;
    _lives = max(0, _lives - 1);
    if (_lives == 0) {
      _endGame();
    }
  }

  void _adjustDifficulty() {
    // Increase difficulty every 20 seconds or after streaks.
    final timeFactor = (_elapsed.inSeconds ~/ 20) + 1;
    final streakFactor = 1 + (_streak ~/ 5) * 0.05;
    _difficulty = (timeFactor * streakFactor).clamp(1.0, 3.5).toDouble();
  }

  void _togglePause() {
    setState(() {
      _isPaused = !_isPaused;
    });
  }

  void _restartGame() {
    setState(() {
      _activeMoles.clear();
      _elapsed = Duration.zero;
      _nextSpawnAt = _initialSpawnInterval;
      _score = 0;
      _streak = 0;
      _lives = 3;
      _isPaused = false;
      _isGameOver = false;
      _difficulty = 1.0;
    });
    _ticker.start();
  }

  void _endGame() {
    setState(() {
      _isGameOver = true;
    });
    _ticker.stop();
  }

  Duration get _currentSpawnInterval {
    final multiplier = max(0.35, 1 - ((_difficulty - 1) * 0.18));
    final nextMs =
        (_initialSpawnInterval.inMilliseconds * multiplier).round();
    final candidate = Duration(milliseconds: nextMs);
    return candidate < _minSpawnInterval ? _minSpawnInterval : candidate;
  }

  int get _selectedHoleIndex {
    // Map tilt (-8..8) to grid index (0.._gridSize-1).
    final normX = ((_tiltX / _tiltRange) + 1) / 2;
    final normY = ((-_tiltY / _tiltRange) + 1) / 2; // invert Y for UI
    final col = (normX * _gridSize).clamp(0, _gridSize - 0.001).floor();
    final row = (normY * _gridSize).clamp(0, _gridSize - 0.001).floor();
    return row * _gridSize + col;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selectedIndex = _selectedHoleIndex;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Mole Smash Rhythm'),
        actions: [
          IconButton(
            icon: Icon(_isPaused ? Icons.play_arrow : Icons.pause),
            onPressed: _isGameOver ? null : _togglePause,
            tooltip: _isPaused ? 'Wznów' : 'Pauza',
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _restartGame,
            tooltip: 'Restart',
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _ScoreTile(
                  label: 'Wynik',
                  value: _score.toString(),
                  icon: Icons.bolt,
                  color: theme.colorScheme.primary,
                ),
                _ScoreTile(
                  label: 'Streak',
                  value: 'x$_streak',
                  icon: Icons.trending_up,
                  color: theme.colorScheme.secondary,
                ),
                _ScoreTile(
                  label: 'Życia',
                  value: '$_lives',
                  icon: Icons.favorite,
                  color: Colors.pink,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Poziom: ${_difficulty.toStringAsFixed(1)}'),
                Text('Tempo: ${_currentSpawnInterval.inMilliseconds} ms'),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final size = min(constraints.maxWidth, constraints.maxHeight);
                final cellSize = size / _gridSize;
                return Center(
                  child: SizedBox(
                    width: size,
                    height: size,
                    child: Stack(
                      children: [
                        GridView.builder(
                          physics: const NeverScrollableScrollPhysics(),
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: _gridSize,
                          ),
                          itemCount: _gridSize * _gridSize,
                          itemBuilder: (context, index) {
                            final mole = _activeMoles[index];
                            final isSelected = index == selectedIndex;
                            return _MoleCell(
                              isActive: mole != null,
                              isSelected: isSelected,
                              progress: mole == null
                                  ? 0
                                  : ((_elapsed - mole.spawnedAt).inMilliseconds /
                                          _moleLifetime.inMilliseconds)
                                      .clamp(0.0, 1.0),
                            );
                          },
                        ),
                        Positioned(
                          left: (selectedIndex % _gridSize) * cellSize,
                          top: (selectedIndex ~/ _gridSize) * cellSize,
                          child: IgnorePointer(
                            child: SizedBox(
                              width: cellSize,
                              height: cellSize,
                              child: AnimatedOpacity(
                                duration: const Duration(milliseconds: 120),
                                opacity: _isPaused ? 0.3 : 1,
                                child: Container(
                                  margin: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    border: Border.all(
                                      color: theme.colorScheme.primary,
                                      width: 3,
                                    ),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              _isGameOver
                  ? 'Koniec gry! Naciśnij restart, aby zagrać ponownie.'
                  : 'Wychyl platformę, aby celować, i dynamicznie naciśnij, aby trafić krecika.',
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}

class _Mole {
  _Mole({required this.spawnedAt});

  final Duration spawnedAt;
}

class _MoleCell extends StatelessWidget {
  const _MoleCell({
    required this.isActive,
    required this.isSelected,
    required this.progress,
  });

  final bool isActive;
  final bool isSelected;
  final double progress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          color: isActive
              ? Color.lerp(Colors.greenAccent, Colors.redAccent, progress)
              : theme.colorScheme.surfaceVariant,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            if (isActive)
              BoxShadow(
                color: Colors.black.withOpacity(0.15),
                blurRadius: 8,
                offset: const Offset(0, 4),
              ),
          ],
          border: Border.all(
            color: isSelected
                ? theme.colorScheme.primary
                : theme.colorScheme.outlineVariant,
            width: isSelected ? 3 : 1,
          ),
        ),
        child: Center(
          child: isActive
              ? Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.pest_control, size: 32),
                    Text('${((1 - progress) * 100).clamp(0, 99).round()}%'),
                  ],
                )
              : const Icon(Icons.circle_outlined),
        ),
      ),
    );
  }
}

class _ScoreTile extends StatelessWidget {
  const _ScoreTile({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });

  final String label;
  final String value;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: Theme.of(context).textTheme.labelMedium,
              ),
              Text(
                value,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
