import 'dart:async';
import 'dart:io';
import 'package:bonsoir/bonsoir.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:lan_link/src/model/Device.dart';
import 'package:lan_link/src/model/ReceiveStatus.dart';
import 'package:lan_link/src/features/client.dart';
import 'package:lan_link/src/features/discovery_addresses.dart';
import 'package:lan_link/src/features/file_opener.dart';
import 'package:lan_link/src/features/receiver_lifecycle.dart';

export 'package:lan_link/src/model/ReceiveStatus.dart';

const String kServiceType =
    '_lanlink._tcp'; // MUST match the broadcast side exactly

class Core {
  //main lanlink features
  //some features will be called from features folder and for some simple features will be implemented here
  final ReceiverLifecycle _receiver = ReceiverLifecycle(
    serviceType: kServiceType,
  );
  final Map<String, Device> _discoveredDevices = {};
  TransferClient client = TransferClient(
    host: '',
  ); //this will be used to connect to a device on the LAN
  //1-discover devices on the LAN that are currently in receive mode
  //live/reactive: emits the current device list every time it changes (a device appears or disappears)
  Stream<List<Device>> discoverDevices() async* {
    const String type = kServiceType;

    final discovery = BonsoirDiscovery(type: type);
    await discovery.initialize();

    final found = _discoveredDevices;
    found.clear();
    final controller = StreamController<List<Device>>();

    discovery.eventStream!.listen((event) {
      switch (event) {
        case BonsoirDiscoveryServiceFoundEvent():
          event.service.resolve(
            discovery.serviceResolver,
          ); // found != has-address yet
        case BonsoirDiscoveryServiceResolvedEvent():
          final s = event.service;
          final addresses = compatibleDiscoveryAddresses(s.hostAddresses);
          if (addresses.isNotEmpty) {
            found[s.name] = Device(
              id: s.name,
              name: s.name,
              host: addresses.first,
              port: s.port,
              addresses: addresses,
            );
            controller.add(found.values.toList());
          }
        case BonsoirDiscoveryServiceLostEvent():
          found.remove(event.service.name);
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
    final device = _discoveredDevices.values
        .where((d) => d.host == ip)
        .firstOrNull;
    client = TransferClient(
      host: ip,
      port: device?.port ?? 5050,
      alternateHosts: device?.addresses ?? const [],
    );
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
    await _receiver.start();
  }

  //7-live status of this device's receive server: waiting for a peer, a transfer
  //coming in, or a transfer just completed. A failed transfer should reach the
  //UI as a Stream error rather than as a status value.
  Stream<ReceiveStatus> receiveStatusStream() {
    return _receiver.statusStream;
  }

  //8-close the server on the LAN
  Future<void> closeServer() async {
    await _receiver.stop();
  }

  //9- show received files
  Future<List<FileSystemEntity>> showReceivedFiles() async {
    final docsDir = await getApplicationDocumentsDirectory();
    final saveDir = Directory('${docsDir.path}/LanLink');
    if (!await saveDir.exists()) return [];
    return saveDir
        .list(followLinks: false)
        .where((entry) => entry is File)
        .toList();
  }

  //open a received file
  Future<void> openReceivedFile(String filePath) async {
    await FileOpener.open(filePath);
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
