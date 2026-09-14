# LookAwayBlur

Two privacy guards for your Mac, in one tiny menu-bar app:

1. **Look-away blur (AirPods)** — the moment you turn your head away, every screen blurs. Turn back, it clears. Uses the motion sensor in your AirPods.
2. **Shoulder-surf guard (camera)** — if a second face appears in front of the Mac, the screen blurs with "Someone else is looking". Uses the built-in camera + Apple's on-device face detection; frames are never stored or sent anywhere.

Each guard can be switched on/off from the menu. Either one alone works (no AirPods? just use the camera guard).

## Requirements
- macOS 14 (Sonoma) or newer, Apple Silicon or Intel
- AirPods with head tracking: AirPods Pro (any), AirPods 3, AirPods 4, AirPods Max, Beats Fit Pro. (AirPods 1st/2nd gen don't have the sensor.)
- For the AirPods guard: AirPods connected to **this Mac** and in both ears
- For the camera guard: a Mac with a built-in or attached camera

## Install
1. Unzip `LookAwayBlur.zip` and drag `LookAwayBlur.app` to **Applications**.
2. First launch: **right-click the app → Open**. If macOS still blocks it, go to
   **System Settings → Privacy & Security**, scroll down, click **Open Anyway**, then launch again.
   (Needed once, because the app isn't notarized by Apple.)
3. Allow **Motion & Fitness** and **Camera** access when asked.

## Use
A 👁 appears in the menu bar.
- **👁 …** zeroing — face the screen and hold still ~1 s
- **👁** tracking · **👁 ●** blurred (you looked away) · **👁 👀** blurred (someone else is looking) · **👁 ✗** no signal (AirPods off / camera denied) · **👁 ⏸** paused
- **⌃⌥Z** re-zero ("I'm facing the screen now") — use after moving your chair
- **⌃⌥X** pause / resume everything (also clears a stuck blur)
- Menu → tick/untick **Look-away blur (AirPods)** and **Shoulder-surf guard (camera)**
- Head blur turns on past ~40° of turn, off under ~25°. Removing the AirPods clears it.
- Camera guard checks 5 frames/sec; a second face for 0.6 s → blur, gone for 1.5 s → clear.

## Privacy
Nothing leaves your Mac. No network access, no analytics, no storage. Camera frames are analysed in memory and discarded.
- Menu → **Install Launch at Login** to start it automatically.

## Build from source
`./build.sh` — needs Xcode command-line tools only (single Swift file, no project).
