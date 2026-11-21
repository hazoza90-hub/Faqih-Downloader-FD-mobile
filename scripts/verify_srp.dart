import 'dart:io';

const int softTargetLines = 300;
const int hardLimitLines = 400;

void main() {
  final scanTargets = <({String dir, String ext})>[
    (dir: 'lib', ext: '.dart'),
    (dir: 'android/app/src/main/kotlin', ext: '.kt'),
  ];

  var totalScanned = 0;
  final warnings = <String>[];
  final violations = <String>[];

  for (final target in scanTargets) {
    final root = Directory(target.dir);
    if (!root.existsSync()) {
      continue;
    }

    final files = root
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .where((file) => file.path.toLowerCase().endsWith(target.ext))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    for (final file in files) {
      totalScanned++;
      final lines = file.readAsLinesSync().length;
      final normalizedPath = file.path.replaceAll('\\', '/');

      if (lines > hardLimitLines) {
        violations.add(
          '[FAIL] $normalizedPath ($lines lines > $hardLimitLines limit)',
        );
      } else if (lines > softTargetLines) {
        warnings.add(
          '[WARN] $normalizedPath ($lines lines > $softTargetLines target)',
        );
      }
    }
  }

  for (final warning in warnings) {
    stdout.writeln(warning);
  }
  for (final violation in violations) {
    stderr.writeln(violation);
  }

  stdout.writeln(
    'SRP scan complete: $totalScanned file(s) checked, '
    '${warnings.length} warning(s), ${violations.length} violation(s).',
  );

  if (violations.isNotEmpty) {
    exitCode = 1;
  }
}
