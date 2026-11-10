# Bambuddy Cert Installer

A small macOS menu bar app that finds [Bambuddy](https://github.com/maziggy/bambuddy) on your network, reads its Virtual Printer certificate, and adds it to OrcaSlicer and Bambu Studio, so both trust the virtual printer.

Both slicers read printer certificates only from a file inside their own app. Changing that file breaks the app's signature, and macOS then won't open it. So the app adds the certificate, then re-signs the slicer on your Mac, keeping its entitlements. Before its first change to a slicer it snapshots everything re-signing touches, so **Undo** puts the slicer back exactly, original signature included.

## How it works

1. It finds Bambuddy the way the slicers find printers: it sends the Bambu printer search on UDP 2021, and Bambuddy's virtual printer answers. If nothing answers, it tries Bambuddy Tray's address, then `bambuddy.lan` and `bambuddy.local`. You can also type an address.
2. It reads the certificate from `/api/v1/virtual-printers/ca-certificate`, and checks it's a single certificate that matches the fingerprint Bambuddy sends and hasn't expired.
3. The first time, you check the fingerprint against Bambuddy's **Settings › Virtual Printer** page and trust it. After that it refuses any other certificate until you trust the new one.
4. For each slicer it shows whether it trusts Bambuddy. **Add** appends the certificate, re-signs the app and checks the signature. If anything fails, it restores the snapshot.

The snapshot holds the certificate file, the slicer's main program and its signature folder, about 300 MB per slicer. Undo restores it and deletes it. A slicer update makes a new one on the next **Add**.

Slicer updates put back the slicer's own file. For slicers you added the certificate to, it adds it again by itself once the update finishes and the slicer is closed. It watches the Applications folders, checks when a slicer quits or your Mac wakes, and every 30 minutes. You can turn this off in Settings.

## Things to know

- Re-signing makes the slicer ad hoc signed, so it's no longer notarized. Gatekeeper would then refuse a downloaded app, so the app also removes the slicer's download (quarantine) flag, the way Homebrew does for apps that aren't notarized. macOS may ask again for permissions such as local network access.
- macOS may ask you to allow Bambuddy Cert Installer under **System Settings › Privacy & Security › App Management** the first time it changes a slicer.
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
