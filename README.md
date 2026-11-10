# Bambuddy Cert Installer

A small macOS menu bar app that finds [Bambuddy](https://github.com/maziggy/bambuddy) on your network, reads its Virtual Printer certificate, and adds it to OrcaSlicer and Bambu Studio, so both trust the virtual printer.

Both slicers read printer certificates only from a file inside their own app. Changing that file breaks the app's signature, and macOS then won't open it. So the app adds the certificate, then re-signs the slicer on your Mac, keeping its entitlements. Every change keeps a backup, and **Undo** puts the file back.

## How it works

1. It finds Bambuddy the way the slicers find printers: it sends the Bambu printer search on UDP 2021, and Bambuddy's virtual printer answers. If nothing answers, it tries Bambuddy Tray's address, then `bambuddy.lan` and `bambuddy.local`. You can also type an address.
2. It reads the certificate from `/api/v1/virtual-printers/ca-certificate`, and checks it's a single certificate that matches the fingerprint Bambuddy sends and hasn't expired.
3. The first time, you check the fingerprint against Bambuddy's **Settings › Virtual Printer** page and trust it. After that it refuses any other certificate until you trust the new one.
4. For each slicer it shows whether it trusts Bambuddy. **Add** appends the certificate, re-signs the app and checks the signature. If anything fails, it puts the file back.

Slicer updates replace the file, so it checks again every 30 minutes and when your Mac wakes.

## Things to know

- Re-signing makes the slicer ad hoc signed, so it's no longer notarized. macOS still opens it on your Mac, but it may ask again for permissions such as local network access.
- macOS may ask you to allow Bambuddy Cert Installer under **System Settings › Privacy & Security › App Management** the first time it changes a slicer.
- Quit a slicer before changing it.

## Build

```sh
swift test
scripts/make-app.sh   # builds build/Bambuddy Cert Installer.app
```

`LIVE=1 swift test --filter live` checks your real Bambuddy and slicers without changing anything.

Needs macOS 15. MIT licence. Not affiliated with Bambu Lab or Bambuddy.
