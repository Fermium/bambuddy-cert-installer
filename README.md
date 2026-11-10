# Bambuddy Cert Installer

A small macOS menu bar app that adds [Bambuddy](https://github.com/maziggy/bambuddy)'s Virtual Printer certificate to OrcaSlicer and Bambu Studio. Both slicers then trust the virtual printer.

Both slicers read printer certificates only from a file inside their own app. Changing that file breaks the slicer's signature, and macOS won't open it. So after adding the certificate, the app re-signs the slicer on your Mac and keeps its entitlements.

Before its first change to a slicer, the app takes a snapshot of everything re-signing touches. **Undo** restores it, original signature included.

## How it works

1. It finds Bambuddy the way the slicers find printers, with the Bambu printer search on UDP 2021. Bambuddy's virtual printer answers it. If nothing answers, it tries Bambuddy Tray's address, then `bambuddy.lan` and `bambuddy.local`. You can also type an address.
2. It reads the certificate from `/api/v1/virtual-printers/ca-certificate`. It must be a single certificate, match the fingerprint Bambuddy sends, and not have expired.
3. The first time, you compare the fingerprint with Bambuddy's **Settings › Virtual Printer** page, then trust it. After that, the app refuses any other certificate until you trust the new one.
4. For each slicer it shows whether it trusts Bambuddy. **Add** appends the certificate, re-signs the slicer and checks its signature. If anything fails, it restores the snapshot.

The snapshot holds the certificate file, the slicer's main program and its signature folder. That's about 300 MB per slicer. Undo restores the snapshot, then deletes it. After a slicer update, the next **Add** takes a new one.

Slicer updates put back the slicer's own file. For slicers you added the certificate to, the app adds it again by itself, once the update has finished and the slicer is closed. It watches the Applications folders, and checks when a slicer quits, when your Mac wakes and every 30 minutes. You can turn this off in Settings.

## Things to know

- Re-signing makes the slicer ad hoc signed, so it's no longer notarized. Gatekeeper refuses a downloaded app in that state, so the app also removes the slicer's download (quarantine) flag. Homebrew does the same for apps that aren't notarized. macOS may ask again for permissions such as local network access.
- The first time the app changes a slicer, macOS may ask you to allow it under **System Settings › Privacy & Security › App Management**.
- Quit a slicer before changing it.

## Settings

Right-click the shield, or click the gear in the popover.

- **Bambuddy address**: empty finds it automatically.
- **Trusted Certificate**: the fingerprint you trusted, and **Forget**.
- **Add it again after a slicer updates** and **Open at login**.
- **Backups**: the space the snapshots use.

## Build

```sh
swift test
scripts/make-app.sh   # builds build/Bambuddy Cert Installer.app
```

`LIVE=1 swift test --filter live` checks your real Bambuddy and slicers without changing anything. `-snapshot <folder>` draws the popover and Settings into PNGs, offscreen.

Needs macOS 15. MIT licence. Not affiliated with Bambu Lab or Bambuddy.
