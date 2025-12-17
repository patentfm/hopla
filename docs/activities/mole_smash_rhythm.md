# Mole Smash Rhythm Activity (Flame)

Design for an endless whac-a-mole rhythm mini-game controlled by the Hopla balance platform. The activity uses tilt to select lanes and platform impacts to smash moles on-beat. Difficulty scales automatically based on player accuracy and streaks.

## Core Loop
- Music-driven beat timeline spawns moles on a 3x3 grid (rows represent lanes selectable by tilt, columns by timed beats).
- Player tilts left/center/right to choose a lane highlight; a platform stomp during a beat window smashes the currently highlighted tile.
- Combos and multipliers grow with consecutive on-beat hits; mistakes reduce lives. The session ends when lives reach zero.
- Between waves, short breathers introduce special moles (decoys, shields, multi-hit) and optionally lane swap events to force quick tilt corrections.

## Controls
- **Tilt (analog)**: maps to three lane zones with a deadzone for center. Smooth interpolation keeps highlight stable.
- **Impact**: stomp/press within the beat window to register a hit on the highlighted lane tile. Cooldown and force threshold filter noise.
- **Stability hint**: when `isStable` is true for >1s, auto-center highlight to reduce drift before the next wave.

## Difficulty & Scaling
- Start at difficulty = 1.0. Adjust every 10–15 beats:
  - Increase beat tempo (BPM) slightly on streaks; decrease after misses.
  - Spawn patterns with more simultaneous moles and trick types as streaks grow.
  - Shrink hit windows from 180ms toward a 90ms floor; widen after multiple misses.
- Clamp difficulty between 0.8 and 2.5 to avoid extremes.
- Track metrics: `streak`, `recentAccuracy` (rolling 20 hits), `lateEarlyBias` (to auto-shift timing offset).

## Entities & Components
- **BeatConductor**: maintains BPM, beat timeline, and hit windows; exposes `onBeat`, `onPreBeat` streams.
- **LaneSelector**: maps tilt to lane index (0, 1, 2) with hysteresis; controls lane highlight visuals.
- **MoleSpawner**: schedules mole patterns (single, double, decoy, shielded, multi-hit) based on difficulty.
- **Mole**: state machine (hidden → popping → hittable → escape); properties: `type`, `hp`, `spawnBeat`, `despawnBeat`.
- **ImpactHandler**: filters raw impact data, enforces cooldown, and routes hits to the active mole on the highlighted lane.
- **ScoreSystem**: computes points, combo/multiplier, and life changes; applies accuracy-based difficulty nudges.
- **HUDOverlay**: shows score, multiplier, lives, difficulty meter, upcoming beat hint bar, and pause/tutorial overlays.

## Input Mapping
- Expect normalized `tiltX` in [-1, 1]. Zones: left ≤ -0.25, center between -0.25..0.25, right ≥ 0.25. Add 0.05 hysteresis to prevent jitter.
- Impact registered when vertical acceleration spike > threshold and outside a 250ms cooldown. Use a 120ms grace window around beat center (shrinks with difficulty).
- Calibrate neutral tilt during countdown; apply a 0.2s low-pass filter to `tiltX` for smoothness.

## Session Flow
1. **Countdown/Tutorial**: show lane selection practice and first beat flash; auto-calibrate neutral tilt.
2. **Play**: run beat loop with dynamic difficulty. Missed moles cost life; off-beat impacts drain multiplier.
3. **Wave Breaks**: every ~30 beats, insert a 2-beat breather with only decoy flashes to reset tempo or introduce new mole types.
4. **Game Over**: when lives == 0, show results (score, best streak, accuracy, difficulty reached) and offer restart.

## Data Contracts (aligning with shared framework)
- `MinigameDefinition`: id `mole-smash-rhythm`, name, description, icon, default params (starting BPM, lanes=3, initial lives=3, hitWindowMs=180), and `createGame()` returning Flame `Game` instance.
- `GameSession`: stores score, streak, lives, difficulty, elapsed beats/time, pause state, and `recentAccuracy` buffer.
- `HoplaInput`: provides filtered `tiltX`, `impact`, `isStable`; preprocess with calibration + normalization before reaching the game.

## Pseudocode (Flame-style)
```dart
class MoleSmashRhythmGame extends FlameGame with HasCollisionDetection {
  final HoplaInput input;
  final GameSession session;
  late final BeatConductor beat;
  late final LaneSelector laneSelector;
  late final MoleSpawner spawner;
  late final ImpactHandler impacts;
  late final ScoreSystem scoring;

  @override
  Future<void> onLoad() async {
    beat = BeatConductor(startBpm: params.startBpm);
    laneSelector = LaneSelector(lanes: 3, deadzone: 0.25, hysteresis: 0.05);
    spawner = MoleSpawner(beat: beat, difficulty: () => session.difficulty);
    impacts = ImpactHandler(input: input, cooldown: 0.25, forceThreshold: params.impactThreshold);
    scoring = ScoreSystem(session: session);

    addAll([beat, laneSelector, spawner, impacts, scoring, HUDOverlay(session: session)]);

    impacts.onBeatHit.listen((BeatHit hit) {
      final lane = laneSelector.currentLane;
      final mole = spawner.activeMoleOnLane(lane);
      if (mole != null && beat.isWithinWindow(hit.time)) {
        mole.hit();
        scoring.registerHit(hit.timingErrorMs);
      } else {
        scoring.registerMiss();
      }
    });

    beat.onBeat.listen((beatIndex) {
      spawner.maybeSpawn(beatIndex);
      scoring.onBeat(beatIndex);
      adjustDifficulty();
    });
  }

  void adjustDifficulty() {
    session.difficulty = clampDouble(
      session.difficulty + scoring.difficultyDelta(),
      0.8,
      2.5,
    );
    beat.updateTempo(session.difficulty);
    spawner.updatePatterns(session.difficulty);
    impacts.updateWindow(session.difficulty);
  }
}
```

## Art & Audio Notes
- Visual clarity: three big lane pedestals with strong highlight colors; beat bar across the bottom showing upcoming hits.
- Audio: metronome tick or music loop; impact SFX variants for normal, shield break, and miss; soft whoosh for lane swaps.

## Testing Checklist
- Verify tilt zones switch lanes without jitter across devices and that `isStable` recenters after calibration.
- Confirm hit registration within shrinking beat windows and proper cooldown handling.
- Simulate difficulty climbing/decaying based on synthetic streak/miss sequences.
- Ensure game over/resume/pause flows integrate with shared HUD overlays.

## Future Extensions
- Add swipe-style diagonals by combining tiltX + tiltY for 5-lane mode.
- Introduce boss moles with patterned shields requiring rhythmic double impacts.
- Sync beat timeline with music BPM detection if custom tracks are allowed.
