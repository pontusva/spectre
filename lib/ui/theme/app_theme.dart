import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class SpectreColors {
  SpectreColors._();

  static const Color blackDeep = Color(0xFF080808);
  static const Color blackLess = Color(0xFF0D0D0D);
  static const Color blackPanel = Color(0xFF121212);
  static const Color blackHair = Color(0xFF1A1A1A);

  static const Color purpleDeep = Color(0xFF2D0A3E);
  // Brightened so it's legible as link/label TEXT on near-black (the old
  // 0xFF6B00A8 was ~2:1). Still the accent for borders/squares.
  static const Color purpleBright = Color(0xFFA95EEA);
  static const Color purpleHair = Color(0xFF1F0530);

  static const Color redBlood = Color(0xFF8B0000);
  static const Color redDanger = Color(0xFFE23B3B);
  static const Color redDecay = Color(0xFFAA1A1A);

  // Text tiers, tuned for readability on the near-black backgrounds (≈AA for
  // body/helper text). Hierarchy preserved bright > cold > dim > faint; the
  // old dim/faint (0x66/0x3D) were ~3:1 and ~1.7:1 — unreadable for helpers.
  static const Color textBright = Color(0xFFECECEC);
  static const Color textCold = Color(0xFFC2C2C2);
  static const Color textDim = Color(0xFF9C9C9C);
  static const Color textFaint = Color(0xFF7C7C7C);

  static const Color matrixGreen = Color(0xFF00FF41);
  static const Color matrixDim = Color(0xFF1FC03A);

  // Slightly lighter so separators are actually visible on black.
  static const Color hairline = Color(0xFF2E2E2E);
}

class SpectreTypography {
  SpectreTypography._();

  static const String _mono = 'JetBrainsMono';
  static const List<String> _monoFallback = <String>[
    'JetBrains Mono',
    'Courier New',
    'Courier',
    'monospace',
  ];

  static TextStyle base({
    double size = 13,
    FontWeight weight = FontWeight.w400,
    Color color = SpectreColors.textCold,
    double letterSpacing = 0.4,
    double height = 1.35,
  }) {
    return TextStyle(
      fontFamily: _mono,
      fontFamilyFallback: _monoFallback,
      fontSize: size,
      fontWeight: weight,
      color: color,
      letterSpacing: letterSpacing,
      height: height,
    );
  }

  static TextStyle display() => base(
        size: 22,
        weight: FontWeight.w700,
        color: SpectreColors.textBright,
        letterSpacing: 6,
        height: 1.0,
      );

  static TextStyle title() => base(
        size: 15,
        weight: FontWeight.w600,
        color: SpectreColors.textBright,
        letterSpacing: 2.4,
      );

  static TextStyle body() => base();

  static TextStyle mono() => base(letterSpacing: 0.2);

  static TextStyle caption() => base(
        size: 10.5,
        color: SpectreColors.textDim,
        letterSpacing: 1.6,
      );

  static TextStyle stamp() => base(
        size: 10,
        color: SpectreColors.textDim,
        letterSpacing: 1.2,
      );

  static TextStyle badge() => base(
        size: 10,
        weight: FontWeight.w700,
        color: SpectreColors.textBright,
        letterSpacing: 1.4,
      );

  static TextStyle action() => base(
        size: 12,
        weight: FontWeight.w600,
        color: SpectreColors.textBright,
        letterSpacing: 2.0,
      );

  static TextStyle danger() => base(
        size: 12,
        weight: FontWeight.w700,
        color: SpectreColors.redDanger,
        letterSpacing: 2.0,
      );
}

class AppTheme {
  AppTheme._();

