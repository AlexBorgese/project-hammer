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

**Revised: stability, not connectivity.** The flood fill only asked "is there
any path to the ground?" In play, two surviving interior wall stubs — and the
top step of the staircase — held up the entire upper storey, because everything
was connected to them through the floor slab. Connectivity isn't load capacity.

Each chunk now gets a stability value. Grounded chunks start at 100; support
passed straight up is free, support passed sideways costs `100 / max_span` per
metre, and hanging below a supporter costs double. A chunk falls when its best
reachable stability hits zero. With `max_span = 3.0`, a few stubs can hold up
the slab within ~3m of themselves and the rest of the storey drops.

Stairs are no longer load-bearing by default — each step is a solid column from
the floor and stands on its own, and stairs shouldn't hold up floors.

`debug_collapse` tints standing chunks green → red by stability.

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

### 4.6 Material roles and weighting

`Destructible.structural_role` sets three tuning values at once:

| Role | Threshold | Weight | Mass | Load-bearing |
|---|---|---|---|---|
| Structural | 90 | 1.0 | 12 | yes |
| Partition | 45 | 0.7 | 7 | yes |
| Furniture | 20 | 0.25 | 3 | **no** |

Completion is measured by **weight**, not chunk count:
`destruction_percentage = destroyed_weight / total_weight`. A chunk of chair is
worth a quarter of a chunk of wall, so ~24 pieces of furniture across a house
comes to roughly 13% of level weight — worth smashing, impossible to win on.

The role setter only rewrites values **in the editor**, never at runtime.
Applying presets on load would clobber whatever the `.tscn` saved and would
silently depend on the order Godot restores properties in. In `.tscn` files,
`structural_role` must be listed *before* the values it presets.

`is_load_bearing = false` (automatic for Furniture) excludes an object from the
structural graph entirely. A chair holds nothing up, so asking "does this chair
have a load path to the ground?" is a question that should never be asked — and
asking it was what made furniture collapse on level load.

### 4.7 Level generation

`FloorPlan` (`@tool`) builds one storey from a grid layout:

```
layout = ["LLK",
		  "HHB"]
```

One string per row, one character per cell, same character = same room. Walls
are built only where adjacent cells **differ**, which gives shared walls for
free — `L|L` builds nothing, `L|K` builds a partition, `L|outside` builds a
structural exterior wall. Roles are assigned by that same rule.

Doorways are punched automatically between differing rooms, splitting the wall
into two segments. `stairwell_cells` omits floor cells so a staircase has
somewhere to arrive.

Floors are built **one slab per cell** rather than one sheet, so a floor can
partially collapse and so stairwell cells can simply be skipped.

Stack storeys by placing a second `FloorPlan` at `y = cell_size.y`. No wiring
needed — the collapse graph is spatial, so upper walls find lower walls as
support automatically.

`Staircase` (`@tool`) generates one `Destructible` per step, each a solid wedge
from floor to tread height rather than a floating slab, so steps hold each
other up properly.

Because `Destructible` builds no chunks in the editor, it draws one translucent
ghost box instead, colour-coded by role — grey structural, blue partition,
amber furniture. Preview meshes are given no owner, so they're never saved.

### 4.8 Ladder and climbing

The staircase is destructible and sits in a hallway you'll be smashing anyway.
Destroy it and the **ladder** becomes the only route upstairs.

The player carries exactly one ladder; **G** places it in front, G again nearby
picks it back up. Carrying one means where you leave it is a real decision.

Walking into a ladder's `Area3D` starts a climb: gravity off, W/S vertical, A/D
shuffle, jump to let go. Reaching the top applies a forward nudge so you step
onto the ledge rather than sliding back down the face — the absence of that
nudge is what makes most ladder implementations feel broken.

### 4.9 Camera in interiors

A 3m third-person boom is inside a wall in any real interior. Raising ceilings
moves the problem rather than fixing it.

`CameraRig` (on the `SpringArm3D`) sphere-casts backwards each physics frame
and applies **asymmetric** smoothing:

