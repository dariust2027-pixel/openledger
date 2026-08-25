import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../db/providers.dart';

/// Accent colors — any accent works with any mode.
enum AppAccent {
  blue(Color(0xFF2D6CDF), 'Blue'),
  gold(Color(0xFFD4A017), 'Gold'),
  emerald(Color(0xFF1E9E6A), 'Emerald'),
  violet(Color(0xFF7C4DD4), 'Violet'),
  copper(Color(0xFFB8643A), 'Copper');

  final Color seed;
  final String label;
  const AppAccent(this.seed, this.label);
}

/// AppThemeMode adds AMOLED to Flutter's ThemeMode.
enum AppThemeMode { system, light, dark, amoled }

class ThemeState {
  final AppThemeMode mode;
  final AppAccent accent;

  const ThemeState({this.mode = AppThemeMode.system, this.accent = AppAccent.blue});

  ThemeState copyWith({AppThemeMode? mode, AppAccent? accent}) =>
      ThemeState(mode: mode ?? this.mode, accent: accent ?? this.accent);
}

class ThemeController extends Notifier<ThemeState> {
  @override
  ThemeState build() {
    _load();
    return const ThemeState();
  }

  Future<void> _load() async {
    final db = ref.read(appDbProvider);
    final mode = await db.getSetting<String>('theme_mode', 'system');
    final accent = await db.getSetting<String>('theme_accent', 'blue');
    state = state.copyWith(
      mode: AppThemeMode.values.asNameMap()[mode] ?? AppThemeMode.system,
      accent: AppAccent.values.asNameMap()[accent] ?? AppAccent.blue,
    );
  }

  Future<void> setMode(AppThemeMode mode) async {
    state = state.copyWith(mode: mode);
    await ref.read(appDbProvider).setSetting('theme_mode', mode.name);
  }

  Future<void> setAccent(AppAccent accent) async {
    state = state.copyWith(accent: accent);
    await ref.read(appDbProvider).setSetting('theme_accent', accent.name);
  }
}

final themeControllerProvider =
    NotifierProvider<ThemeController, ThemeState>(ThemeController.new);

Brightness _brightnessOf(AppThemeMode mode, Brightness platform) {
  switch (mode) {
    case AppThemeMode.system:
      return platform;
    case AppThemeMode.light:
      return Brightness.light;
    case AppThemeMode.dark:
    case AppThemeMode.amoled:
      return Brightness.dark;
  }
}

/// Builds the Material-3 scheme for a mode+accent pair.
/// AMOLED overrides surfaces to true black; elevation is conveyed with
/// subtle borders instead of shadows (shadows are invisible on black).
ThemeData buildAppTheme(ThemeState ts, Brightness platformBrightness) {
  final brightness = _brightnessOf(ts.mode, platformBrightness);
  final isBlack = ts.mode == AppThemeMode.amoled && brightness == Brightness.dark;

  ColorScheme scheme = ColorScheme.fromSeed(
    seedColor: ts.accent.seed,
    brightness: brightness,
  );

  if (isBlack) {
    scheme = scheme.copyWith(
      surface: Colors.black,
      surfaceContainerLowest: Colors.black,
      surfaceContainerLow: const Color(0xFF050505),
      surfaceContainer: const Color(0xFF0A0A0A),
      surfaceContainerHigh: const Color(0xFF101010),
      surfaceContainerHighest: const Color(0xFF161616),
      onSurface: Colors.white,
      onSurfaceVariant: const Color(0xFFBBBBBB),
    );
  }

  final base = ThemeData(useMaterial3: true, colorScheme: scheme, brightness: brightness);

  if (!isBlack) return base;

  final outline = scheme.outline.withValues(alpha: 0.35);
  return base.copyWith(
    cardTheme: CardThemeData(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: outline),
      ),
    ),
    dividerColor: outline,
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Colors.black,
      indicatorColor: scheme.primary.withValues(alpha: 0.25),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.black,
      scrolledUnderElevation: 0,
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: outline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: outline),
      ),
    ),
  );
}
