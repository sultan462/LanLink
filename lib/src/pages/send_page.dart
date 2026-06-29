import 'package:flutter/material.dart';

import '../Core.dart';
import '../model/Device.dart';
import 'widgets/app_colors.dart';
import 'widgets/app_logo.dart';
import 'widgets/status_view.dart';

class SendPage extends StatefulWidget {
  const SendPage({super.key, required this.core});

  final Core core;

  @override
  State<SendPage> createState() => _SendPageState();
}

class _SendPageState extends State<SendPage> {
  late final Stream<List<Device>> _deviceStream = widget.core.discoverDevices();

  Future<void> _handleDeviceTap(Device device) async {
    String? filePath;
    try {
      filePath = await widget.core.pickFile();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Couldn't open file picker: $e")),
        );
      }
      return;
    }
    if (filePath == null || !mounted) return;
    final path = filePath;

    final sent = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _SendDialog(core: widget.core, ip: device.host, filePath: path),
    );

    if (sent == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('File sent')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppLogo(variant: AppLogoVariant.mark, height: 28),
            SizedBox(width: 12),
            Text('Send'),
          ],
        ),
      ),
      body: StreamBuilder<List<Device>>(
        stream: _deviceStream,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const StatusView(
              graphic: SizedBox(
                width: 40,
                height: 40,
                child: CircularProgressIndicator(color: AppColors.primaryBlue),
              ),
              title: 'Scanning for devices…',
              message: 'Looking for devices in receive mode on your network.',
            );
          }

          final devices = snapshot.data ?? const <Device>[];
          if (snapshot.hasError || devices.isEmpty) {
            return const StatusView(
              graphic: AppLogo(variant: AppLogoVariant.mark, height: 64),
              title: 'No devices found',
              message: 'Make sure another device has opened Receive on the same network.',
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: devices.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final device = devices[index];
              return ListTile(
                leading: const Icon(Icons.devices, color: AppColors.primaryBlue),
                title: Text(device.name),
                subtitle: Text(device.host),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _handleDeviceTap(device),
              );
            },
          );
        },
      ),
    );
  }
}

/// Runs connect → sendFile → disconnect for one device while open, and shows
/// the "send failure" state distinctly if any step throws.
class _SendDialog extends StatefulWidget {
  const _SendDialog({required this.core, required this.ip, required this.filePath});

  final Core core;
  final String ip;
  final String filePath;

  @override
  State<_SendDialog> createState() => _SendDialogState();
}

class _SendDialogState extends State<_SendDialog> {
  String? _error;

  @override
  void initState() {
    super.initState();
    _send();
  }

  Future<void> _send() async {
    var connected = false;
    try {
      await widget.core.connectToDevice(widget.ip);
      connected = true;
      await widget.core.sendFile(widget.ip, widget.filePath);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (connected) await widget.core.disconnectFromDevice(widget.ip);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: _error == null
            ? const StatusView(
                graphic: SizedBox(
                  width: 40,
                  height: 40,
                  child: CircularProgressIndicator(color: AppColors.primaryBlue),
                ),
                title: 'Sending file…',
              )
            : StatusView(
                graphic: const Icon(Icons.error_outline, size: 48, color: Colors.redAccent),
                title: "Couldn't send file",
                message: _error,
                action: TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Close'),
                ),
              ),
      ),
    );
  }
}
