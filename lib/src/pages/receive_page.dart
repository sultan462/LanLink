import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../Core.dart';
import 'widgets/app_colors.dart';
import 'widgets/app_logo.dart';
import 'widgets/status_view.dart';

class ReceivePage extends StatefulWidget {
  const ReceivePage({super.key, required this.core});

  final Core core;

  @override
  State<ReceivePage> createState() => _ReceivePageState();
}

class _ReceivePageState extends State<ReceivePage> {
  late Future<void> _serverStartFuture;
  StreamSubscription<ReceiveStatus>? _statusSub;
  bool _torndown = false;

  ReceiveStatus _liveStatus = ReceiveStatus.waiting;
  Object? _transferError;
  final List<FileSystemEntity> _sessionFiles = [];
  Set<String> _knownPaths = {};

  @override
  void initState() {
    super.initState();
    _serverStartFuture = _startReceiving();
  }

  Future<void> _startReceiving() async {
    await widget.core.establishServer();
    // seed with what's already there so only files that arrive THIS session
    // are treated as new
    _knownPaths = (await widget.core.showReceivedFiles()).map((f) => f.path).toSet();
    if (!mounted) return;
    _statusSub = widget.core.receiveStatusStream().listen(
          _handleStatus,
          onError: (e) {
            if (mounted) setState(() => _transferError = e);
          },
        );
  }

  // `completed` is intercepted here rather than rendered directly: it has no
  // file identity of its own, so we re-list via Core to find what's new, then
  // drop straight back to "waiting" instead of dead-ending on "File received".
  void _handleStatus(ReceiveStatus status) {
    if (status == ReceiveStatus.completed) {
      _onCompleted();
    } else if (mounted) {
      setState(() {
        _liveStatus = status;
        _transferError = null;
      });
    }
  }

  Future<void> _onCompleted() async {
    final files = await widget.core.showReceivedFiles();
    final newOnes = files.where((f) => !_knownPaths.contains(f.path)).toList();
    _knownPaths = files.map((f) => f.path).toSet();
    if (!mounted) return;
    setState(() {
      _sessionFiles.insertAll(0, newOnes);
      _liveStatus = ReceiveStatus.waiting;
      _transferError = null;
    });
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    _teardown();
    super.dispose();
  }

  Future<void> _teardown() async {
    if (_torndown) return;
    _torndown = true;
    await widget.core.closeServer();
  }

  Future<void> _stopReceiving() async {
    await _teardown();
    if (mounted) Navigator.pop(context);
  }

  void _retryStart() {
    _statusSub?.cancel();
    _statusSub = null;
    setState(() {
      _liveStatus = ReceiveStatus.waiting;
      _transferError = null;
      _sessionFiles.clear();
      _serverStartFuture = _startReceiving();
    });
  }

  Future<void> _openFile(FileSystemEntity file) async {
    try {
      await widget.core.openReceivedFile(file.path);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Couldn't open file: $e")),
        );
      }
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
            Text('Receive'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: _stopReceiving,
            child: const Text('Stop receiving'),
          ),
        ],
      ),
      body: FutureBuilder<void>(
        future: _serverStartFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const StatusView(
              graphic: SizedBox(
                width: 40,
                height: 40,
                child: CircularProgressIndicator(color: AppColors.primaryBlue),
              ),
              title: 'Starting server…',
            );
          }

          if (snapshot.hasError) {
            return StatusView(
              graphic: const Icon(Icons.error_outline, size: 56, color: Colors.redAccent),
              title: "Couldn't start receiving",
              message: '${snapshot.error}',
              action: FilledButton(onPressed: _retryStart, child: const Text('Retry')),
            );
          }

          return Column(
            children: [
              Expanded(
                child: _transferError != null
                    ? StatusView(
                        graphic: const Icon(Icons.error_outline, size: 56, color: Colors.redAccent),
                        title: 'Transfer failed',
                        message: '$_transferError',
                      )
                    : switch (_liveStatus) {
                        ReceiveStatus.incoming => const StatusView(
                            graphic: SizedBox(
                              width: 40,
                              height: 40,
                              child: CircularProgressIndicator(color: AppColors.primaryBlue),
                            ),
                            title: 'Receiving file…',
                          ),
                        ReceiveStatus.waiting || ReceiveStatus.completed => const StatusView(
                            graphic: AppLogo(variant: AppLogoVariant.mark, height: 64),
                            title: 'Waiting for a device to send a file',
                            message: 'This device is discoverable to others in Send mode.',
                          ),
                      },
              ),
              if (_sessionFiles.isNotEmpty)
                SizedBox(
                  height: 160,
                  child: Column(
                    children: [
                      const Divider(height: 1),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'Received this session',
                            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                                  color: AppColors.navy.withValues(alpha: 0.6),
                                ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: ListView.separated(
                          itemCount: _sessionFiles.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final file = _sessionFiles[index];
                            final name = Uri.file(file.path).pathSegments.last;
                            return ListTile(
                              dense: true,
                              leading: const Icon(Icons.check_circle, color: AppColors.primaryBlue),
                              title: Text(name),
                              onTap: () => _openFile(file),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
