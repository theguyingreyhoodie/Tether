# Tether

A menu-bar app for macOS 26 that keeps you on one thing at a time and stops you mid-drift.
It is not a task manager. It works on two moments: starting, and the second you reach for a feed.

## How it works

**Tethered.** Press `⌃⌥Space`, type the task (`finish viva slides 45m`), press Return, then name
the first two-minute move. A small pill shows the task and the clock. Open a scroll site and the
screen pauses: Return or Esc goes back and closes the tab; getting through means waiting out a
timer and typing why. The reason is kept in the day's ledger and the next wait is twice as long.

**Untethered.** Scroll sites run on a daily budget (30 minutes by default) with the meter visible
in the menu bar and the pill. You get a check-in after ten minutes straight, a gate once the budget
is spent, and a gate at any time during night-guard hours (midnight to 6 AM by default). After
fifteen untethered minutes the pill asks what the one thing is.

**The wall.** Adult sites are closed the moment they come to the front, with no pass, followed by
ninety seconds of guided breathing. `⌃⌥U` opens the same screen on demand. Turning the wall off
takes ten minutes to apply. Walled visits are counted, never recorded.

The popover shows today's focused time, scroll time, how often you pulled yourself back, what you
said to get through, and the week.

## Build

    ./build-app.sh             # builds Tether.app here
    ./build-app.sh --install   # also copies it to /Applications and launches it

Needs Xcode 26 or later. The app is ad-hoc signed, so macOS treats every rebuild as a new app and
asks for the browser permissions again.

## Permissions

- **Automation**, once per browser (Safari, Chrome, Brave, Edge, Arc, Vivaldi, Opera). Tether reads
  the address of the front tab once a second and closes that tab when you go back.
- **Accessibility**, optional, only for browsers that can't be scripted (Firefox, Zen and others),
  where it reads the window title instead.

Everything is stored in `~/Library/Application Support/Tether/state.json`. Nothing leaves the Mac.

## Limits

- It sees the front tab of the front window. A feed in a background window is not caught.
- It only covers this Mac. The phone is a separate problem.
- It is a speed bump, not a lock: quitting Tether (`⌘Q`, also the emergency exit from a gate)
  takes it all down. For a harder wall, add a filtering DNS such as `1.1.1.3` in System Settings.

## Development

    swift test                                   # core logic: classifier, drift engine, parser, store
    .build/debug/Tether --selftest               # drives the real app model with a faked front tab
    .build/debug/Tether --uitest                 # opens every real window once, reports geometry
    .build/debug/Tether --snapshots <folder>     # renders every screen to PNG, offscreen
    .build/debug/Tether --livetest <folder>      # drives the real windows with real key events, saves a picture per step

The dev modes use a throwaway store and never touch real data, browsers or sound. Offscreen
snapshots replace Liquid Glass with a flat fill, because glass only composites on a real display.
`--livetest` needs an unlocked display and takes over the screen for about a minute; its pictures
show Tether's own windows over the wallpaper, which needs no Screen Recording permission.

`Sources/TetherCore` is pure logic with no AppKit. `Sources/Tether` is the app: `AppModel` owns
state and the one-second tick, `BrowserBridge` talks to browsers, and each surface (popover,
command bar, pill, gate, settings, onboarding) has its own file.