- pulls in almost instantly when blocked — so it can never end up inside geometry
- eases out slowly when clear — so it doesn't lurch past every doorway

It sphere-casts rather than raycasts because a ray threads through gaps the
camera's near plane cannot, which produces "mostly works, occasionally pops
through a wall". The obstruction mask is world + destructible and **must not**
include debris, or flying rubble yanks the view.

### 4.10 Physics layers

| Layer | Name | Used by |
|---|---|---|
| 1 | world | Ground, static scenery |
| 2 | destructible | Intact chunks |
| 3 | player | Player capsule |
| 4 | hammer | Hammer head |
| 5 | debris | Settled rubble (nothing masks it) |
| 6 | climbable | Ladder climb volumes |

---

## 5. Milestone 2 — A proper first level

**Goal:** replace the four-wall test box with a real two-storey house containing
rooms and furniture, and give the player a visible body. Blockout meshes only —
primitives, no art pass, no textures.

**Status: substantially complete.** All systems built and verified in play.
Remaining: dress the house with furniture, add a roof, level complete screen.

| # | Task | Status |
|---|---|---|
| 1 | Destruction weighting | ✅ |
| 2 | Structural roles | ✅ |
| 3 | Furniture prefabs | ✅ five prefabs |
| 4 | Level generation (`FloorPlan`) | ✅ |
| 5 | Two-storey house | 🔶 shell stands; furniture to place |
| 6 | Character model and rig | ✅ |
| 7 | Performance pass | ✅ pulled forward |
| 8 | Level complete screen | ⬜ not started |
| 9 | Destructible staircase | ✅ |
| 10 | Ladder item and climbing | ✅ |
| 11 | Interior camera | ✅ |

**Scope changes agreed during the milestone**

- Furniture is **hand-placed**, not auto-scattered — the auto-scatter tool was
  specced and then dropped in favour of authored placement.
- Stairs are destructible **and** a ladder item was added as the fallback route
  upstairs. This wasn't in the original milestone; it turns "how do I get up
  there" into a consequence of your own demolition.

**Bugs found and fixed in play**

- Furniture fell apart on level load — it was in the structural graph and being
  judged unsupported. Furniture is now excluded via `is_load_bearing = false`.
- Camera pushed through walls and ceilings indoors — the `SpringArm3D` mask was
  world-only and never saw the building.
- Upper floor slab sealed the stairwell — floors are now per-cell with
  `stairwell_cells` to omit them.

### Task 3 reference — furniture prefabs

Built as `Destructible` scenes with `structural_role = Furniture`. Thresholds
vary a little by type — a chair should disintegrate, a counter should take a
real hit — while all sit far below a partition at 45.

| Prefab | Size (m) | Grid | Notes |
|---|---|---|---|
| `furniture_table` | 1.6 × 0.8 × 0.9 | 3×2×2 | Kitchen / dining |
| `furniture_chair` | 0.5 × 0.9 × 0.5 | 1×3×1 | Cheap, place several |
| `furniture_shelf` | 1.2 × 1.8 × 0.4 | 2×4×1 | Tall, topples well |
| `furniture_bed` | 2.0 × 0.5 × 1.4 | 3×1×3 | Upstairs rooms |
| `furniture_counter` | 2.4 × 0.9 × 0.6 | 4×2×1 | Kitchen run |

All primitives. No art.

### Task 4 — Level generation ✅ DONE

Built as `FloorPlan` rather than the per-room `room_builder` originally specced.
A per-room builder would have made two adjacent rooms each construct their own
wall — double the chunks and a z-fighting seam down every shared boundary. A
grid floor plan builds each wall once. See §4.7.

### Task 5 — Level 02: the house 🔶 SHELL DONE

`scenes/levels/level_02_house.tscn`

