# Project Hammer — Game Design Document

Working title. A 3D physics-based demolition game built in Godot 4.6, GDScript
only, Jolt physics.

---

## 1. Core concept

Third-person over-the-shoulder. You swing a sledgehammer to demolish buildings
as fast as possible. Completion time earns coins; coins buy better equipment;
each level has a leaderboard ranked by time.

**Design pillars**

1. **The swing is the game.** Physics-driven, heavy, slightly out of control.
   Landing a good hit should feel earned.
2. **Buildings behave like buildings.** Structural collapse, not just chipping
   away at cubes. Working out *where* to hit is the puzzle.
3. **Speed is the score.** Every system serves "how fast can you flatten this".

---

## 2. Tech stack

| | |
|---|---|
| Engine | Godot 4.6 |
| Language | GDScript only, no C# |
| Physics | Jolt (Godot default — do not change) |
| Rendering | Forward+, D3D12 on Windows |
| Target | PC (Windows / Mac / Linux) |

---

## 3. Controls

| Action | Input |
|---|---|
| Move | WASD / left stick |
| Look | Mouse (only when not holding LMB) |
| Swing | **Hold LMB and throw the mouse around** |
| Jump | Space |
| Free cursor | Esc |

Holding LMB hands the mouse to the hammer instead of the camera. You can't
re-aim mid-swing — that's part of the clumsiness.

---

## 4. Systems as built (Milestone 1 — complete)

### 4.1 Destruction (`scripts/buildings/destructible.gd`)

A `Destructible` is a `Node3D` that generates a 3D grid of `RigidBody3D` chunks
at runtime from `size` × `grid_columns/rows/depth`. Chunks start frozen
(`FREEZE_MODE_STATIC`) and unfreeze when broken or when they lose support.

- `break_force_threshold` — impact needed to knock a chunk loose
- Damage bleeds to orthogonal neighbours at 40%, so hits knock out clusters
- Emits `chunk_destroyed` per piece

**Why frozen, not jointed:** the design doc originally called for
`Generic6DOFJoint3D` links. That's implemented behind `use_joints` but defaults
off — 45+ constrained bodies sag and jitter under Jolt. Freeze-until-hit is
stable and reads identically.

### 4.2 Structural collapse (`scripts/buildings/structural_manager.gd`)

Every 0.2s after a break, the manager builds a contact graph of all intact
chunks (one shape query each) and flood-fills outward from whatever touches the
ground. **Anything the fill can't reach has no load path down and collapses.**

This works across separate `Destructible` nodes and separate `.tscn` files —
they're different scenes that know nothing about each other, but they're
physically touching, so the graph connects them.

A downward-only probe was tried first and doesn't work: the middle of a 4×4 roof
has no wall beneath it and would fall on level load. It's held up sideways.

### 4.3 Debris

On break, a chunk becomes debris: mass ×0.3, scale ×0.8, damping raised. After
`debris_settle_time` (1.5s) it moves to physics layer 5, which neither the
player nor the hammer masks — you walk and swing straight through rubble, but it
still collides with ground and other debris.

The delay is deliberate: you want the moment where a flying chunk knocks others
loose, *then* have the wreckage stop mattering.

### 4.4 Swing (`scripts/player/hammer_swing.gd`)

The hammer is a free `RigidBody3D` with `top_level = true` — not joined or
parented to the player. An invisible target point is dragged by the mouse, and
a spring-damper pushes the hammer toward it:

```
force = (target - position) * stiffness * mass
      - velocity * damping * mass
      + gravity_compensation
```

Heavy mass + low stiffness = it lags, overshoots, keeps swinging. Damage is real
momentum (`mass × speed`) at contact, so a slow nudge does nothing and a wild arc
caves the wall in. Impacts above `stagger_threshold` shove the player and remove
control for `stagger_time`.

The rig pitches with the camera (`follow_camera_pitch`) so looking down lowers
the hammer to reach ground-floor chunks.

### 4.5 Economy and persistence

- `CurrencyManager` — Gold <60s = 150, Silver <120s = 75, Bronze = 25. Saved to `user://currency.save`.
- `LeaderboardManager` — top 3 times per level, `user://leaderboard.save`.
- `GameManager` — state machine, run timer, level start/complete signals.

