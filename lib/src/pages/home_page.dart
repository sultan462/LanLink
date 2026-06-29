import 'package:flutter/material.dart';

import '../Core.dart';
import 'receive_page.dart';
import 'received_files_page.dart';
import 'send_page.dart';
import 'widgets/app_logo.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key, required this.core});

  final Core core;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const AppLogo(height: 96),
                const SizedBox(height: 56),
                SizedBox(
                  width: 220,
                  child: FilledButton.icon(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => SendPage(core: core)),
                    ),
                    icon: const Icon(Icons.send),
                    label: const Text('Send'),
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: 220,
                  child: FilledButton.tonalIcon(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => ReceivePage(core: core)),
                    ),
                    icon: const Icon(Icons.call_received),
                    label: const Text('Receive'),
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: 220,
                  child: OutlinedButton.icon(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => ReceivedFilesPage(core: core)),
                    ),
                    icon: const Icon(Icons.folder_open),
                    label: const Text('Received Files'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
