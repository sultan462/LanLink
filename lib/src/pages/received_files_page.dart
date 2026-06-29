import 'dart:io';

import 'package:flutter/material.dart';

import '../Core.dart';
import 'widgets/app_colors.dart';
import 'widgets/app_logo.dart';
import 'widgets/status_view.dart';

class ReceivedFilesPage extends StatefulWidget {
  const ReceivedFilesPage({super.key, required this.core});

  final Core core;

  @override
  State<ReceivedFilesPage> createState() => _ReceivedFilesPageState();
}

class _ReceivedFilesPageState extends State<ReceivedFilesPage> {
  late Future<List<FileSystemEntity>> _filesFuture;

  // Populated once from the future's snapshot, then mutated directly on
  // delete. showReceivedFiles() is one-shot, so this is what lets a deleted
  // row disappear without re-fetching the whole list.
  List<FileSystemEntity>? _files;

  @override
  void initState() {
    super.initState();
    _filesFuture = widget.core.showReceivedFiles();
  }

  void _refresh() {
    setState(() {
      _files = null;
      _filesFuture = widget.core.showReceivedFiles();
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

  Future<void> _confirmAndDelete(int index, FileSystemEntity file) async {
    final name = Uri.file(file.path).pathSegments.last;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete file?'),
        content: Text('"$name" will be permanently deleted.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await widget.core.deleteReceivedFile(file.path);
      if (mounted) setState(() => _files?.removeAt(index));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Couldn't delete file: $e")),
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
            Text('Received Files'),
          ],
        ),
        actions: [
          IconButton(
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: FutureBuilder<List<FileSystemEntity>>(
        future: _filesFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const StatusView(
              graphic: SizedBox(
                width: 40,
                height: 40,
                child: CircularProgressIndicator(color: AppColors.primaryBlue),
              ),
              title: 'Loading received files…',
            );
          }

          if (snapshot.hasError) {
            return StatusView(
              graphic: const Icon(Icons.error_outline, size: 56, color: Colors.redAccent),
              title: "Couldn't load received files",
              message: '${snapshot.error}',
              action: FilledButton(onPressed: _refresh, child: const Text('Retry')),
            );
          }

          _files ??= List.of(snapshot.data ?? const <FileSystemEntity>[]);
          final files = _files!;
          if (files.isEmpty) {
            return const StatusView(
              graphic: AppLogo(variant: AppLogoVariant.mark, height: 64),
              title: 'No files received yet',
              message: 'Files sent to this device will appear here.',
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: files.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final file = files[index];
              final name = Uri.file(file.path).pathSegments.last;
              return ListTile(
                leading: const Icon(Icons.insert_drive_file, color: AppColors.primaryBlue),
                title: Text(name),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                  tooltip: 'Delete',
                  onPressed: () => _confirmAndDelete(index, file),
                ),
                onTap: () => _openFile(file),
              );
            },
          );
        },
      ),
    );
  }
}
