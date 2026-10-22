// The extension's icons, read from their SVG path data: every one parses and stays on the 24-point
// grid it was drawn on.
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:zandr/ui/icons.dart';

// Where the lines actually run, sampled along them: Path.getBounds counts curves' control points.
Rect drawn(Path path) {
  var left = double.infinity, top = double.infinity, right = -double.infinity, bottom = -double.infinity;
  for (final metric in path.computeMetrics()) {
    for (var at = 0.0; at <= metric.length; at += 0.05) {
      final point = metric.getTangentForOffset(at)!.position;
      left = point.dx < left ? point.dx : left;
      top = point.dy < top ? point.dy : top;
      right = point.dx > right ? point.dx : right;
      bottom = point.dy > bottom ? point.dy : bottom;
    }
  }
  return Rect.fromLTRB(left, top, right, bottom);
}

void main() {
  test('every icon parses and fits the grid', () {
    final glyphs = {
      'check': ZIcons.check, 'close': ZIcons.close, 'back': ZIcons.back, 'chevronRight': ZIcons.chevronRight,
      'chevronDown': ZIcons.chevronDown, 'plus': ZIcons.plus, 'import': ZIcons.import, 'copy': ZIcons.copy,
      'eye': ZIcons.eye, 'eyeOff': ZIcons.eyeOff, 'lock': ZIcons.lock, 'settings': ZIcons.settings,
      'addressBook': ZIcons.addressBook, 'trash': ZIcons.trash, 'privateKey': ZIcons.privateKey, 'phrase': ZIcons.phrase,
      'more': ZIcons.more, 'explore': ZIcons.explore, 'receive': ZIcons.receive, 'send': ZIcons.send,
      'swap': ZIcons.swap, 'flip': ZIcons.flip, 'filter': ZIcons.filter, 'reclaim': ZIcons.reclaim, 'app': ZIcons.app,
      'info': ZIcons.info, 'warning': ZIcons.warning, 'scan': ZIcons.scan, 'paste': ZIcons.paste, 'rename': ZIcons.rename,
      'openOutside': ZIcons.openOutside, 'network': ZIcons.network, 'clock': ZIcons.clock, 'offline': ZIcons.offline, 'rosette': ZIcons.rosette, 'rosetteCheck': ZIcons.rosetteCheck,
    };
    for (final MapEntry(key: name, value: glyph) in glyphs.entries) {
      final bounds = drawn(glyph.path);
      expect(bounds.isEmpty, isFalse, reason: name);
      // Inside the grid, less half the widest stroke.
      expect(bounds.left >= 1.2 && bounds.top >= 1.2 && bounds.right <= 22.8 && bounds.bottom <= 22.8, isTrue, reason: '$name: $bounds');
    }
  });

  test('path data: relative and absolute, repeats, smooth curves and arcs', () {
    // A circle of radius 3 round (12, 12), as two arcs.
    expect(svgPath('M9 12a3 3 0 1 0 6 0a3 3 0 1 0-6 0Z').getBounds(), rectMoreOrLessEquals(const Rect.fromLTRB(9, 9, 15, 15), epsilon: 0.01));
    // Lines after a move, and flags written together.
    expect(svgPath('M2 2 4 4 6 2').getBounds(), const Rect.fromLTRB(2, 2, 6, 4));
    expect(svgPath('M0 0a1 1 0 011 1').getBounds().right, closeTo(1, 0.01));
    expect(() => svgPath('2 2'), throwsFormatException);
  });
}