  static ThemeData dark() {
    const base = ColorScheme.dark(
      brightness: Brightness.dark,
      primary: SpectreColors.purpleBright,
      onPrimary: SpectreColors.textBright,
      secondary: SpectreColors.matrixGreen,
      onSecondary: SpectreColors.blackDeep,
      surface: SpectreColors.blackLess,
      onSurface: SpectreColors.textCold,
      error: SpectreColors.redDanger,
      onError: SpectreColors.textBright,
    );

    final textTheme = TextTheme(
      displayLarge: SpectreTypography.display(),
      headlineMedium: SpectreTypography.title(),
      titleMedium: SpectreTypography.title().copyWith(fontSize: 13),
      bodyLarge: SpectreTypography.body(),
      bodyMedium: SpectreTypography.body(),
      bodySmall: SpectreTypography.caption(),
      labelLarge: SpectreTypography.action(),
      labelMedium: SpectreTypography.action().copyWith(fontSize: 11),
      labelSmall: SpectreTypography.caption(),
    );

    return ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
      colorScheme: base,
      scaffoldBackgroundColor: SpectreColors.blackDeep,
      canvasColor: SpectreColors.blackDeep,
      dividerColor: SpectreColors.hairline,
      splashColor: SpectreColors.purpleDeep.withOpacity(0.25),
      highlightColor: SpectreColors.purpleDeep.withOpacity(0.15),
      hoverColor: SpectreColors.purpleHair,
      textTheme: textTheme,
      iconTheme: const IconThemeData(
        color: SpectreColors.textCold,
        size: 20,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: SpectreColors.blackDeep,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        iconTheme: const IconThemeData(color: SpectreColors.textBright),
        titleTextStyle: SpectreTypography.display().copyWith(fontSize: 18),
        systemOverlayStyle: const SystemUiOverlayStyle(
          statusBarColor: SpectreColors.blackDeep,
          statusBarIconBrightness: Brightness.light,
          systemNavigationBarColor: SpectreColors.blackDeep,
          systemNavigationBarIconBrightness: Brightness.light,
        ),
        shape: const Border(
          bottom: BorderSide(color: SpectreColors.hairline, width: 1),
        ),
      ),
      cardTheme: CardThemeData(
        color: SpectreColors.blackLess,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.zero,
          side: BorderSide(color: SpectreColors.hairline, width: 1),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: SpectreColors.hairline,
        thickness: 1,
        space: 1,
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: SpectreColors.purpleDeep,
        foregroundColor: SpectreColors.textBright,
        elevation: 0,
        focusElevation: 0,
        hoverElevation: 0,
        highlightElevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.zero,
          side: BorderSide(color: SpectreColors.purpleBright, width: 1),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: SpectreColors.blackLess,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        hintStyle: SpectreTypography.body().copyWith(color: SpectreColors.textDim),
        labelStyle: SpectreTypography.caption(),
        border: const OutlineInputBorder(
          borderRadius: BorderRadius.zero,
          borderSide: BorderSide(color: SpectreColors.hairline, width: 1),
        ),
        enabledBorder: const OutlineInputBorder(
          borderRadius: BorderRadius.zero,
          borderSide: BorderSide(color: SpectreColors.hairline, width: 1),
        ),
        focusedBorder: const OutlineInputBorder(
          borderRadius: BorderRadius.zero,
          borderSide: BorderSide(color: SpectreColors.purpleBright, width: 1),
        ),
        errorBorder: const OutlineInputBorder(
          borderRadius: BorderRadius.zero,
          borderSide: BorderSide(color: SpectreColors.redDanger, width: 1),
        ),
      ),
      textSelectionTheme: const TextSelectionThemeData(
        cursorColor: SpectreColors.purpleBright,
        selectionColor: Color(0x55A95EEA),
        selectionHandleColor: SpectreColors.purpleBright,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: SpectreColors.blackLess,
        elevation: 0,
        titleTextStyle: SpectreTypography.title(),
        contentTextStyle: SpectreTypography.body(),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.zero,
          side: BorderSide(color: SpectreColors.hairline, width: 1),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: SpectreColors.blackLess,
        elevation: 0,
        modalElevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.zero,
          side: BorderSide(color: SpectreColors.hairline, width: 1),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: SpectreColors.blackLess,
        contentTextStyle: SpectreTypography.body(),
        actionTextColor: SpectreColors.matrixGreen,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.zero,
          side: BorderSide(color: SpectreColors.hairline, width: 1),
        ),
        behavior: SnackBarBehavior.fixed,
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: SpectreColors.purpleBright,
        linearTrackColor: SpectreColors.blackHair,
        circularTrackColor: SpectreColors.blackHair,
      ),
      checkboxTheme: CheckboxThemeData(
        side: const BorderSide(color: SpectreColors.textDim, width: 1),
        fillColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return SpectreColors.purpleBright;
          }
          return SpectreColors.blackLess;
        }),
        checkColor: WidgetStateProperty.all(SpectreColors.textBright),
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.android: _NoSoftTransitionBuilder(),
          TargetPlatform.iOS: _NoSoftTransitionBuilder(),
          TargetPlatform.linux: _NoSoftTransitionBuilder(),
          TargetPlatform.macOS: _NoSoftTransitionBuilder(),
          TargetPlatform.windows: _NoSoftTransitionBuilder(),
        },
      ),
    );
  }
}

