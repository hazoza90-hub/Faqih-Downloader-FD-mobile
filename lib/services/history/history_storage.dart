import 'dart:convert';
import 'dart:io';

import '../../core/models/history_entry.dart';

/// Atomic JSON disk persistence for [HistoryEntry] records.
class HistoryStorage {
  const HistoryStorage(this.filePath);

  final String filePath;

  Future<List<HistoryEntry>> load() async {
    try {
      final file = File(filePath);
      if (!file.existsSync()) {
        return const <HistoryEntry>[];
      }
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) {
        return const <HistoryEntry>[];
      }
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        return const <HistoryEntry>[];
      }

      final entries = <HistoryEntry>[];
      for (final item in decoded) {
        if (item is Map) {
          entries.add(HistoryEntry.fromJson(Map<String, dynamic>.from(item)));
        }
      }
      return entries;
    } catch (_) {
      return const <HistoryEntry>[];
    }
  }

  Future<bool> save(List<HistoryEntry> entries) async {
    try {
      final target = File(filePath);
      await target.parent.create(recursive: true);
      final tmp = File('$filePath.tmp');
      final encoded = const JsonEncoder.withIndent('  ').convert(
        entries.map((e) => e.toJson()).toList(growable: false),
      );
      await tmp.writeAsString(encoded, flush: true);
      try {
        await tmp.rename(target.path);
      } on FileSystemException {
        if (target.existsSync()) {
          await target.delete();
        }
        await tmp.rename(target.path);
      }
      return true;
    } catch (_) {
      return false;
    }
  }
}
