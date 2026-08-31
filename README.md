# Bifold

A Nintendo DS emulator for iOS by Redfern's Outpost, built around the
[melonDS](https://melonds.kuribo64.net) core. Two screens, a touch screen,
a microphone you can blow into, and the same dark component style as Tinbox.

Bifold is a sideload-first project: CI builds an unsigned IPA on GitHub's
macOS runners and you sign it on Windows with Sideloadly. No Mac required.

## What it does

- DS games (.nds), booted directly with melonDS's built-in FreeBIOS and
  generated firmware. No BIOS or firmware dumps needed.
- Both screens rendered with Metal: stacked in portrait, side by side in
  landscape. The touch screen takes real touch input, wherever it is.
- Full DS controls: D-pad, A B X Y, L R, Start, Select, plus a hold-to-blow
  MIC button for games that want you to huff at them.
- Battery saves (.sav), ten save-state slots with thumbnails, auto-save on
  exit, suspend recovery after an interrupted session.
- Fast-forward, screen swap, lid close (sleep), Bluetooth controllers.
- Library with each cart's own embedded banner icon as cover art.

## What it does not do (yet)

- DSi mode (needs real BIOS/NAND dumps), local wireless, WFC, GBA slot,
  cheats, rewind, .zip archives.

## Building

Everything compiles in CI (`.github/workflows/build.yml`):

1. `Scripts/build-melonds.sh` clones melonDS (pinned tag) and builds the
   core as a static xcframework for device + simulator (cached between runs).
2. `Scripts/gen_xcodeproj.py` generates `Bifold.xcodeproj` (never hand-edit
   the pbxproj; re-run the script after adding or removing files).
3. `xcodebuild` produces simulator (screenshots) and device (IPA) builds.

The unsigned IPA lands in the rolling `latest` release. Sign and install
with Sideloadly.

## License

GPL-3.0 (see LICENSE). Bifold links the melonDS core, which is GPL-3.0;
the whole app is distributed under the same terms. melonDS is by the
melonDS team; Bifold is not affiliated with Nintendo. Bring your own game
dumps of cartridges you own.
