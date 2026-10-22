// The icons, drawn as the extension draws them: its SVG paths on a 24-point grid, stroked with
// round ends and joins, at its stroke widths (src/entrypoints/popup/*.svelte). The few it has no
// need of (scan, paste, rename, open in a browser) are Lucide's (ISC licence), the set the
// extension's recycle icon comes from too.
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

// One icon: SVG path data on a 24×24 grid, stroked `stroke` wide, or filled when `stroke` is 0.
class Glyph {
  final List<String> paths;
  final double stroke;
  Glyph(this.paths, {this.stroke = 2});

  late final Path path = () {
    final path = Path();
    for (final d in paths) {
      path.addPath(svgPath(d), Offset.zero);
    }
    return path;
  }();
}

// A circle and a rounded rectangle as path data, for the extension's <circle> and <rect>.
String _circle(double cx, double cy, double r) => 'M${cx - r} ${cy}a$r $r 0 1 0 ${2 * r} 0a$r $r 0 1 0 ${-2 * r} 0Z';
String _rect(double x, double y, double w, double h, double r) =>
    'M${x + r} ${y}h${w - 2 * r}a$r $r 0 0 1 $r ${r}v${h - 2 * r}a$r $r 0 0 1 ${-r} ${r}h${-(w - 2 * r)}a$r $r 0 0 1 ${-r} ${-r}v${-(h - 2 * r)}a$r $r 0 0 1 $r ${-r}Z';

