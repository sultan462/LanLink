import 'dart:async';
import 'dart:io';
import 'package:bonsoir/bonsoir.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:lan_link/src/model/Device.dart';
import 'package:lan_link/src/model/ReceiveStatus.dart';
import 'package:lan_link/src/features/client.dart';
import 'package:lan_link/src/features/server.dart';

export 'package:lan_link/src/model/ReceiveStatus.dart';

const String kServiceType =
    '_lanlink._tcp'; // MUST match the broadcast side exactly

class Core {
  //main lanlink features
  //some features will be called from features folder and for some simple features will be implemented here
  TransferServer? _server;
  BonsoirBroadcast? _broadcast;
  TransferClient client = TransferClient(
    host: '',
  ); //this will be used to connect to a device on the LAN
  //1-discover devices on the LAN that are currently in receive mode
  //live/reactive: emits the current device list every time it changes (a device appears or disappears)
  Stream<List<Device>> discoverDevices() async* {
    const String type = kServiceType;

    final discovery = BonsoirDiscovery(type: type);
    await discovery.initialize();

    final Map<String, Device> found =
        {}; // source of truth, keyed by service name
    final controller = StreamController<List<Device>>();

    discovery.eventStream!.listen((event) {
      switch (event) {
        case BonsoirDiscoveryServiceFoundEvent():
          event.service!.resolve(
            discovery.serviceResolver,
          ); // found != has-address yet
        case BonsoirDiscoveryServiceResolvedEvent():
          final s = event.service!;
          final host = s.hostAddresses?.first;
          if (host != null) {
            found[s.name] = Device(
              id: s.name,
              name: s.name,
              host: host,
              port: s.port,
            );
            controller.add(found.values.toList());
          }
        case BonsoirDiscoveryServiceLostEvent():
          found.remove(event.service!.name);
          controller.add(found.values.toList());
        default:
          break;
      }
    });

    await discovery.start();
    controller.onCancel = () async => discovery.stop();

    yield* controller.stream;
  }

  //2-connect to a device on the LAN
  Future<void> connectToDevice(String ip) async {
    //this function will connect to a device on the LAN using its IP address
    //for now we will just print the IP address
    client = TransferClient(host: ip);
    await client.connect();
    _connections[ip] = client;
  }

  //3-pick a file from this device to send
  //returns the picked file's path, or null if the user cancelled the picker
  Future<String?> pickFile() async {
    //this function will let the user pick a file from this device's filesystem
    final result = await FilePicker.pickFiles();
    return result?.files.single.path;
  }

  final Map<String, TransferClient> _connections = {};

  Future<void> sendFile(
    String ip,
    String filePath, {
    void Function(double progress)? onProgress,
  }) async {
    final client = _connections[ip];
    if (client == null) {
      throw StateError('Not connected to $ip — call connectToDevice() first.');
    }
    await client.sendFile(filePath, onProgress: onProgress);
  }
  //note: for file receiving there is a private function in the server.dart file that will handle incoming files, so we don't need to implement it here
  //a good practice is to save the file in the app folder and then notify the user that a file has been received, so they can open it from the app folder. This will be implemented in the server.dart file.

  //5-disconnect from a device on the LAN
  Future<void> disconnectFromDevice(String ip) async {
    //this function will disconnect from a device on the LAN using its IP address
    //for now we will just print the IP address
    final client = _connections[ip];
    if (client != null) {
      await client.disconnect();
      _connections.remove(ip);
    }
  }

  //6-establish a server on the LAN to listen for incoming connections
  Future<void> establishServer() async {
    //this function will establish a server on the LAN to listen for incoming connections
    if (_server != null) await closeServer(); // idempotent on retry

    final docsDir = await getApplicationDocumentsDirectory();
    final saveDir = Directory('${docsDir.path}/LanLink');
    if (!await saveDir.exists()) await saveDir.create(recursive: true);

    final server = TransferServer(saveDirectory: saveDir);
    await server.start();
    _server = server;

    // advertise this device over mDNS so a peer's discoverDevices() finds it
    final broadcast = BonsoirBroadcast(
      service: BonsoirService(
        name: '${Platform.localHostname}-lanlink',
        type: kServiceType,
        port: server.port,
      ),
    );
    await broadcast.initialize();
    await broadcast.start();
    _broadcast = broadcast;
  }

  //7-live status of this device's receive server: waiting for a peer, a transfer
  //coming in, or a transfer just completed. A failed transfer should reach the
  //UI as a Stream error rather than as a status value.
  Stream<ReceiveStatus> receiveStatusStream() {
    final server = _server;
    if (server == null) {
      throw StateError('Server not started — call establishServer() first.');
    }
    return server.statusStream;
  }

  //8-close the server on the LAN
  Future<void> closeServer() async {
    //this function will close the server on the LAN
    await _broadcast?.stop();
    _broadcast = null;
    await _server?.dispose();
    _server = null;
  }

  //9- show received files
  Future<List<FileSystemEntity>> showReceivedFiles() async {
    final docsDir = await getApplicationDocumentsDirectory();
    final saveDir = Directory('${docsDir.path}/LanLink');
    if (!await saveDir.exists()) return [];
    return saveDir.list().toList();
  }

  //open a received file
  Future<void> openReceivedFile(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw FileSystemException('File not found', filePath);
    }
    if (Platform.isMacOS) {
      await Process.start('open', [filePath]);
    } else if (Platform.isLinux) {
      await Process.start('xdg-open', [filePath]);
    } else if (Platform.isWindows) {
      // rundll32 is a real exe, so the path is passed as a clean argv entry —
      // no cmd.exe re-quoting to break on names with spaces/dots (e.g. "9. Learning.pdf").
      await Process.start('rundll32', ['url.dll,FileProtocolHandler', filePath]);
    } else {
      throw UnsupportedError('Opening files is not supported on this platform.');
    }
  }

  //10- delete a received file
  Future<void> deleteReceivedFile(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw FileSystemException('File not found', filePath);
    }
    await file.delete();
  }
}
