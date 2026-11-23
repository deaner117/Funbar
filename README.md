# Sam and Dean Worldwide

A VR mansion for Meta Quest 3 where friends in different places hang out together. Everyone who
enters the same room code shares the mansion. You see each other (head, body, realistic hands
that follow your fingers, name tag), talk with voice chat, and play and mess around together.

(The project folder, scripts and Android package still use the original working name,
`hangout-mansion`.)

| Area | What's there |
|---|---|
| Grand Hall | Sofas, chandelier, welcome board with the controls, a cake you can throw (it splats) |
| Game Room | Air hockey (2 players), Connect Four, arcade cabinets, bar |
| Gym | Basketball hoop, ball rack, scoreboard of baskets per player |
| Lounge | Stone fireplace with a real-looking fire, sofas, bookshelves, jukebox (synthesized songs, shared) |
| Patio | Outdoors at sunset: sunken pool, fire pit (roast marshmallows, throw logs on), gas BBQ (meat really cooks), drinks cooler, string lights on wires, outdoor speakers |
| Lawn | Cornhole |

## Controls

- **Moving:** left stick walks; right stick turns (snap or smooth). You can also walk around physically, and walls stop you.
- **Grip (grab):** works on mallets, balls, cake, drinks, meat, logs, marshmallow sticks and bean bags. Let go mid-swing to throw.
- **Trigger:** points a laser at buttons and presses them. Your fingers curl with grip and trigger.
- **Menu (Y or the menu button):**
  - Room code
  - Quick travel and "go to my friend"
  - Your name and colour
  - Settings: turning, speed, voice mute, eye height, and "My room" passthrough mode

## Build and install

```powershell
.\build.ps1            # build\HangoutMansion.apk
.\deploy.ps1           # install + launch on the Quest (USB, or Wi-Fi via quest-ip.txt)
.\deploy.ps1 -Build    # both
.\deploy.ps1 -Wifi     # one-time Wi-Fi adb setup (headset on USB)
```

To play with a friend, they need the same APK installed (sideload it). Machine setup is in
[docs/HANDOFF.md](docs/HANDOFF.md#3-setting-up-a-machine): Godot 4.7.2 in `tools/`, export
templates, Android SDK and JDK 17.

## Relay server (needed for playing together)

`server/` is a Cloudflare Worker (free plan). Each room code is one Durable Object, with up to 4
players. Messages are relayed verbatim. All game logic runs in the headsets.

```powershell
cd server
npx wrangler login     # once
npm run deploy
```

The app connects to `DEFAULT_SERVER` in `main.gd`.

## Testing on the laptop

```powershell
# Two players in one process against a local relay (start `npx wrangler dev --port 8787` in server/ first):
tools\Godot_v4.7.2-stable_win64_console.exe --headless --xr-mode off --path . -s tests/_multi.gd
# Screenshots of every area (desktop mode):
tools\Godot_v4.7.2-stable_win64_console.exe --xr-mode off --path . --resolution 1280x720 -- --solo --shots=<abs dir>
# Desktop mode to walk around: WASD + mouse (click to capture), Q/E turn, M menu.
tools\Godot_v4.7.2-stable_win64.exe --xr-mode off --path . -- --solo
```

## Documentation

- [docs/HANDOFF.md](docs/HANDOFF.md): architecture, every system, networking protocol, history, gotchas, next steps
- [CLAUDE.md](CLAUDE.md): short orientation for AI coding agents