abstract final class ZIcons {
  static final check = Glyph(['M5 12.5 9.5 17 19 7.5']);
  static final close = Glyph(['M6 6l12 12M18 6 6 18']);
  static final back = Glyph(['M19 12H5m6-6-6 6 6 6']);
  static final chevronRight = Glyph(['m9 6 6 6-6 6']);
  static final chevronDown = Glyph(['m6 9 6 6 6-6']);
  static final plus = Glyph(['M12 5v14M5 12h14']);
  static final import = Glyph(['M12 4v11m-5-5 5 5 5-5M4 15v3a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-3']);
  static final copy = Glyph([_rect(8, 8, 13, 13, 2.5), 'M16 8V5.5A2.5 2.5 0 0 0 13.5 3h-8A2.5 2.5 0 0 0 3 5.5v8A2.5 2.5 0 0 0 5.5 16H8']);
  static final eye = Glyph(['M2 12s3.6-7 10-7 10 7 10 7-3.6 7-10 7S2 12 2 12Z', _circle(12, 12, 3)]);
  static final eyeOff = Glyph([
    'M10.7 5.1A10.4 10.4 0 0 1 12 5c6.4 0 10 7 10 7a17.6 17.6 0 0 1-2.1 3',
    'M6.6 6.6C3.7 8.4 2 12 2 12s3.6 7 10 7a9.8 9.8 0 0 0 5.4-1.6',
    'M9.9 9.9a3 3 0 0 0 4.2 4.2',
    'm2 2 20 20',
  ]);
  static final lock = Glyph([_rect(4, 11, 16, 10, 2.5), 'M8 11V7.5a4 4 0 0 1 8 0V11'], stroke: 1.75);
  static final settings = Glyph(['M21 5h-7M10 5H3m18 7h-9m-4 0H3m18 7h-5m-4 0H3M14 3v4m-6 3v4m8 3v4'], stroke: 1.75);
  static final addressBook = Glyph(['M5 4.5A2.5 2.5 0 0 1 7.5 2H19v20H7.5A2.5 2.5 0 0 1 5 19.5v-15Z', 'M5 19.5A2.5 2.5 0 0 1 7.5 17H19', _circle(12, 9, 2.5)], stroke: 1.75);
  static final trash = Glyph(['M4 7h16m-10 4v6m4-6v6M6 7l1 12a2 2 0 0 0 2 2h6a2 2 0 0 0 2-2l1-12M9 7V4h6v3'], stroke: 1.75);
  static final privateKey = Glyph(['m15.5 7.5 2.3 2.3a1 1 0 0 0 1.4 0l2.1-2.1a1 1 0 0 0 0-1.4L19 4m2-2-9.6 9.6', _circle(7.5, 15.5, 5.5)], stroke: 1.75);
  static final phrase = Glyph(['M4 6h16M4 12h16M4 18h10'], stroke: 1.75);
  static final more = Glyph([_circle(12, 4, 1.75), _circle(12, 12, 1.75), _circle(12, 20, 1.75)], stroke: 0);
  static final explore = Glyph([_circle(11, 11, 6.5), 'm20 20-4.4-4.4']);
  static final receive = Glyph(['M18 6 6 18m0-10v10h10']);
  static final send = Glyph(['M6 18 18 6M8 6h10v10']);
  static final swap = Glyph(['M4 8h16m-4-4 4 4-4 4', 'M20 16H4m4-4-4 4 4 4']);
  static final flip = Glyph(['M8 4v16m0 0-4-4m4 4 4-4M16 20V4m0 0-4 4m4-4 4 4']);
  static final filter = Glyph(['M3 6h18M6 12h12m-8 6h4']);
  static final reclaim = Glyph([
    'M7 19H4.815a1.83 1.83 0 0 1-1.57-.881 1.785 1.785 0 0 1-.004-1.784L7.196 9.5',
    'M11 19h8.203a1.83 1.83 0 0 0 1.556-.89 1.784 1.784 0 0 0 0-1.775l-1.226-2.12',
    'm14 16-3 3 3 3',
    'M8.293 13.596 7.196 9.5 3.1 10.598',
    'm9.344 5.811 1.093-1.892A1.83 1.83 0 0 1 11.985 3a1.784 1.784 0 0 1 1.546.888l3.943 6.843',
    'm13.378 9.633 4.096 1.098 1.097-4.096',
  ]);
  static final app = Glyph([_rect(4, 4, 6.5, 6.5, 1.6), _rect(13.5, 4, 6.5, 6.5, 1.6), _rect(4, 13.5, 6.5, 6.5, 1.6), _rect(13.5, 13.5, 6.5, 6.5, 1.6)], stroke: 1.9);
  static final network = Glyph([_circle(12, 12, 9.5), 'M12 2.5a14 14 0 0 0 0 19 14 14 0 0 0 0-19ZM2.5 12h19'], stroke: 1.75);
  // For empty and failed lists, as the extension's.
  static final clock = Glyph([_circle(12, 12, 9), 'M12 7.5V12l3 2'], stroke: 1.75);
  static final offline = Glyph(['m2 2 20 20', 'M5.78 5.78A7 7 0 0 0 9 19h8.5a4.5 4.5 0 0 0 1.31-.19', 'M21.53 16.5A4.5 4.5 0 0 0 17.5 10h-1.79A7 7 0 0 0 10 5.07'], stroke: 1.75);
  static final info = Glyph([_circle(12, 12, 9.5), 'M12 16.5v-5m0-3.5h.01'], stroke: 1.75);
  static final warning = Glyph(['M10.3 4.2 2.6 17.5A2 2 0 0 0 4.3 20.5h15.4a2 2 0 0 0 1.7-3L13.7 4.2a2 2 0 0 0-3.4 0ZM12 9.5v4m0 3.5h.01'], stroke: 1.75);
  // Lucide's, for what the extension doesn't do.
  static final scan = Glyph(['M3 7V5a2 2 0 0 1 2-2h2', 'M17 3h2a2 2 0 0 1 2 2v2', 'M21 17v2a2 2 0 0 1-2 2h-2', 'M7 21H5a2 2 0 0 1-2-2v-2', 'M7 12h10']);
  static final paste = Glyph([_rect(8, 2, 8, 4, 1), 'M16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2']);
  static final rename = Glyph(['M21.174 6.812a1 1 0 0 0-3.986-3.987L3.842 16.174a2 2 0 0 0-.5.83l-1.321 4.352a.5.5 0 0 0 .623.622l4.353-1.32a2 2 0 0 0 .83-.497z', 'm15 5 4 4'], stroke: 1.75);
  static final openOutside = Glyph(['M15 3h6v6', 'M10 14 21 3', 'M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6']);
  // The verified mark: a rosette, then a check on it (src/components/Verified.svelte).
  static final rosette = Glyph([
    'M3.85 8.62a4 4 0 0 1 4.78-4.77 4 4 0 0 1 6.74 0 4 4 0 0 1 4.78 4.78 4 4 0 0 1 0 6.74 4 4 0 0 1-4.77 4.78 4 4 0 0 1-6.75 0 4 4 0 0 1-4.78-4.77 4 4 0 0 1 0-6.76Z',
  ], stroke: 0);
  static final rosetteCheck = Glyph(['m9 12 2 2 4-4'], stroke: 2.4);
}

// An icon, sized and coloured like Flutter's own: from the IconTheme around it (an IconButton's,
// say) unless given.
class ZIcon extends StatelessWidget {
  final Glyph glyph;
  final double? size;
  final Color? color;
  const ZIcon(this.glyph, {super.key, this.size, this.color});

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final side = size ?? theme.size ?? 24;
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: side,
        child: CustomPaint(painter: GlyphPainter([(glyph, color ?? theme.color ?? const Color(0xFF888888))])),
      ),
    );
  }
}

