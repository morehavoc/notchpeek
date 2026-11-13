# NotchPeek

See the menu bar icons hiding behind your MacBook's notch.

Hover the notch, or press **⌃⌥Space**. A small black strip drops out of the notch with only the icons macOS couldn't fit. Click one and its real menu opens. Esc, a click elsewhere, or moving away closes it.

- No settings, no sections to manage, no dragging. It never moves or hides your icons, so it has nothing to break when macOS changes how the menu bar works.
- Needs **Accessibility** permission only (to read where icons are and open their menus). No screen recording, no network.
- Free, MIT licensed. One Swift file.

**Settings** (right-click the strip, the menu bar icon, or open the app again): keyboard shortcut, hover on/off, background (Glass to match the menu bar, Black to grow out of the notch, or any colour), show every icon, menu bar icon, open at login.

Nothing behind the notch? The strip says so and shows every icon instead. On a Mac without a notch it opens under the middle of the menu bar.

## Limits
- Apple's own items (clock, Control Center, Now Playing) can't be opened this way on macOS 27. They sit at the right end and are never the ones hidden.
- An app whose menu bar item doesn't support the Accessibility press action can't be opened from the strip.

## Updates
NotchPeek updates itself with [Sparkle](https://sparkle-project.org) from this repo's GitHub releases (checked daily; turn off automatic installs in Settings).

## Build
```
./build.sh          # fetches Sparkle (checksum-pinned), builds, signs with "Apple Development"
build/NotchPeek.app/Contents/MacOS/NotchPeek --list   # print every item and whether it's hidden
NOTCHPEEK_FAKE_NOTCH=2140,85 build/NotchPeek.app/Contents/MacOS/NotchPeek   # test on a Mac without a notch
```
Requires macOS 14+.

## Release
1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in Info.plist, commit, push a tag `vX.Y.Z`.
2. CI signs (Developer ID), notarizes, staples and publishes `NotchPeek-X.Y.Z.zip`.
3. On the machine holding the update key: `scripts/publish-appcast.sh vX.Y.Z` signs the feed and uploads `appcast.xml`.