Autoloads are accessed via `/root/GameManager` lookup, not the bare identifier —
a compile-time reference to a singleton takes down every consumer with a
misleading error if the autoload fails to load.

### 4.6 Physics layers

| Layer | Name | Used by |
|---|---|---|
| 1 | world | Ground, static scenery |
| 2 | destructible | Intact chunks |
| 3 | player | Player capsule |
| 4 | hammer | Hammer head |
| 5 | debris | Settled rubble (nothing masks it) |

---

## 5. Milestone 2 — A proper first level

**Goal:** replace the four-wall test box with a real two-storey house containing
rooms and furniture, and give the player a visible body. Blockout meshes only —
primitives, no art pass, no textures.

**Agreed scope**

- Two storeys, 3–4 rooms per floor
- Furniture is destructible, but softer than walls and worth less toward completion
- Full structural collapse: the upper floor rests on ground-floor walls, and
  bringing the whole thing down is the intended challenge
- Character is cylinder/box primitives — torso, head, two legs, two arms — plus
  the hammer

### Task 1 — Destruction weighting

Right now every chunk counts equally toward the 85%. A chair shouldn't be worth
as much as a load-bearing wall.

- Add `@export var destruction_weight: float = 1.0` to `Destructible`
- `StructuralManager` sums **weighted** totals rather than raw chunk counts:
  `total_weight += chunk_count * destruction_weight`
- Suggested values: structural walls `1.0`, floors `1.0`, interior partitions
  `0.7`, furniture `0.25`
- `destruction_percentage` becomes `destroyed_weight / total_weight`

**Why:** without this, adding furniture silently makes levels easier — 200 chair
chunks would dominate the percentage and you'd win without touching the house.

### Task 2 — Structural roles

Add `@export_enum("Structural", "Partition", "Furniture") var structural_role`
to `Destructible`, which sets sensible defaults for `break_force_threshold`,
`destruction_weight`, and `chunk_mass` in one go.

| Role | Threshold | Weight | Feel |
|---|---|---|---|
| Structural | 90 | 1.0 | Load-bearing. Tough. Holds the house up. |
| Partition | 45 | 0.7 | Interior walls. Two or three good hits. |
| Furniture | 20 | 0.25 | Explodes when looked at. |

**Design note:** load-bearing walls being genuinely tough is what makes collapse
an *achievement* rather than a shortcut. If structural walls were soft, the
optimal strategy would be to knock out two pillars and watch — which is a cool
moment once, but not a game.

### Task 3 — Furniture prefabs

Build as `Destructible` scenes with `structural_role = Furniture`:

| Prefab | Size (m) | Grid | Notes |
|---|---|---|---|
| `furniture_table` | 1.6 × 0.8 × 0.9 | 3×2×2 | Kitchen / dining |
| `furniture_chair` | 0.5 × 0.9 × 0.5 | 1×3×1 | Cheap, place several |
| `furniture_shelf` | 1.2 × 1.8 × 0.4 | 2×4×1 | Tall, topples well |
| `furniture_bed` | 2.0 × 0.5 × 1.4 | 3×1×3 | Upstairs rooms |
| `furniture_counter` | 2.4 × 0.9 × 0.6 | 4×2×1 | Kitchen run |

All primitives. No art.

### Task 4 — Room and building composition

Add `scripts/buildings/room_builder.gd` — a tool script that generates a
rectangular room from exports rather than hand-placing walls:

- `room_size: Vector3`, `wall_thickness`, `has_ceiling: bool`
- `doorways: Array[Vector2]` — positions along each wall to leave gaps
- Spawns four `Destructible` walls with the correct role, skipping doorway spans
- `@tool` annotation so rooms preview in the editor

**Why generate rather than place by hand:** a two-storey, 7-room house is ~30
wall segments. Placing those manually and re-placing them every time you retune
a size is the kind of task that quietly kills momentum.

### Task 5 — Level 02: the house

`scenes/levels/level_02_house.tscn`

