# LanLink

Drop a file on one device, watch it land on another — no cloud, no accounts, just your LAN.

LanLink is a cross-platform Flutter app for sending files between devices on the same local network. One device discovers the other over mDNS/Bonjour, then the file moves directly over a raw TCP socket — nothing leaves the LAN, nothing touches a server.

<!-- TODO: demo GIF -->

<!-- TODO: screenshots -->

## Features

- **Send** — pick any file, see the devices currently in Receive mode on your LAN, send with live progress.
- **Receive** — turns this device into a discoverable LAN endpoint. Receiving is continuous: one file completes, it's saved, and the device keeps listening for the next one without restarting.
- **Received Files** — browse everything this device has ever received, open a file with the OS's default handler, or delete it (with a confirmation step — deletion is permanent).

## How it works

The UI never touches a socket or the filesystem directly — everything goes through one API surface, `Core` (`lib/src/Core.dart`): `discoverDevices()`, `establishServer()`, `sendFile()`, `showReceivedFiles()`, `openReceivedFile()`, `deleteReceivedFile()`, and a handful more. Pages call `Core`; `Core` owns the transport.

**Wire protocol** (`lib/src/features/protocol.dart`): every message on the socket starts with a fixed **64-byte** ASCII header holding the exact UTF-8 byte length of what follows, right-padded with spaces — no delimiter, just a byte count you can always read up front. A file transfer is two such messages: a small JSON metadata frame (`{"name": ..., "size": ...}`), then the raw file bytes. The receiving side (`lib/src/features/server.dart`) reads *exactly* `size` bytes off the wire — it isn't reading "until the connection closes." The connection's eventual close (a `DISCONNECT` sentinel) only means "no more files this session," and is explicitly checked for so it's never mistaken for the next file's metadata.

**Discovery** runs over mDNS/Bonjour via [`bonsoir`](https://pub.dev/packages/bonsoir): a receiving device broadcasts itself as `<hostname>-lanlink` under the service type `_lanlink._tcp` on TCP port `5050`; a sending device browses for that same service type and resolves each hit into a host/port pair to connect to.

**Storage**: received files land in `<ApplicationDocumentsDirectory>/LanLink/`. The receiver only ever takes the basename of the sender-supplied filename before writing it, so a crafted path can't write outside that folder.

**Receive status** is a broadcast stream (`waiting` → `incoming` → `completed`) that the Receive screen consumes to drive its UI and a "received this session" list — the underlying server stays bound and keeps accepting connections across that whole cycle, which is what makes continuous receiving possible without any polling.

## Tech stack

- [Flutter](https://flutter.dev) (Material 3) / Dart
- [`bonsoir`](https://pub.dev/packages/bonsoir) — mDNS/Bonjour discovery and broadcast
- [`file_picker`](https://pub.dev/packages/file_picker) — native file picker for Send
- [`path_provider`](https://pub.dev/packages/path_provider) — locating the app's documents directory
- `dart:io` `Socket` / `ServerSocket` — the actual file transport, hand-rolled rather than pulled from a package

## Build & run

```bash
flutter pub get

# pick one, per platform:
flutter run -d macos
flutter run -d windows
flutter run -d linux
flutter run -d <android-device-id>
flutter run -d <ios-device-id>

flutter test
```

Use `flutter devices` to list available targets. Android, iOS, and macOS builds carry the local-network and Bonjour permissions LanLink needs (`AndroidManifest.xml`, both platforms' `Info.plist`, macOS sandbox entitlements); Windows and Linux run on the standard Flutter desktop scaffolding.

## Prior art

Tools like [LocalSend](https://localsend.org) already solve LAN file transfer well. LanLink exists as a from-the-socket-layer-up implementation — the discovery, the wire framing, and the transfer state machine are all written here rather than pulled in as a transfer library, which is the part of this project actually worth looking at.
