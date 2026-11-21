import 'package:path/path.dart' as p;

/// Resolves a collision-free destination file path using `name (1).ext` numbering.
String generateUniquePath(
  String desiredPath, {
  required bool Function(String) existsCheck,
  Set<String>? reservedPaths,
}) {
  if (desiredPath.trim().isEmpty) {
    return desiredPath;
  }

  final pathCtx = desiredPath.contains('\\') ? p.windows : p.posix;
  final normalizedReserved = <String>{
    for (final path in reservedPaths ?? const <String>{})
      if (path.trim().isNotEmpty) pathCtx.normalize(path),
  };

  bool isOccupied(String candidate) {
    if (normalizedReserved.contains(pathCtx.normalize(candidate))) {
      return true;
    }
    return existsCheck(candidate);
  }

  if (!isOccupied(desiredPath)) {
    return desiredPath;
  }

  final dir = pathCtx.dirname(desiredPath);
  final hasExplicitDir =
      dir != '.' ||
      desiredPath.startsWith('./') ||
      desiredPath.startsWith(r'.\');
  final base = pathCtx.basenameWithoutExtension(desiredPath);
  final ext = pathCtx.extension(desiredPath);

  final suffixMatch = RegExp(r'^(.*?)\s*\((\d+)\)$').firstMatch(base);
  final String rootBase;
  var counter = 1;
  if (suffixMatch != null) {
    rootBase = suffixMatch.group(1)!.trimRight();
    counter = (int.tryParse(suffixMatch.group(2)!) ?? 0) + 1;
  } else {
    rootBase = base;
  }

  while (true) {
    final filename = '$rootBase ($counter)$ext';
    final candidate = hasExplicitDir ? pathCtx.join(dir, filename) : filename;
    if (!isOccupied(candidate)) {
      return candidate;
    }
    counter++;
  }
}