```
Ground floor (~10 x 8m)     Upper floor
├── Living room             ├── Bedroom 1
├── Kitchen                 ├── Bedroom 2
├── Hallway (stairs)        └── Bathroom
└── Back room
```

- Ground-floor exterior walls: `Structural`
- Interior dividers: `Partition`
- **First-floor slab is a `Destructible` with role `Structural`** resting on the
  ground-floor walls — this is what makes the upper storey pancake
- Roof on top of the upper walls
- Furniture scattered per room, 3–6 pieces each
- Player spawns outside the front

**Target: 400–600 chunks.** Profile before adding more.

### Task 6 — Character model

`scenes/player/character_mesh.tscn`, added under `Player`. Primitives only:

```
CharacterMesh          (Node3D)
├── Torso              (CylinderMesh, h 0.9, r 0.25)
├── Head               (SphereMesh, r 0.18)
├── LegL / LegR        (CylinderMesh, h 0.8, r 0.1)
├── ArmL / ArmR        (CylinderMesh, h 0.7, r 0.08)
```

Then `scripts/player/character_rig.gd`:

- Arms **procedurally point at the hammer** every frame — `look_at` from the
  shoulder toward `hammer.global_position`, and stretch the arm cylinder to
  match the distance (clamped so it doesn't go rubbery)
- Legs do a simple two-frame walk cycle driven by horizontal velocity — no
  animation player, just alternating rotation on a sine wave
- Torso leans into the swing direction based on hammer offset from rest

**Why no skeleton:** rigid arms that track the hammer sell "person holding a
sledgehammer" at 5% of the cost of a `Skeleton3D` + `SkeletonIK3D` setup, and
none of that work survives contact with a real character model later. Revisit
when there's art worth rigging.

### Task 7 — Performance pass

400–600 chunks is 5–10× Milestone 1. Before it's playable:

- Set `debris_lifetime` to ~20s so rubble cleans itself up
- Cap `StructuralManager` collapse checks — currently one shape query per intact
  chunk per check. At 600 chunks and 0.2s intervals that's 3000 queries/sec.
  **Fix: only re-probe chunks within N metres of the break**, not the whole level
- Ensure frozen chunks are genuinely sleeping (`can_sleep = true`)
- Consider `MultiMeshInstance3D` for intact chunks if draw calls become the
  bottleneck

**This task is not optional and should be done alongside Task 5, not after.**
Building the whole house and then discovering it runs at 12fps means unpicking
level design decisions that were made for the wrong reasons.

### Task 8 — Level complete screen

`scenes/ui/level_complete.tscn`

- Final time, tier earned (Gold / Silver / Bronze), coins awarded
- Top 3 leaderboard times for the level
- Retry / Level select buttons

### Exit criteria for Milestone 2

- [ ] Two-storey house loads and stands stably at rest (no sag, no jitter)
- [ ] Player has a visible body; arms track the hammer; legs move when walking
- [ ] Furniture breaks easily and contributes proportionally less to the bar
- [ ] Knocking out enough ground-floor structural walls pancakes the upper storey
- [ ] Holds 60fps during a full collapse
- [ ] Level complete screen shows time, tier, coins and leaderboard

---

## 6. Milestone 3 — Economy (not started)

Shop UI, equipment tiers, currency spending, level select, main menu.

Open question: does a better hammer raise `max_follow_force`, `mass`, or both?
Mass is the more interesting lever — a heavier hammer hits harder *and* is
clumsier, which is a real trade-off rather than a straight upgrade.

## 7. Milestone 4 — Polish (not started)

Sound, particles, camera shake, dust on collapse, art pass.

---

## 8. Open questions

- Should the hammer collide with the ground while idle, or ghost through it?
  Currently collides, so it can snag on scenery.
- Do collapsed chunks count for full credit, or less than smashed ones? Full
  credit today. If collapse trivialises levels, add a `collapse_credit`
  multiplier around 0.6.
- Stairs: real geometry the player walks up, or does the player just jump/climb
  rubble to reach the first floor? Leaning toward rubble-climbing — it makes
  your own destruction into the traversal.
- Does the 85% threshold still make sense at 600 chunks, or should later levels
  use a lower bar with a time bonus for going further?
