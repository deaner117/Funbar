# Sam and Dean Worldwide: handoff notes

This document is for the next developer or AI picking up the project. It covers what the app is,
how it is put together, how to build, test and ship it, what has been done so far (and why),
the gotchas found along the way, and what's next. `CLAUDE.md` at the repo root is the short
version.

---

## 1. What it is

A **social VR hangout for Meta Quest 3**: a mansion that two (up to four) friends in different
places join with a shared room code, see each other (head, body, realistic hands, name tag),
talk by voice and play together. The owners are Sam and Dean, and the mansion is named after them
("Sam and Dean Worldwide"). The project folder, Godot project path and Android package are still
called **hangout-mansion** / `com.homebrew.hangoutmansion` (renaming the package would install
as a separate app).

- Engine: **Godot 4.7.2** (GDScript only, no C#), **OpenXR**, mobile renderer, Jolt physics,
  90 Hz on Quest 3.
- No scenes or imported art: `main.tscn` is a single node with `main.gd`; **every mesh,
  material, texture and sound is generated in code** (boxes, rounded boxes, cylinders, tubes,
  MultiMeshes, procedural noise/pattern textures, synthesized audio). That keeps the repo
  small and everything editable as text.
- Multiplayer: a tiny **Cloudflare Worker relay** (`server/`), one Durable Object per room code,
  that forwards messages verbatim. All game logic runs in the headsets.

### Rooms (see the ASCII map at the top of `mansion.gd`)

| Room | Where (floor rect, metres) | Contents |
|---|---|---|
| Grand Hall | x -7..7, z -7..7, 6 m high | spawn, sofas, coffee table with the **throwable cake**, chandelier with glowing bulbs, welcome board, name sign |
| Game Room | north, z -19..-7 | air hockey, Connect Four, arcade cabinets, bar with stools/bottles |
| Gym | east, x 7..21 | basketball hoop, ball rack, scoreboard, bleachers |
| Lounge | west, x -21..-7 | recessed stone **fireplace with a real fire**, sofas, bookshelves full of books, card table, **jukebox** |
| Patio | south, x -10..10, z 7..21 (outdoors, sunset) | sunken **pool** (water shader, ladder, floats), **fire pit** (stone ring, fire, marshmallow stand, woodpile), **gas BBQ** with meat, **drinks cooler**, umbrella tables, loungers, **string lights on wires**, two **outdoor speakers** |
| Lawn | south of the patio, through a gap in the railing | **cornhole** (2 boards, red/blue bags), hedges, flowers, trees |

North is -z and east is +x. The floor is at y = 0 everywhere; the lawn is at y = -0.05.

---

## 2. Repository layout

```
main.gd            Orchestrator: XR start, player rig (origin/camera/hands/body), movement,
                   menu, settings, networking, routing messages to modules, desktop screenshots
main.tscn          Just a Node3D with main.gd
mansion.gd         Builds every room, the patio, pool, string lights and grounds. Exposes
                   spawns, anchors (where games/props go), rooms (for "where's my friend"),
                   structure (nodes hidden in passthrough mode)
kit.gd             Static helpers: layers, cached materials/meshes, add_box/rbox/cylinder/
                   sphere/label/omni, rounded-box mesh, tube mesh, catenary, MultiMesh,
                   procedural textures (tex/tmat), halo glow material, transform packing
fire.gd            A fire: logs with a glowing-ember shader, coal bed, GPU particle flames
                   (core and tongues), embers, spark bursts, smoke, flickering light, ground
                   glow, procedural crackle. heat_at(), contains(), stoke(); hands in it get
                   sparks and haptics
props.gd           Throwable props and their fixtures (BBQ, cooler, woodpile, marshmallow
                   stand, cornhole boards) plus all their interactions (see section 5)
hand.gd            The local XRController3D: grab/release, trigger presses via laser, throw
                   velocity, haptics; shows a HandModel whose fingers follow grip/trigger
hand_model.gd      A procedural human hand (palm, thumb pad, wrist, 5 jointed fingers with
                   nails, a wristband in the player's colour). Right is modelled; left mirrors it
avatar.gd          A remote friend: head + visor, torso, two HandModels (finger curls from the
                   network), name tag, voice player
air_hockey.gd, connect_four.gd, basketball.gd, jukebox.gd   The games (jukebox also drives the
                   outdoor speakers via add_speaker())
menu.gd            Wrist/face menu: Home (room code keypad, join/leave), Travel, Me (name,
                   colour), Settings (turning, speed, mute, passthrough, eye height)
button3d.gd        Laser-pressable 3D button
net.gd             WebSocket client with reconnect/backoff, JSON + binary messages
voice.gd           Mic capture -> 16 kHz mu-law packets -> relay -> AudioStreamGenerator on
                   each avatar's head
server/            Cloudflare Worker relay (src/index.js, wrangler.toml, package.json)
tests/_multi.gd    Two full players in one process (SubViewports with own worlds) against a
                   local relay; 42 checks across every system
build.ps1          Exports build/HangoutMansion.apk (debug-signed)
deploy.ps1         Installs and launches on the Quest over USB or Wi-Fi adb (-Build, -Log, -Wifi)
screenshot.ps1     Takes a screenshot inside the headset (Oculus metacam) and pulls it
addons/godotopenxrvendors/   Godot OpenXR Vendors plugin 5.1.0 (Meta loader); committed
openxr_action_map.tres, export_presets.cfg, project.godot
```

Ignored and not in git: `.godot/`, `android/` (the Gradle build template is reinstalled by
build.ps1), `build/`, `tools/` (the Godot executables), `screenshots/`,
`server/node_modules`, `server/.wrangler`, and `quest-ip.txt` (the headset's LAN IP).

---

## 3. Setting up a machine

1. **Godot 4.7.2 stable (standard, not .NET)**. Put `Godot_v4.7.2-stable_win64.exe` and
   `Godot_v4.7.2-stable_win64_console.exe` in `tools/`. The scripts expect exactly those paths.
2. **Export templates 4.7.2** installed in Godot (Editor > Manage Export Templates).
3. **Android export settings** (Editor Settings > Export > Android). On the original PC:
   - Java SDK: `C:\Program Files\Microsoft\jdk-17.0.20.8-hotspot\`
   - Android SDK: `C:\Users\deank\Development\AndroidSDK`. It needs platform-tools, build-tools
     and the platform API that Godot 4.7 asks for. `adb` is used from this SDK.
   - Debug keystore: Godot's default (`%APPDATA%\Godot\keystores\debug.keystore`, pass
     `android`)
4. **Quest 3 in Developer Mode**, with USB debugging allowed for the PC. Running
   `.\deploy.ps1 -Wifi` once over USB enables Wi-Fi adb and writes `quest-ip.txt`. Repeat it
   after the headset reboots.
5. **Node.js** (for wrangler) to run or deploy the relay.

---

## 4. Build, run, test, ship

```powershell
.\build.ps1                       # -> build\HangoutMansion.apk (~90 MB, debug)
.\deploy.ps1                      # install + launch (USB if plugged in, else Wi-Fi)
.\deploy.ps1 -Build -Log          # rebuild, install, launch, stream the godot log
.\screenshot.ps1                  # grab what the headset shows -> screenshots\*.jpg
adb logcat -d -s godot            # the app prints "Stats: fps, draw calls, ..." every 2 s
```

**Desktop (laptop) mode** has no XR. Use WASD and the mouse (click to capture), Q/E to turn and
M for the menu:
```powershell
tools\Godot_v4.7.2-stable_win64.exe --xr-mode off --path . -- --solo
```

**Screenshots of every area** are the quickest visual check after changing the mansion. They
include close-ups of the fire pit, BBQ, pool, string lights, fireplace, lawn and cake. There is
also a `hands` view with both HandModels in front of the camera, the left one open and the
right one in a fist:
```powershell
tools\Godot_v4.7.2-stable_win64_console.exe --xr-mode off --path . --resolution 1280x720 -- --solo --shots=<absolute dir>
```

**Two-player test** (run this after any gameplay or network change; it should print
`42 passed, 0 failed`):
```powershell
cd server; npx wrangler dev --port 8787      # in another terminal
tools\Godot_v4.7.2-stable_win64_console.exe --headless --xr-mode off --path . -s tests/_multi.gd
```

**Relay deploy** (only if `server/` changes): `cd server; npx wrangler login; npm run deploy`.
The live relay is `wss://hangout-mansion.usa-vs-vietnam-relay.workers.dev` (`DEFAULT_SERVER`
in main.gd). It runs on the owner's Cloudflare account, the same one used by their earlier
"USA vs Vietnam" beer-pong app.

**Playing with a friend**: both need the APK sideloaded. Both type the same room code in the
menu (Home page) and press Join.

---

## 5. How the systems work

### Player rig and movement (main.gd)
- `XROrigin3D` > `XRCamera3D` + two `XRController3D` hands (`hand.gd`, pose `aim`).
- The reference space is **Local Floor** (`xr/openxr/reference_space=2`). `_check_height()`
  lifts the view to 1.65 m only if the head starts below 0.25 m, which would mean the runtime
  fell back to a head-relative space. Settings also has Lower / Standing / Higher eye-height
  buttons.
- A floating `CharacterBody3D` follows the head. It collides with `LAYER_STRUCTURE` and
  `LAYER_BLOCKER` (the invisible box that stops you walking into the pool). When it is blocked,
  the origin shifts back. The left stick walks (relative to where you look); the right stick
  snap- or smooth-turns around the camera.
- `travel(room)` / `place_at()` teleport. The spawn is the Grand Hall at (0, 0, 4).

### Layers (kit.gd)
- Physics: STRUCTURE 1 (walls and floors; the body collides), FURNITURE 2 (balls and props
  bounce), BALL 4 (balls and props), UI 8 (laser buttons), BLOCKER 16 (the body only).
- Visual: VIS_INDOOR 1, VIS_OUTDOOR 2, VIS_ALL 3. The **sun only lights VIS_OUTDOOR**,
  because it has no shadows and would otherwise shine through roofs. Set `Kit.vis_layers`
  before building outdoor things. Things that move between inside and outside (hands, props,
  fire) use VIS_ALL.

### Networking
- The relay assigns a **slot** (0 to 3). The **host is the lowest slot**. Every client JSON
  message gets `"s": my_slot` added, and `main._on_received` routes on the part of `"t"` before
  the `_` to `modules[prefix].handle(msg, from)`.
- Each module implements `handle()`, `full_state()` (the host sends it to joiners),
  `on_identity_changed(old, new)` and `on_peer_left(slot)`.
- Message types:
  - `hello` (name, colour)
  - `p` (pose at 15 Hz: `h`/`l`/`r` packed transforms; `g` is
    `[lgrip, ltrig, rgrip, rtrig]` 0..9 for finger curls)
  - `ah_hold/ah_s/ah_goal/ah_reset/ah_full`
  - `c4_req/c4_s/c4_no/c4_reset`
  - `bb_b/bb_score/bb_reset/bb_full`
  - `jb_s/jb_full`
  - `pr_b/pr_e/pr_full`
- Binary messages carry voice: `[slot, 1, seq lo, seq hi, mu-law bytes...]`, 60 ms per packet.
- **Authority**:
  - Air hockey: whoever's half the puck is on simulates it.
  - Connect Four: the host referees.
  - Basketballs and props: owned by whoever last grabbed them (the host owns untouched ones).
    The owner simulates and streams at 20 Hz while the object moves. Everyone else shows it
    kinematically and interpolates. If two players grab at once, the lower slot wins.

### Grabbing
`main.try_grab(hand)` picks the nearest node in group `grabbable` (each must implement
`grab_distance(p)`, `on_grab(hand) -> bool` and `on_release(hand)`) within 16 cm of the palm.
On release the throw velocity is the hand's smoothed velocity × 1.05.

### Props (props.gd), all one module with prefix `pr`
- Built by `setup(mansion.anchors)` in a fixed order, so prop indices match on every headset.
  Each prop is a `RigidBody3D` (`Prop` inner class) with a home transform. Most props are held
  where you grabbed them; marshmallow sticks are always held by the handle, pointing forward.
- **Cake** (hall coffee table): hitting anything at more than 3 m/s → `splat` event: crumb
  particles, hidden for 3 s, then a fresh cake at home.
- **Drinks** (6 cans in the cooler): bring one to your mouth tilted → "Cheers!".
- **Meat** (BBQ: patties, sausages, steak): above the grate (`Grill` heat source) it cooks from
  raw to browned to charred, with grill marks and sizzle audio. Every headset works out cooking
  from the synced positions. Untouched meat stops at "nearly done".
- **Logs** (woodpile): resting in a fire's bed (`fire.contains()`) for 0.5 s → `burn` event.
  The log vanishes, the nearest fire `stoke()`s (it flares and decays over about 25 s) and the
  log respawns at the pile after 10 s.
- **Marshmallows on sticks** (stand by the fire pit):
  - The tip toasts with heat (white to golden to brown to black).
  - More than 3 s in strong heat (or over-toasting) → `ignite` (small flame particles).
  - Swinging the hand faster than 2.6 m/s → `out`.
  - Bringing the tip to your mouth (not burning) → `eat`, with a message rating the toast;
    a fresh marshmallow appears on the stick.
- **Cornhole bags**: the board collides as four pieces around a square hole. A bag dropping
  through → `hole` event, and everyone gets "<name>: in the hole!".
- Props landing in the pool float (buoyancy in `_pool_float`), and a burning marshmallow that
  goes into the water is put out.
- A **"Tidy up"** button on the cooler sends every prop that nobody is holding back home.

### Fire (fire.gd)
- `Fire.new(size, light_energy, smoke)`. The patio pit uses (0.9, 1.9); the lounge fireplace
  uses (0.75, 2.0, false).
- It is built from:
  - Log and coal meshes with an ember `ShaderMaterial` (noise-driven char and pulsing glow).
  - GPU particles: flame tongues and a hot core, both using a procedural teardrop texture and
    **HDR colour ramps** (`GradientTexture1D.use_hdr`), plus embers, a one-shot spark burst
    and optional smoke.
  - A flickering, slightly wandering OmniLight and an additive ground glow.
  - A procedural crackle loop.
- `heat_at(p)` returns 0..1 and `contains(p)` checks the bed. Hands in the fire get sparks and
  haptic pulses. Fires are in group `heat`, alongside the BBQ's `Grill`.

### Hands (hand_model.gd)
- Modelled as a **right** hand: palm down, fingers along -Z, back +Y, **thumb toward -X**. The
  left hand mirrors it. (The original box "gloves" had the thumbs on the wrong side; the user
  noticed.)
- The root is rolled about 60° so the palm faces in toward the controller grip.
- Each finger is a chain of capsule joints (knuckle, middle, tip) with a nail on the tip, and
  the thumb is the same chain from the base of the palm.
- `set_curl(grip, trigger)` bends the joints about local X. Grip curls the middle, ring and
  pinky fingers (and partly the thumb); trigger curls the index. Holding something keeps the
  hand at least 75% curled.
- Skin tone is a constant (`SKIN`, light). `set_skin()` exists for the planned skin-tone
  setting.

### Mansion building (mansion.gd)
- `_room()` builds the floor, ceiling and walls (with door gaps), plus baseboards, crown
  moulding, door casings and optional wainscot panels.
- Furniture helpers: `_sofa` (rounded frame, legs, seat and back cushions, throw pillows),
  `_table`, `_chair`, `_plant` (MultiMesh leaves), `_painting`, `_window`, `_floor_lamp`,
  `_table_lamp`, `_column`, `_umbrella`, `_lounger`, `_books` (a MultiMesh of hundreds of
  books).
- **Materials**: `Kit.tmat(color, kind, per_m, rough)` gives a colour broken up by a procedural
  greyscale texture applied with world triplanar mapping. Kinds: planks, tiles, pavers, grain,
  bricks, plaster, carpet, fabric, grass, bark.
- **String lights**: catenary wires (`Kit.catenary` + `Kit.tube_mesh`) between six posts and
  four hooks on the house. Each bulb hangs on a drop wire in a socket with an emissive bulb and
  an additive fresnel **halo** (`Kit.halo_mat`), all MultiMeshes.
- **Pool**: the patio floor and the lawn are split into pieces around the hole. The basin is
  tiled, with a dark waterline band, underwater lights and an omni light. The water plane uses
  `WATER_SHADER` (moving normals, fresnel alpha, sparkles). There is also a ladder and two
  bobbing floats (`_process`).
- Pass `--shots` and check the screenshots after layout changes. Coordinates are easy to get
  wrong.

### Audio
- Jukebox songs are synthesized on a `WorkerThreadPool` task into an `AudioStreamWAV`. Its
  `_exit_tree` waits for the task, because quitting mid-render hangs.
- `jukebox.add_speaker(pos, yaw)` builds an outdoor speaker on a tripod that plays the same
  stream and has its own Play/Next buttons. There are two by the patio door.
- The fire crackle and the BBQ sizzle use the same procedural loop (`Fire.crackle_stream()`;
  the sizzle plays it at pitch 2.6).

---

## 6. History (what was done, in order)

1. **Initial build (2026-11-22)**. The owner asked for "a hang out mansion for my friends and I
   where we can go to different rooms and play different games or activities or just hang out
   areas... for two players in different places".
   - They picked "mixed reality", but a walkable mansion has to be fully virtual, so a "My room"
     passthrough toggle was added instead. It hides the `structure` nodes and keeps the
     furniture and games.
   - The original build had all the rooms, air hockey, Connect Four, basketball, the jukebox,
     voice chat, the menu and the relay. The relay was deployed to Cloudflare and the APK
     installed on the Quest 3.
2. **Grey screen on the headset**. The headset showed one flat grey-brown colour while the
   desktop render was fine.
   - Cause: `rendering/anti_aliasing/quality/msaa_3d` (MSAA) together with
     `xr/openxr/foveation_level=2`.
   - Fix: removed MSAA and set foveation to 1.
   - Diagnosed with headset screenshots (`screenshot.ps1`) and the Stats log line.
   - Also fixed the eye-height check: its threshold dropped from 0.6 to 0.25 m, because Local
     Floor works on this Quest.
3. **Detail pass (owner feedback from inside the headset)**. Their requests: more definition
   (not plain rectangles), a realistic and interactive fire, realistic human hands with left and
   right the correct way round, real wires for the floating patio lights and bulbs that look
   lit, backyard accessories (speaker with music, BBQ with meat, "things you'd find in a
   backyard"), and the rename to **Sam and Dean Worldwide**. They also asked to be able to
   throw the cake. What was built:
   - Kit gained rounded boxes, tubes, catenaries, MultiMesh, procedural textures, `tmat` and
     halos.
   - `fire.gd` was rewritten.
   - New `hand_model.gd`, with finger curls synced over the network.
   - New `props.gd` (cake, drinks, BBQ meat, logs, marshmallows, cornhole).
   - The mansion was rewritten with textures, trim and nicer furniture, plus the recessed
     fireplace, sunken pool, string lights, backyard and lawn.
   - The jukebox got outdoor speakers.
   - The test grew from 28 to 42 checks, all passing.

---

## 7. Gotchas

- **Quest rendering**: don't turn MSAA back on, and keep foveation at level 1. If the headset
  shows something the desktop doesn't, use `screenshot.ps1` plus the Stats log.
- **Performance**: Quest 3 at 90 fps. Before the detail pass it ran about 284 draw calls at
  90 fps. Use MultiMesh for anything repeated, avoid shadows (all lights have shadows off), and
  keep transparent overdraw low (particles and halos are small). Check the Stats line after big
  additions.
- **Two worlds in one tree in tests**: `tests/_multi.gd` runs two Mains with `own_world_3d`, so
  `get_tree().get_nodes_in_group(...)` returns nodes from both players. Filter with
  `main.is_ancestor_of(node)` or compare `get_world_3d()`.
- **Editing files**: PowerShell string `.Replace()` on multi-line text once corrupted tabs and
  quotes (a helper flattened arrays). Use a proper edit tool. When writing files from
  PowerShell 5.1, write UTF-8 *without* a BOM (`[IO.File]::WriteAllText(path, text, (New-Object Text.UTF8Encoding $false))`).
- **GDScript typing**: calling script methods on a variable typed as a native class (`Node`,
  `Node3D`) works dynamically. Avoid naming parameters `scale` and similar in Node3D scripts,
  because they shadow properties.
- **Labels** are unshaded and single-sided. Face them (`yaw`) toward where people stand.
- **Props state**: when a prop is restored or teleported, reset transient physics state (e.g.
  `last_speed`), or a hidden cake splats again the moment it reappears.

---

## 8. Ideas and next steps (owner's wishes)

- **Skin tone setting** for the hands (the owner said "eventually we'll add settings for race,
  but just start with Caucasian"). `HandModel.set_skin()` is ready; it needs a Me-page option
  and a network field in `hello`.
- Look at other VR hangout apps (Rec Room, Horizon Worlds, Bigscreen, VRChat worlds) for more
  backyard and party activities: e.g. beer pong (see the owner's earlier USA vs Vietnam
  project), a hot tub, a TV or projector, darts, a dance floor with lights.
- Hands still pass through things. Better grab poses per object (wrap fingers around a can)
  would add realism.
- The cornhole score is only announced, not kept. A scoreboard like basketball's would help.
- Possibly a forearm or sleeve to the elbow, and a more human avatar body for friends (still a
  capsule and a head sphere).
- Test with two real headsets in different places (only tested in-process so far). The voice
  mic level and echo on the Quest are still unverified.
