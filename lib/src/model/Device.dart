class Device {
  final String
  id; // mDNS service name — stable identity across found/resolved/lost
  final String name; // human-readable label for the list
  final String host; // resolved IP — ready for Socket.connect / connectToDevice
  final int port; // resolved port

  const Device({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
  });
}