class _NoSoftTransitionBuilder extends PageTransitionsBuilder {
  const _NoSoftTransitionBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return FadeTransition(
      opacity: animation,
      child: child,
    );
  }
}

class NoisePainter extends CustomPainter {
  NoisePainter({this.seed = 1337, this.opacity = 0.06});

  final int seed;
  final double opacity;

  @override
  void paint(Canvas canvas, Size size) {
    final rng = Random(seed);
    final paint = Paint()
      ..color = SpectreColors.textCold.withOpacity(opacity)
      ..style = PaintingStyle.fill;
    final count = (size.width * size.height * 0.0018).toInt();
    for (var i = 0; i < count; i++) {
      final x = rng.nextDouble() * size.width;
      final y = rng.nextDouble() * size.height;
      canvas.drawRect(Rect.fromLTWH(x, y, 1, 1), paint);
    }
    final purplePaint = Paint()
      ..color = SpectreColors.purpleBright.withOpacity(opacity * 0.5);
    final purpleCount = count ~/ 6;
    for (var i = 0; i < purpleCount; i++) {
      final x = rng.nextDouble() * size.width;
      final y = rng.nextDouble() * size.height;
      canvas.drawRect(Rect.fromLTWH(x, y, 1, 1), purplePaint);
    }
  }

  @override
  bool shouldRepaint(NoisePainter old) =>
      old.seed != seed || old.opacity != opacity;
}

class ScanlinePainter extends CustomPainter {
  ScanlinePainter({this.spacing = 3.0, this.opacity = 0.045});

  final double spacing;
  final double opacity;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = SpectreColors.textCold.withOpacity(opacity)
      ..style = PaintingStyle.fill;
    for (var y = 0.0; y < size.height; y += spacing) {
      canvas.drawRect(Rect.fromLTWH(0, y, size.width, 1), paint);
    }
  }

  @override
  bool shouldRepaint(ScanlinePainter old) =>
      old.spacing != spacing || old.opacity != opacity;
}

class NoiseBackground extends StatelessWidget {
  const NoiseBackground({
    super.key,
    required this.child,
    this.scanlines = true,
  });

  final Widget child;
  final bool scanlines;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: ColoredBox(color: SpectreColors.blackDeep),
        ),
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(painter: NoisePainter()),
          ),
        ),
        if (scanlines)
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(painter: ScanlinePainter()),
            ),
          ),
        child,
      ],
    );
  }
}

class HairlineDivider extends StatelessWidget {
  const HairlineDivider({super.key, this.color, this.height = 1});

  final Color? color;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      color: color ?? SpectreColors.hairline,
    );
  }
}

class DashedDivider extends StatelessWidget {
  const DashedDivider({
    super.key,
    this.color = SpectreColors.hairline,
    this.dash = 4,
    this.gap = 3,
    this.height = 1,
  });

  final Color color;
  final double dash;
  final double gap;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: CustomPaint(
        painter: _DashedPainter(color: color, dash: dash, gap: gap),
      ),
    );
  }
}

class _DashedPainter extends CustomPainter {
  _DashedPainter({
    required this.color,
    required this.dash,
    required this.gap,
  });

  final Color color;
  final double dash;
  final double gap;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    var x = 0.0;
    while (x < size.width) {
      canvas.drawRect(Rect.fromLTWH(x, 0, dash, size.height), paint);
      x += dash + gap;
    }
  }

  @override
  bool shouldRepaint(_DashedPainter old) =>
      old.color != color || old.dash != dash || old.gap != gap;
}

class SpectreSpacing {
  SpectreSpacing._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
}

class SpectreIcons {
  SpectreIcons._();

  static const String bullet = '■';
  static const String dotFilled = '●';
  static const String dotEmpty = '○';
  static const String chevron = '›';
  static const String cross = '×';
  static const String check = '✓';
  static const String warning = '!';
  static const String block = '█';
}
