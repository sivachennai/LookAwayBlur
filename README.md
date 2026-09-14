# LookAwayBlur

Blurs your Mac screen the moment you turn your head away — using the motion sensor in your AirPods. Turn back, it clears.

## Requirements
- macOS 14 (Sonoma) or newer, Apple Silicon or Intel
- AirPods with head tracking: AirPods Pro (any), AirPods 3, AirPods 4, AirPods Max, Beats Fit Pro. (AirPods 1st/2nd gen don't have the sensor.)
- AirPods connected to **this Mac** and in both ears

## Install
1. Unzip `LookAwayBlur.zip` and drag `LookAwayBlur.app` to **Applications**.
2. First launch: **right-click the app → Open**. If macOS still blocks it, go to
   **System Settings → Privacy & Security**, scroll down, click **Open Anyway**, then launch again.
   (Needed once, because the app isn't notarized by Apple.)
3. Allow **Motion & Fitness** access when asked.

## Use
A 👁 appears in the menu bar.
- **👁 …** zeroing — face the screen and hold still ~1 s
- **👁** tracking · **👁 ●** blurred · **👁 ✗** no AirPods signal · **👁 ⏸** paused
- **⌃⌥Z** re-zero ("I'm facing the screen now") — use after moving your chair
- **⌃⌥X** pause / resume (also clears a stuck blur)
- Blur turns on past ~40° of head turn, off under ~25°. Removing the AirPods clears it.
- Menu → **Install Launch at Login** to start it automatically.

## Build from source
`./build.sh` — needs Xcode command-line tools only (single Swift file, no project).
