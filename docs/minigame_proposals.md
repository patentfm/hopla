# Mini-game Concepts for Hopla Balance Platform

This document captures candidate mini-games designed for tilt and impact input from the balance board's accelerometer (or future BLE XYZ feed). Each game is framed to run indefinitely until the player loses all lives and includes a built-in difficulty scaling loop.

## Shared Framework Assumptions
- **Engine**: Flame
- **Audio**: flame_audio
- **Physics**: flame_forge2d where collision/impulse fidelity is needed
- **Input**: HoplaInput stream providing `tiltX`, `tiltY`, `impact`, `isStable` events (calibrated + filtered)
- **Lifecycle**: `MinigameDefinition` (`id`, name, description, icon, parameters, `createGame()`), shared `GameSession` (time, score, difficulty, pause, save), registry-driven menu, and unified HUD/overlays

## Candidate Endless Mini-Games
1. **Tilt Runner**
   - *Loop*: Auto-runner on a narrow lane; tilt steers left/right to dodge obstacles and collect tokens.
   - *Impact use*: Tap/impact triggers a short hop over low hazards.
   - *Difficulty*: Speed gradually increases; obstacle density and token placement tighten after streaks.

2. **Plate Balancer**
   - *Loop*: Keep a virtual plate level while balls spawn and roll; tilt counters gravity to keep balls on board.
   - *Impact use*: Quick compress resets ball drift or ejects a single hazard ball.
   - *Difficulty*: More balls over time; gravity bias and ball speed increase based on stability streaks.

3. **Geyser Jump**
   - *Loop*: Stand on a platform over geysers that erupt; time impacts to launch over jets while tilting to land safely.
   - *Impact use*: Main jump impulse; repeated rhythmic presses chain higher jumps.
   - *Difficulty*: Shorter warning windows and moving landing pads after consistent success.

4. **Skyline Surfer**
   - *Loop*: Side-scrolling glider; tilt controls pitch/roll to pass checkpoints and ride thermal updrafts.
   - *Impact use*: Burst dash to cut wind resistance or break through weak barriers.
   - *Difficulty*: Stronger gusts, narrower gaps, and more vertical variance as score climbs.

5. **Mole Smash Rhythm**
   - *Loop*: Whac-a-mole grid; tilting highlights lanes, impact smashes highlighted tile on beat.
   - *Impact use*: Primary hit; combos build if timed with beat pulses.
   - *Difficulty*: Faster beats, trick moles (decoys, multi-hit) and lane swaps after streaks.

6. **Orb Collector**
   - *Loop*: Top-down arena; tilt moves a magnet to gather roaming orbs while avoiding spiky mines.
   - *Impact use*: Short shockwave that converts nearby mines into orbs once per charge.
   - *Difficulty*: More mines, faster orb drift, and reduced shockwave cooldown as score rises.

7. **Rope Bridge Runner**
   - *Loop*: Balance on a swaying rope bridge; tilt to counter sway and step over gaps.
   - *Impact use*: Stomp to stabilize the bridge temporarily or flatten loose planks.
   - *Difficulty*: Sway amplitude and gap frequency increase; wind gusts appear during high stability.

8. **Fruit Stack**
   - *Loop*: Catch falling fruit on a tray; tilt positions tray, impact compacts the stack to prevent spills.
   - *Impact use*: Compress stack to reduce bounce or clear rotten fruit.
   - *Difficulty*: Faster drops, mixed weights, and random bounce forces; compact window shrinks after streaks.

9. **Laser Gates**
   - *Loop*: Navigate through rotating laser grids; tilt aligns avatar with safe openings.
   - *Impact use*: Brief phase/slide move to pass tight gates.
   - *Difficulty*: Gate rotation speed and pattern complexity ramp up; fewer safe slots after clean runs.

10. **Bubble Diver**
    - *Loop*: Descend through underwater caverns; tilt steers, maintain buoyancy; collect air bubbles.
    - *Impact use*: Propel upward burst to dodge floor hazards or reset buoyancy.
    - *Difficulty*: Cavern width narrows; bubble frequency drops; drifting currents introduce drift when player is steady.

## Difficulty Auto-Scaling Ideas
- Track short rolling performance (streaks, misses, hit timing) to adjust spawn timers, speeds, and forgiveness windows.
- Apply ceiling/floor on difficulty to avoid frustration or boredom.
- Use shared `difficulty` field in `GameSession` to coordinate HUD indicators and analytics.

## Input Mapping Notes
- Map tilt magnitude to analog movement; deadzone derived from `isStable` periods.
- Use impact thresholding plus cooldown to distinguish intentional presses from landing noise.
- Consider low-pass filtering and auto-calibration per session to ensure neutrality when user stands centered.

