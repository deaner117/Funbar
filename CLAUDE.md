# Sam and Dean Worldwide (Quest VR hangout): notes for AI agents

Read `docs/HANDOFF.md` first. It covers the architecture, networking, every system, the
history, the gotchas and what's next. This file is the short version.

- **What**: a multiplayer social VR mansion for Meta Quest 3. Friends join with a room code and
  get voice chat, avatars with realistic hands, games (air hockey, Connect Four, basketball,
  cornhole) and hangout props (a fire to roast marshmallows on, a BBQ, a pool, a jukebox,
  speakers, a throwable cake).
- **Stack**: Godot 4.7.2 (GDScript), OpenXR plus the Meta vendors plugin, mobile renderer, Jolt.
  Everything is generated in code; there are no art assets. The relay is a Cloudflare Worker in
  `server/`.
- **Names**: the app is "Sam and Dean Worldwide", but the folder, scripts and Android package
  are still `hangout-mansion` / `com.homebrew.hangoutmansion` on purpose.

## Commands (Windows, PowerShell, from the repo root)
- Build the APK: `.\build.ps1`. Install and launch on the Quest: `.\deploy.ps1` (`-Build`,
  `-Log`, `-Wifi`).
- Headset screenshot: `.\screenshot.ps1`. Performance: `adb logcat -d -s godot` shows a
  "Stats:" line every 2 s.
- Desktop screenshots of every area:
  `tools\Godot_v4.7.2-stable_win64_console.exe --xr-mode off --path . --resolution 1280x720 -- --solo --shots=<abs dir>`
- Multiplayer test (expect `42 passed, 0 failed`): start `npx wrangler dev --port 8787` in
  `server/`, then
  `tools\Godot_v4.7.2-stable_win64_console.exe --headless --xr-mode off --path . -s tests/_multi.gd`
- `tools/` (the Godot exes) isn't in git. Setup is in docs/HANDOFF.md section 3.

## Rules of thumb
- Verify visual changes with `--shots` screenshots, and on the headset with `screenshot.ps1`
  when you can.
- Run the multiplayer test after any gameplay or network change, and extend it for new
  features.
- Never re-enable MSAA, and keep foveation at level 1: either one made the Quest show a flat
  grey screen.
- Keep to 90 fps on the Quest; it is draw-call bound. `Kit.merge_static()` merges the static
  meshes in mansion.gd per material per room (488 down to about 100 draw calls), so anything
  you animate after build must be skipped from the merge. Use MultiMesh for repeated things,
  no shadows, and little transparent overdraw.
- New networked features become a module with a message prefix: `handle`, `full_state`,
  `on_identity_changed`, `on_peer_left`, registered in `main._build_games`. Grabbables join the
  `grabbable` group with `grab_distance`/`on_grab`/`on_release`.
- Outdoor visuals use `Kit.VIS_OUTDOOR` (the sun lights only that layer). Indoor ones use
  `VIS_INDOOR`.
- Write files as UTF-8 without a BOM. Use an edit tool, not PowerShell string replace, for
  multi-line edits.