```
Ground floor  ["LLK",     Upper floor  ["AAB",
			   "HHB"]                   "LLB"]
├── L Living room (2 cells)   ├── A Bedroom (2 cells)
├── K Kitchen                 ├── B Bathroom (2 cells)
└── H Hallway (2 cells)       └── L Landing (2 cells)
	B Back room
```

Two `FloorPlan` nodes, upper at `y = 3.0`. `cell_size` `(4, 3, 4)`, grid 3×2.
Stairwell at cell `(0, 1)`; staircase instanced at `(-4, 0, 2)`.

**Verified in play:** both storeys stand stably, upper walls register the lower
walls as support, the camera survives the interior.

**Remaining:** hand-place furniture (3–6 pieces per room), add a roof, and move
the player spawn outside the front.

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

### Task 7 — Performance pass ✅ DONE (pulled forward)

**Done:** the contact graph is now cached instead of rebuilt every check.

The original plan here said "only re-probe chunks within N metres of the break."
That was wrong as stated — probing is local, but flood-fill *reachability* is
global. Knocking out a ground-floor wall can unsupport a roof chunk 8m away, so
the fill has to stay whole-level.

What actually works: intact chunks are frozen, so they never move, so their
contact links can't change while intact. Build the graph once at level load,
mark only the neighbours of a break as dirty, re-probe just those, and run the
fill over the cache. The fill is a pure memory walk — microseconds over 600
nodes.

Cost went from ~600 shape queries every 0.2s to ~600 once at load plus 10–20
per break. Probe shape and query params are also reused rather than allocated
per chunk per check.

**Known consequence:** fallen debris doesn't create *new* support in the cached
graph — a pile of rubble won't hold up a wall. This matches the old behaviour
and is arguably correct, but it's a design choice, not just an optimisation.

Still open for later if needed:

- Set `debris_lifetime` to ~20s so rubble cleans itself up
- Ensure frozen chunks are genuinely sleeping (`can_sleep = true`)
- `MultiMeshInstance3D` for intact chunks if draw calls become the bottleneck

### Task 8 — Level complete screen

`scenes/ui/level_complete.tscn`

- Final time, tier earned (Gold / Silver / Bronze), coins awarded
- Top 3 leaderboard times for the level
- Retry / Level select buttons

### Task 9 — Destructible staircase ✅ DONE

Added mid-milestone, not in the original spec. `Staircase` (`@tool`) generates
one `Destructible` per step. See §4.7.

### Task 10 — Ladder and climbing ✅ DONE

Added mid-milestone. The consequence of making stairs destructible: there has to
be another way up. See §4.8.

### Task 11 — Interior camera ✅ DONE

Added mid-milestone, in response to the camera clipping through the first-floor
slab. See §4.9.

### Exit criteria for Milestone 2

- [x] Two-storey house loads and stands stably at rest (no sag, no jitter)
- [x] Player has a visible body; arms track the hammer; legs move when walking
- [x] Furniture breaks easily and contributes proportionally less to the bar
- [x] Camera works in interiors without clipping
- [x] Stairs are destructible, with the ladder as a fallback route up
- [x] Knocking out enough ground-floor structural walls pancakes the upper storey
- [ ] Holds 60fps during a full collapse
- [ ] House is furnished and has a roof
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
- ~~Stairs, or climb your own rubble?~~ **Decided:** destructible stairs plus a
  carryable ladder as the fallback.
- Does the 85% threshold still make sense at 600 chunks, or should later levels
  use a lower bar with a time bonus for going further?
- Climbing currently overrides stagger, so a hammer blow can't knock you off a
  ladder. Should it?
- Stairs are `Partition` role, so they'll often be destroyed incidentally while
  clearing the hallway rather than deliberately. That makes the ladder a recovery
  from carelessness rather than a chosen tactic — probably the better version,
  but worth confirming in play.
- A 0.6m camera boom in a 4×4m room may still feel cramped. If so the honest fix
  is near-first-person indoors, which is a bigger design call.
- `front_door` punches a doorway in upper storeys too — a door to nowhere three
  metres up. Currently untick it per-storey; could be automatic.