// Glyphs drawn one over another, each in its colour, scaled from the 24-point grid.
class GlyphPainter extends CustomPainter {
  final List<(Glyph, Color)> layers;
  GlyphPainter(this.layers);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24);
    for (final (glyph, color) in layers) {
      final paint = Paint()
        ..color = color
        ..isAntiAlias = true;
      if (glyph.stroke == 0) {
        paint.style = PaintingStyle.fill;
      } else {
        paint
          ..style = PaintingStyle.stroke
          ..strokeWidth = glyph.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round;
      }
      canvas.drawPath(glyph.path, paint);
    }
  }

  @override
  bool shouldRepaint(GlyphPainter old) => !listEquals(old.layers, layers);
}

// SVG path data to a Path: moves, lines, cubic and quadratic curves (smooth ones too), arcs and
// closes, absolute or relative, with the repeats SVG allows after a command.
Path svgPath(String d) {
  final path = Path();
  final reader = _PathReader(d);
  var command = '';
  double x = 0, y = 0, startX = 0, startY = 0;
  // The last control point, for a smooth curve's reflection.
  double? controlX, controlY;
  while (reader.more) {
    if (reader.atCommand) {
      command = reader.command();
    } else if (command.isEmpty) {
      throw FormatException('Path data must start with a command', d);
    }
    final relative = command == command.toLowerCase();
    final ox = relative ? x : 0.0, oy = relative ? y : 0.0;
    var curve = false;
    switch (command.toUpperCase()) {
      case 'M':
        x = ox + reader.number();
        y = oy + reader.number();
        path.moveTo(x, y);
        startX = x;
        startY = y;
        // More pairs after a move are lines.
        command = relative ? 'l' : 'L';
      case 'L':
        x = ox + reader.number();
        y = oy + reader.number();
        path.lineTo(x, y);
      case 'H':
        x = ox + reader.number();
        path.lineTo(x, y);
      case 'V':
        y = oy + reader.number();
        path.lineTo(x, y);
      case 'C' || 'S':
        final double x1, y1;
        if (command.toUpperCase() == 'C') {
          x1 = ox + reader.number();
          y1 = oy + reader.number();
        } else {
          x1 = controlX == null ? x : 2 * x - controlX;
          y1 = controlY == null ? y : 2 * y - controlY;
        }
        final x2 = ox + reader.number(), y2 = oy + reader.number();
        x = ox + reader.number();
        y = oy + reader.number();
        path.cubicTo(x1, y1, x2, y2, x, y);
        controlX = x2;
        controlY = y2;
        curve = true;
      case 'Q':
        final x1 = ox + reader.number(), y1 = oy + reader.number();
        x = ox + reader.number();
        y = oy + reader.number();
        path.quadraticBezierTo(x1, y1, x, y);
      case 'A':
        final rx = reader.number(), ry = reader.number(), rotation = reader.number();
        final large = reader.flag(), sweep = reader.flag();
        x = ox + reader.number();
        y = oy + reader.number();
        path.arcToPoint(Offset(x, y), radius: Radius.elliptical(rx, ry), rotation: rotation, largeArc: large, clockwise: sweep);
      case 'Z':
        path.close();
        x = startX;
        y = startY;
        command = '';
      default:
        throw FormatException('Unsupported path command $command', d);
    }
    if (!curve) controlX = controlY = null;
  }
  return path;
}

class _PathReader {
  final String text;
  int _at = 0;
  _PathReader(this.text);

  static final _number = RegExp(r'[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?');

  void _skip() {
    while (_at < text.length && ' ,\t\n\r'.contains(text[_at])) {
      _at++;
    }
  }

  bool get more {
    _skip();
    return _at < text.length;
  }

  bool get atCommand {
    _skip();
    return _at < text.length && RegExp('[A-Za-z]').hasMatch(text[_at]);
  }

  String command() {
    _skip();
    return text[_at++];
  }

  double number() {
    _skip();
    final match = _number.matchAsPrefix(text, _at);
    if (match == null) throw FormatException('Expected a number', text, _at);
    _at = match.end;
    return double.parse(match[0]!);
  }

  // An arc's flags are one digit each, and may be written with nothing between them.
  bool flag() {
    _skip();
    if (_at >= text.length || (text[_at] != '0' && text[_at] != '1')) throw FormatException('Expected a flag', text, _at);
    return text[_at++] == '1';
  }
}
