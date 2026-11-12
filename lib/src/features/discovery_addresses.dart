import 'dart:io';

/// The receiver binds IPv4 only. Preserve discovery order among usable IPv4
/// addresses, rather than letting an IPv6-first result hide a reachable peer.
List<String> compatibleDiscoveryAddresses(Iterable<String> addresses) {
  return addresses
      .where((host) {
        final address = InternetAddress.tryParse(host);
        return address != null &&
            address.type == InternetAddressType.IPv4 &&
            !address.isMulticast &&
            address.address != InternetAddress.anyIPv4.address;
      })
      .toSet()
      .toList();
}
