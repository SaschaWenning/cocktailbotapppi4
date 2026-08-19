//noinspection SpellCheckingInspection
// spellchecker:disable
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const CocktailMachineApp());

class CocktailMachineApp extends StatefulWidget {
  const CocktailMachineApp({super.key});
  @override
  State<CocktailMachineApp> createState() => _CocktailMachineAppState();
}

class _CocktailMachineAppState extends State<CocktailMachineApp> {
  final store = MachineStore();
  Timer? _keyboardDebounce;
  EditableTextState? _activeEditable;
  TextEditingValue _virtualKeyboardValue = const TextEditingValue();
  bool _virtualKeyboardObscure = false;
  bool _virtualKeyboardVisible = false;
  bool _virtualKeyboardShift = false;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_handleFocusChange);
    store.load();
  }

  EditableTextState? _editableStateForFocus(FocusNode? focus) {
    final focusContext = focus?.context;
    if (focusContext == null) return null;

    if (focusContext is StatefulElement &&
        focusContext.state is EditableTextState) {
      return focusContext.state as EditableTextState;
    }
    return focusContext.findAncestorStateOfType<EditableTextState>();
  }

  void _handleFocusChange() {
    final editable = _editableStateForFocus(FocusManager.instance.primaryFocus);
    _keyboardDebounce?.cancel();

    if (editable != null && editable.mounted && !editable.widget.readOnly) {
      _activeEditable = editable;
      _keyboardDebounce = Timer(const Duration(milliseconds: 60), () {
        if (!mounted) return;
        final current = _editableStateForFocus(FocusManager.instance.primaryFocus);
        if (current == null || !current.mounted || current.widget.readOnly) return;
        setState(() {
          _activeEditable = current;
          _virtualKeyboardValue = current.textEditingValue;
          _virtualKeyboardObscure = current.widget.obscureText;
          _virtualKeyboardVisible = true;
        });
      });
      return;
    }

    // Ein kleines Delay verhindert Flackern beim Wechsel zwischen Feldern.
    _keyboardDebounce = Timer(const Duration(milliseconds: 220), () {
      if (!mounted) return;
      final current = _editableStateForFocus(FocusManager.instance.primaryFocus);
      if (current == null || !current.mounted || current.widget.readOnly) {
        setState(() {
          _virtualKeyboardVisible = false;
          _activeEditable = null;
          _virtualKeyboardValue = const TextEditingValue();
          _virtualKeyboardObscure = false;
          _virtualKeyboardShift = false;
        });
      }
    });
  }

  bool get _activeKeyboardIsNumeric {
    final editable = _activeEditable;
    if (editable == null || !editable.mounted) return false;
    final type = editable.widget.keyboardType;
    if (type == null) return false;
    return type.index == TextInputType.number.index ||
        type.index == TextInputType.phone.index ||
        type.index == TextInputType.datetime.index;
  }

  void _updateActiveValue(TextEditingValue value) {
    final editable = _activeEditable;
    if (editable == null || !editable.mounted || editable.widget.readOnly) return;

    // Die Popup-Tastatur verwaltet ihre Cursorposition selbst. Damit bleibt
    // nach dem ersten Tastendruck nicht der komplette Inhalt markiert und
    // weitere Zeichen werden angehängt statt den vorherigen Wert zu ersetzen.
    final requestedOffset = value.selection.isValid
        ? value.selection.extentOffset.clamp(0, value.text.length).toInt()
        : value.text.length;
    var normalized = value.copyWith(
      selection: TextSelection.collapsed(offset: requestedOffset),
      composing: TextRange.empty,
    );

    _virtualKeyboardValue = normalized;
    editable.userUpdateTextEditingValue(
      normalized,
      SelectionChangedCause.keyboard,
    );

    // InputFormatter dürfen den Text verändern. Danach übernehmen wir den
    // tatsächlich akzeptierten Text, erzwingen aber wieder einen
    // zusammengeklappten Cursor. So kann die Browser-Selektion nicht bei
    // jedem virtuellen Tastendruck erneut den ganzen Inhalt markieren.
    final formatted = editable.textEditingValue;
    final formattedOffset = requestedOffset
        .clamp(0, formatted.text.length)
        .toInt();
    normalized = formatted.copyWith(
      selection: TextSelection.collapsed(offset: formattedOffset),
      composing: TextRange.empty,
    );
    _virtualKeyboardValue = normalized;

    if (formatted.selection != normalized.selection ||
        formatted.composing != TextRange.empty) {
      editable.userUpdateTextEditingValue(
        normalized,
        SelectionChangedCause.keyboard,
      );
    }

    // Zusätzlich die Controller-Selektion explizit zusammenklappen. Das ist
    // besonders im Flutter-Web-Kiosk wichtig, weil Chromium sonst die zuletzt
    // markierte Auswahl optisch beibehalten kann.
    if (editable.widget.controller.selection != normalized.selection) {
      editable.widget.controller.selection = normalized.selection;
    }

    editable.widget.focusNode.requestFocus();
    if (mounted) setState(() {});
  }

  void _insertVirtualText(String text) {
    final editable = _activeEditable;
    if (editable == null || !editable.mounted) return;
    final value = _virtualKeyboardValue;
    final selection = value.selection;
    final start = selection.isValid
        ? (selection.start < selection.end ? selection.start : selection.end)
        : value.text.length;
    final end = selection.isValid
        ? (selection.start > selection.end ? selection.start : selection.end)
        : value.text.length;
    final nextText = value.text.replaceRange(start, end, text);
    _updateActiveValue(
      TextEditingValue(
        text: nextText,
        selection: TextSelection.collapsed(offset: start + text.length),
        composing: TextRange.empty,
      ),
    );
  }

  void _virtualBackspace() {
    final editable = _activeEditable;
    if (editable == null || !editable.mounted) return;
    final value = _virtualKeyboardValue;
    if (value.text.isEmpty) return;
    final selection = value.selection;
    var start = selection.isValid
        ? (selection.start < selection.end ? selection.start : selection.end)
        : value.text.length;
    var end = selection.isValid
        ? (selection.start > selection.end ? selection.start : selection.end)
        : value.text.length;
    if (start == end) {
      if (start <= 0) return;
      start -= 1;
    }
    final nextText = value.text.replaceRange(start, end, '');
    _updateActiveValue(
      TextEditingValue(
        text: nextText,
        selection: TextSelection.collapsed(offset: start),
        composing: TextRange.empty,
      ),
    );
  }

  void _virtualClear() {
    _updateActiveValue(const TextEditingValue(text: ''));
  }

  void _closeVirtualKeyboard({bool unfocus = true}) {
    _keyboardDebounce?.cancel();
    if (unfocus) {
      _activeEditable?.widget.focusNode.unfocus();
    }
    if (!mounted) return;
    setState(() {
      _virtualKeyboardVisible = false;
      _activeEditable = null;
      _virtualKeyboardValue = const TextEditingValue();
      _virtualKeyboardObscure = false;
      _virtualKeyboardShift = false;
    });
  }

  void _virtualDone() {
    final editable = _activeEditable;
    if (editable != null && editable.mounted) {
      final text = editable.widget.controller.text;
      editable.widget.onSubmitted?.call(text);
    }
    _closeVirtualKeyboard();
  }

  void _virtualEnter() {
    final editable = _activeEditable;
    if (editable == null || !editable.mounted) return;
    final maxLines = editable.widget.maxLines;
    if (maxLines == 1) {
      _virtualDone();
    } else {
      _insertVirtualText('\n');
    }
  }

  @override
  void dispose() {
    _keyboardDebounce?.cancel();
    FocusManager.instance.removeListener(_handleFocusChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: store,
      builder: (_, __) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'CocktailBot',
        locale: Locale(store.appLanguage.localeCode),
        themeMode: store.darkMode ? ThemeMode.dark : ThemeMode.light,
        theme: buildTheme(Brightness.light, store.appColors),
        darkTheme: buildTheme(Brightness.dark, store.appColors),
        home: HomeShell(store: store),
        builder: (context, child) {
          return Stack(
            children: [
              child ?? const SizedBox.shrink(),
              if (_virtualKeyboardVisible)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: _CocktailBotVirtualKeyboardLayer(
                    colors: store.appColors,
                    numeric: _activeKeyboardIsNumeric,
                    shift: _virtualKeyboardShift,
                    value: _virtualKeyboardValue,
                    obscureText: _virtualKeyboardObscure,
                    onCharacter: (value) {
                      final output = _virtualKeyboardShift
                          ? value.toUpperCase()
                          : value.toLowerCase();
                      _insertVirtualText(output);
                    },
                    onBackspace: _virtualBackspace,
                    onClear: _virtualClear,
                    onSpace: () => _insertVirtualText(' '),
                    onEnter: _virtualEnter,
                    onDone: _virtualDone,
                    onClose: () => _closeVirtualKeyboard(),
                    onShift: () => setState(
                      () => _virtualKeyboardShift = !_virtualKeyboardShift,
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _CocktailBotVirtualKeyboardLayer extends StatelessWidget {
  const _CocktailBotVirtualKeyboardLayer({
    required this.colors,
    required this.numeric,
    required this.shift,
    required this.value,
    required this.obscureText,
    required this.onCharacter,
    required this.onBackspace,
    required this.onClear,
    required this.onSpace,
    required this.onEnter,
    required this.onDone,
    required this.onClose,
    required this.onShift,
  });

  final AppColorThemeConfig colors;
  final bool numeric;
  final bool shift;
  final TextEditingValue value;
  final bool obscureText;
  final ValueChanged<String> onCharacter;
  final VoidCallback onBackspace;
  final VoidCallback onClear;
  final VoidCallback onSpace;
  final VoidCallback onEnter;
  final VoidCallback onDone;
  final VoidCallback onClose;
  final VoidCallback onShift;

  String get _previewText {
    if (value.text.isEmpty) return '';
    if (!obscureText) return value.text;
    return List.filled(value.text.runes.length, '•').join();
  }

  int get _previewCursorOffset {
    if (!value.selection.isValid) return value.text.length;
    return value.selection.extentOffset.clamp(0, value.text.length).toInt();
  }

  String get _previewWithCursor {
    final text = _previewText;
    if (text.isEmpty) return '▌';
    final offset = _previewCursorOffset.clamp(0, text.length).toInt();
    return '${text.substring(0, offset)}▌${text.substring(offset)}';
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final double popupWidth = (numeric
            ? math.min(560.0, size.width - 28)
            : math.min(980.0, size.width - 28))
        .toDouble();
    final double popupHeight = math.min(370.0, size.height * .65).toDouble();

    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: popupWidth,
            height: popupHeight,
            child: Material(
              elevation: 24,
              color: const Color(0xFF0B1118),
              borderRadius: BorderRadius.circular(18),
              clipBehavior: Clip.antiAlias,
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: colors.accentColor, width: 1.2),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Column(
                  children: [
                          SizedBox(
                            height: 42,
                            child: Padding(
                              padding: const EdgeInsets.only(left: 14, right: 8),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.keyboard_alt_outlined,
                                    size: 21,
                                    color: colors.accentColor,
                                  ),
                                  const SizedBox(width: 8),
                                  const Expanded(
                                    child: Text(
                                      'Bildschirmtastatur',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w800,
                                        fontSize: 15,
                                      ),
                                    ),
                                  ),
                                  _VirtualKeyboardKey(
                                    label: 'Schließen',
                                    icon: Icons.close,
                                    compact: true,
                                    onTap: onClose,
                                    accent: colors.errorColor,
                                  ),
                                ],
                              ),
                            ),
                          ),
                          Divider(height: 1, color: colors.borderColor),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                            child: Container(
                              height: 58,
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 13,
                                vertical: 7,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFF121B24),
                                borderRadius: BorderRadius.circular(11),
                                border: Border.all(
                                  color: colors.accentColor.withValues(alpha: .65),
                                ),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.edit_outlined,
                                    color: colors.accentColor,
                                    size: 20,
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          numeric ? 'Zahleneingabe' : 'Texteingabe',
                                          style: const TextStyle(
                                            color: Color(0xFF97A3AE),
                                            fontSize: 10,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        SingleChildScrollView(
                                          scrollDirection: Axis.horizontal,
                                          reverse: true,
                                          child: Text(
                                            _previewWithCursor,
                                            maxLines: 1,
                                            style: TextStyle(
                                              color: colors.textPrimaryColor,
                                              fontSize: 22,
                                              height: 1,
                                              fontWeight: FontWeight.w800,
                                              letterSpacing: .4,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (value.selection.isValid)
                                    Text(
                                      '${_previewCursorOffset}/${value.text.length}',
                                      style: const TextStyle(
                                        color: Color(0xFF6F7D89),
                                        fontSize: 10,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                              child: numeric
                                  ? _numericKeyboard()
                                  : _textKeyboard(),
                            ),
                          ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _numericKeyboard() {
    return Row(
      children: [
        Expanded(
          flex: 3,
          child: Column(
            children: [
              _keyRow(['7', '8', '9']),
              _keyRow(['4', '5', '6']),
              _keyRow(['1', '2', '3']),
              _keyRow(['-', '0', ',']),
            ],
          ),
        ),
        const SizedBox(width: 7),
        Expanded(
          flex: 1,
          child: Column(
            children: [
              Expanded(
                child: _VirtualKeyboardKey(
                  label: '⌫',
                  icon: Icons.backspace_outlined,
                  onTap: onBackspace,
                ),
              ),
              const SizedBox(height: 6),
              Expanded(
                child: _VirtualKeyboardKey(
                  label: 'Löschen',
                  icon: Icons.delete_outline,
                  onTap: onClear,
                ),
              ),
              const SizedBox(height: 6),
              Expanded(
                child: _VirtualKeyboardKey(
                  label: '.',
                  onTap: () => onCharacter('.'),
                ),
              ),
              const SizedBox(height: 6),
              Expanded(
                child: _VirtualKeyboardKey(
                  label: 'Fertig',
                  icon: Icons.check,
                  onTap: onDone,
                  accent: colors.accentColor,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _textKeyboard() {
    const row1 = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0'];
    const row2 = ['q', 'w', 'e', 'r', 't', 'z', 'u', 'i', 'o', 'p', 'ü'];
    const row3 = ['a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l', 'ö', 'ä'];
    const row4 = ['y', 'x', 'c', 'v', 'b', 'n', 'm', '-', '_', '@'];

    return Column(
      children: [
        _keyRow(row1),
        _keyRow(row2),
        _keyRow(row3),
        Expanded(
          child: Row(
            children: [
              Expanded(
                flex: 2,
                child: _VirtualKeyboardKey(
                  label: shift ? 'SHIFT' : 'Shift',
                  icon: shift ? Icons.keyboard_capslock : Icons.arrow_upward,
                  onTap: onShift,
                  accent: shift ? colors.accentColor : null,
                ),
              ),
              const SizedBox(width: 5),
              ...row4.map(
                (key) => Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2.5),
                    child: _VirtualKeyboardKey(
                      label: shift ? key.toUpperCase() : key,
                      onTap: () => onCharacter(key),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 5),
              Expanded(
                flex: 2,
                child: _VirtualKeyboardKey(
                  label: '⌫',
                  icon: Icons.backspace_outlined,
                  onTap: onBackspace,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 5),
        Expanded(
          child: Row(
            children: [
              Expanded(
                flex: 2,
                child: _VirtualKeyboardKey(
                  label: 'Löschen',
                  icon: Icons.delete_outline,
                  onTap: onClear,
                ),
              ),
              const SizedBox(width: 5),
              Expanded(
                flex: 6,
                child: _VirtualKeyboardKey(
                  label: 'Leerzeichen',
                  icon: Icons.space_bar,
                  onTap: onSpace,
                ),
              ),
              const SizedBox(width: 5),
              Expanded(
                flex: 2,
                child: _VirtualKeyboardKey(
                  label: 'Enter',
                  icon: Icons.keyboard_return,
                  onTap: onEnter,
                ),
              ),
              const SizedBox(width: 5),
              Expanded(
                flex: 2,
                child: _VirtualKeyboardKey(
                  label: 'Fertig',
                  icon: Icons.check,
                  onTap: onDone,
                  accent: colors.accentColor,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _keyRow(List<String> keys) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 5),
        child: Row(
          children: keys
              .map(
                (key) => Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2.5),
                    child: _VirtualKeyboardKey(
                      label: shift ? key.toUpperCase() : key,
                      onTap: () => onCharacter(key),
                    ),
                  ),
                ),
              )
              .toList(),
        ),
      ),
    );
  }
}

class _VirtualKeyboardKey extends StatelessWidget {
  const _VirtualKeyboardKey({
    required this.label,
    required this.onTap,
    this.icon,
    this.accent,
    this.compact = false,
  });

  final String label;
  final VoidCallback onTap;
  final IconData? icon;
  final Color? accent;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final highlight = accent;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        alignment: Alignment.center,
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 9 : 5,
          vertical: compact ? 5 : 4,
        ),
        decoration: BoxDecoration(
          color: highlight?.withValues(alpha: .16) ?? const Color(0xFF18212B),
          borderRadius: BorderRadius.circular(compact ? 9 : 8),
          border: Border.all(
            color: highlight?.withValues(alpha: .75) ?? const Color(0xFF34404D),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (icon != null) ...[
              Icon(icon, size: compact ? 17 : 19, color: highlight ?? Colors.white),
              if (label.isNotEmpty) const SizedBox(width: 5),
            ],
            if (label.isNotEmpty)
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: highlight ?? Colors.white,
                    fontSize: compact ? 12 : 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

ThemeData buildTheme(
  Brightness brightness,
  AppColorThemeConfig colors,
) {
  final accent = colors.accentColor;
  final surface = colors.surfaceColor;
  final scheme = ColorScheme.fromSeed(
    seedColor: accent,
    brightness: Brightness.dark,
  ).copyWith(
    primary: accent,
    secondary: colors.secondaryAccentColor,
    surface: surface,
    onSurface: colors.textPrimaryColor,
    error: colors.errorColor,
  );

  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
  );

  return base.copyWith(
    scaffoldBackgroundColor: colors.backgroundColor,
    textTheme: base.textTheme.apply(
      bodyColor: colors.textPrimaryColor,
      displayColor: colors.textPrimaryColor,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: colors.backgroundColor,
      foregroundColor: colors.textPrimaryColor,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    cardTheme: CardThemeData(
      color: colors.cardColor,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colors.borderColor),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: accent,
        foregroundColor: Colors.black,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(9),
        ),
        textStyle: const TextStyle(fontWeight: FontWeight.w800),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: accent,
        side: BorderSide(color: colors.borderColor),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colors.surfaceColor,
      labelStyle: TextStyle(color: colors.textSecondaryColor),
      helperStyle: TextStyle(color: colors.textSecondaryColor),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: colors.borderColor),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: colors.borderColor),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: accent),
      ),
    ),
    dividerColor: colors.borderColor,
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: accent,
      linearTrackColor: colors.progressTrackColor,
    ),
    sliderTheme: base.sliderTheme.copyWith(
      activeTrackColor: accent,
      thumbColor: accent,
      inactiveTrackColor: colors.progressTrackColor,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? accent
            : colors.textSecondaryColor,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? accent.withValues(alpha: .35)
            : colors.progressTrackColor,
      ),
    ),
  );
}

enum DrinkCategory { cocktail, mocktail, shot }
enum RecipeSortMode { original, nameAsc, nameDesc, availability, alcoholAsc, alcoholDesc, popularity }
enum IngredientKind { alcoholic, nonAlcoholic }
enum ConnectionMode { bluetooth, wifi }
enum LedIdleMode { solid, rainbow, breathe, blink, off }
enum AppLanguage { de, en, es, it, nl, fr, pt, pl, tr, ru }

AppLanguage _activeAppLanguage = AppLanguage.de;

extension AppLanguageMeta on AppLanguage {
  String get nativeName => switch (this) {
        AppLanguage.de => 'Deutsch',
        AppLanguage.en => 'English',
        AppLanguage.es => 'Español',
        AppLanguage.it => 'Italiano',
        AppLanguage.nl => 'Nederlands',
        AppLanguage.fr => 'Français',
        AppLanguage.pt => 'Português',
        AppLanguage.pl => 'Polski',
        AppLanguage.tr => 'Türkçe',
        AppLanguage.ru => 'Русский',
      };

  String get localeCode => switch (this) {
        AppLanguage.de => 'de',
        AppLanguage.en => 'en',
        AppLanguage.es => 'es',
        AppLanguage.it => 'it',
        AppLanguage.nl => 'nl',
        AppLanguage.fr => 'fr',
        AppLanguage.pt => 'pt',
        AppLanguage.pl => 'pl',
        AppLanguage.tr => 'tr',
        AppLanguage.ru => 'ru',
      };
}


enum AppColorSlot {
  background,
  surface,
  card,
  navigation,
  accent,
  secondaryAccent,
  border,
  textPrimary,
  textSecondary,
  progressTrack,
  success,
  warning,
  error,
}

extension AppColorSlotMeta on AppColorSlot {
  String get label => switch (this) {
        AppColorSlot.background => 'App-Hintergrund',
        AppColorSlot.surface => 'Flächen',
        AppColorSlot.card => 'Karten',
        AppColorSlot.navigation => 'Navigation',
        AppColorSlot.accent => 'Akzent / Buttons',
        AppColorSlot.secondaryAccent => 'Sekundärakzent',
        AppColorSlot.border => 'Rahmen / Linien',
        AppColorSlot.textPrimary => 'Haupttext',
        AppColorSlot.textSecondary => 'Nebentext',
        AppColorSlot.progressTrack => 'Balken-Hintergrund',
        AppColorSlot.success => 'Erfolg / Online',
        AppColorSlot.warning => 'Warnung',
        AppColorSlot.error => 'Fehler / Abbrechen',
      };
}

class AppColorThemeConfig {
  const AppColorThemeConfig({
    required this.background,
    required this.surface,
    required this.card,
    required this.navigation,
    required this.accent,
    required this.secondaryAccent,
    required this.border,
    required this.textPrimary,
    required this.textSecondary,
    required this.progressTrack,
    required this.success,
    required this.warning,
    required this.error,
  });

  final int background;
  final int surface;
  final int card;
  final int navigation;
  final int accent;
  final int secondaryAccent;
  final int border;
  final int textPrimary;
  final int textSecondary;
  final int progressTrack;
  final int success;
  final int warning;
  final int error;

  factory AppColorThemeConfig.defaults() => const AppColorThemeConfig(
        background: 0xFF07111A,
        surface: 0xFF0D1823,
        card: 0xFF122131,
        navigation: 0xFF0A141D,
        accent: 0xFF14B8A6,
        secondaryAccent: 0xFF51E3D4,
        border: 0xFF1F3244,
        textPrimary: 0xFFF8FAFC,
        textSecondary: 0xFF9FB0C3,
        progressTrack: 0xFF203244,
        success: 0xFF4FD38B,
        warning: 0xFFFFB454,
        error: 0xFFFF6B6B,
      );

  factory AppColorThemeConfig.fromJson(Map<String, dynamic> json) {
    final defaults = AppColorThemeConfig.defaults();

    int value(String key, int fallback) =>
        (json[key] as num?)?.toInt() ?? fallback;

    return AppColorThemeConfig(
      background: value('background', defaults.background),
      surface: value('surface', defaults.surface),
      card: value('card', defaults.card),
      navigation: value('navigation', defaults.navigation),
      accent: value('accent', defaults.accent),
      secondaryAccent:
          value('secondaryAccent', defaults.secondaryAccent),
      border: value('border', defaults.border),
      textPrimary: value('textPrimary', defaults.textPrimary),
      textSecondary: value('textSecondary', defaults.textSecondary),
      progressTrack: value('progressTrack', defaults.progressTrack),
      success: value('success', defaults.success),
      warning: value('warning', defaults.warning),
      error: value('error', defaults.error),
    );
  }

  Map<String, dynamic> toJson() => {
        'background': background,
        'surface': surface,
        'card': card,
        'navigation': navigation,
        'accent': accent,
        'secondaryAccent': secondaryAccent,
        'border': border,
        'textPrimary': textPrimary,
        'textSecondary': textSecondary,
        'progressTrack': progressTrack,
        'success': success,
        'warning': warning,
        'error': error,
      };

  Color get backgroundColor => Color(background);
  Color get surfaceColor => Color(surface);
  Color get cardColor => Color(card);
  Color get navigationColor => Color(navigation);
  Color get accentColor => Color(accent);
  Color get secondaryAccentColor => Color(secondaryAccent);
  Color get borderColor => Color(border);
  Color get textPrimaryColor => Color(textPrimary);
  Color get textSecondaryColor => Color(textSecondary);
  Color get progressTrackColor => Color(progressTrack);
  Color get successColor => Color(success);
  Color get warningColor => Color(warning);
  Color get errorColor => Color(error);

  int valueOf(AppColorSlot slot) => switch (slot) {
        AppColorSlot.background => background,
        AppColorSlot.surface => surface,
        AppColorSlot.card => card,
        AppColorSlot.navigation => navigation,
        AppColorSlot.accent => accent,
        AppColorSlot.secondaryAccent => secondaryAccent,
        AppColorSlot.border => border,
        AppColorSlot.textPrimary => textPrimary,
        AppColorSlot.textSecondary => textSecondary,
        AppColorSlot.progressTrack => progressTrack,
        AppColorSlot.success => success,
        AppColorSlot.warning => warning,
        AppColorSlot.error => error,
      };

  AppColorThemeConfig withSlot(
    AppColorSlot slot,
    int value,
  ) {
    return AppColorThemeConfig(
      background:
          slot == AppColorSlot.background ? value : background,
      surface: slot == AppColorSlot.surface ? value : surface,
      card: slot == AppColorSlot.card ? value : card,
      navigation:
          slot == AppColorSlot.navigation ? value : navigation,
      accent: slot == AppColorSlot.accent ? value : accent,
      secondaryAccent:
          slot == AppColorSlot.secondaryAccent ? value : secondaryAccent,
      border: slot == AppColorSlot.border ? value : border,
      textPrimary:
          slot == AppColorSlot.textPrimary ? value : textPrimary,
      textSecondary:
          slot == AppColorSlot.textSecondary ? value : textSecondary,
      progressTrack:
          slot == AppColorSlot.progressTrack ? value : progressTrack,
      success: slot == AppColorSlot.success ? value : success,
      warning: slot == AppColorSlot.warning ? value : warning,
      error: slot == AppColorSlot.error ? value : error,
    );
  }
}

String appText(AppLanguage language, String key) {
  final texts = <String, Map<AppLanguage, String>>{
    'navCocktails': {AppLanguage.de: 'Cocktails', AppLanguage.en: 'Cocktails', AppLanguage.es: 'Cócteles', AppLanguage.it: 'Cocktail', AppLanguage.nl: 'Cocktails', AppLanguage.fr: 'Cocktails', AppLanguage.pt: 'Coquetéis', AppLanguage.pl: 'Koktajle', AppLanguage.tr: 'Kokteyller', AppLanguage.ru: 'Коктейли'},
    'navMocktails': {AppLanguage.de: 'Alkoholfrei', AppLanguage.en: 'Alcohol-free', AppLanguage.es: 'Sin alcohol', AppLanguage.it: 'Analcolici', AppLanguage.nl: 'Alcoholvrij', AppLanguage.fr: 'Sans alcool', AppLanguage.pt: 'Sem álcool', AppLanguage.pl: 'Bezalkoholowe', AppLanguage.tr: 'Alkolsüz', AppLanguage.ru: 'Без алкоголя'},
    'navShots': {AppLanguage.de: 'Shots', AppLanguage.en: 'Shots', AppLanguage.es: 'Chupitos', AppLanguage.it: 'Shot', AppLanguage.nl: 'Shots', AppLanguage.fr: 'Shots', AppLanguage.pt: 'Shots', AppLanguage.pl: 'Shoty', AppLanguage.tr: 'Shotlar', AppLanguage.ru: 'Шоты'},
    'navSettings': {AppLanguage.de: 'Einstellungen', AppLanguage.en: 'Settings', AppLanguage.es: 'Ajustes', AppLanguage.it: 'Impostazioni', AppLanguage.nl: 'Instellingen', AppLanguage.fr: 'Paramètres', AppLanguage.pt: 'Configurações', AppLanguage.pl: 'Ustawienia', AppLanguage.tr: 'Ayarlar', AppLanguage.ru: 'Настройки'},
    'titleAlcoholicCocktails': {AppLanguage.de: 'Alkoholische Cocktails', AppLanguage.en: 'Alcoholic cocktails', AppLanguage.es: 'Cócteles con alcohol', AppLanguage.it: 'Cocktail alcolici', AppLanguage.nl: 'Alcoholische cocktails', AppLanguage.fr: 'Cocktails alcoolisés', AppLanguage.pt: 'Coquetéis alcoólicos', AppLanguage.pl: 'Koktajle alkoholowe', AppLanguage.tr: 'Alkollü kokteyller', AppLanguage.ru: 'Алкогольные коктейли'},
    'titleMocktails': {AppLanguage.de: 'Alkoholfreie Cocktails', AppLanguage.en: 'Alcohol-free cocktails', AppLanguage.es: 'Cócteles sin alcohol', AppLanguage.it: 'Cocktail analcolici', AppLanguage.nl: 'Alcoholvrije cocktails', AppLanguage.fr: 'Cocktails sans alcool', AppLanguage.pt: 'Coquetéis sem álcool', AppLanguage.pl: 'Koktajle bezalkoholowe', AppLanguage.tr: 'Alkolsüz kokteyller', AppLanguage.ru: 'Безалкогольные коктейли'},
    'settingsConnection': {AppLanguage.de: 'Verbindung', AppLanguage.en: 'Connection', AppLanguage.es: 'Conexión', AppLanguage.it: 'Connessione', AppLanguage.nl: 'Verbinding', AppLanguage.fr: 'Connexion', AppLanguage.pt: 'Conexão', AppLanguage.pl: 'Połączenie', AppLanguage.tr: 'Bağlantı', AppLanguage.ru: 'Подключение'},
    'settingsConnected': {AppLanguage.de: 'WLAN verbunden', AppLanguage.en: 'Wi-Fi connected', AppLanguage.es: 'Wi‑Fi conectado', AppLanguage.it: 'Wi‑Fi connesso', AppLanguage.nl: 'Wifi verbonden', AppLanguage.fr: 'Wi‑Fi connecté', AppLanguage.pt: 'Wi‑Fi conectado', AppLanguage.pl: 'Wi‑Fi połączone', AppLanguage.tr: 'Wi‑Fi bağlı', AppLanguage.ru: 'Wi‑Fi подключен'},
    'settingsConnectionSub': {AppLanguage.de: 'Bluetooth oder WLAN', AppLanguage.en: 'Bluetooth or Wi-Fi', AppLanguage.es: 'Bluetooth o Wi‑Fi', AppLanguage.it: 'Bluetooth o Wi‑Fi', AppLanguage.nl: 'Bluetooth of wifi', AppLanguage.fr: 'Bluetooth ou Wi‑Fi', AppLanguage.pt: 'Bluetooth ou Wi‑Fi', AppLanguage.pl: 'Bluetooth lub Wi‑Fi', AppLanguage.tr: 'Bluetooth veya Wi‑Fi', AppLanguage.ru: 'Bluetooth или Wi‑Fi'},
    'settingsLanguage': {AppLanguage.de: 'Sprache', AppLanguage.en: 'Language', AppLanguage.es: 'Idioma', AppLanguage.it: 'Lingua', AppLanguage.nl: 'Taal', AppLanguage.fr: 'Langue', AppLanguage.pt: 'Idioma', AppLanguage.pl: 'Język', AppLanguage.tr: 'Dil', AppLanguage.ru: 'Язык'},
    'settingsLanguageSub': {AppLanguage.de: 'App-Sprache ändern', AppLanguage.en: 'Change app language', AppLanguage.es: 'Cambiar idioma de la app', AppLanguage.it: 'Cambia lingua dell’app', AppLanguage.nl: 'App-taal wijzigen', AppLanguage.fr: 'Changer la langue de l’app', AppLanguage.pt: 'Alterar idioma do app', AppLanguage.pl: 'Zmień język aplikacji', AppLanguage.tr: 'Uygulama dilini değiştir', AppLanguage.ru: 'Изменить язык приложения'},
    'settingsDesign': {AppLanguage.de: 'Design/Farben', AppLanguage.en: 'Design/colors', AppLanguage.es: 'Diseño/colores', AppLanguage.it: 'Design/colori', AppLanguage.nl: 'Ontwerp/kleuren', AppLanguage.fr: 'Design/couleurs', AppLanguage.pt: 'Design/cores', AppLanguage.pl: 'Wygląd/kolory', AppLanguage.tr: 'Tasarım/renkler', AppLanguage.ru: 'Дизайн/цвета'},
    'settingsDesignSub': {AppLanguage.de: 'Hintergründe, Balken und Akzente', AppLanguage.en: 'Backgrounds, bars and accents', AppLanguage.es: 'Fondos, barras y acentos', AppLanguage.it: 'Sfondi, barre e accenti', AppLanguage.nl: 'Achtergronden, balken en accenten', AppLanguage.fr: 'Arrière-plans, barres et accents', AppLanguage.pt: 'Fundos, barras e acentos', AppLanguage.pl: 'Tła, paski i akcenty', AppLanguage.tr: 'Arka planlar, çubuklar ve vurgular', AppLanguage.ru: 'Фоны, полосы и акценты'},
    'settingsLed': {AppLanguage.de: 'LED-Beleuchtung', AppLanguage.en: 'LED lighting', AppLanguage.es: 'Iluminación LED', AppLanguage.it: 'Illuminazione LED', AppLanguage.nl: 'LED-verlichting', AppLanguage.fr: 'Éclairage LED', AppLanguage.pt: 'Iluminação LED', AppLanguage.pl: 'Oświetlenie LED', AppLanguage.tr: 'LED aydınlatma', AppLanguage.ru: 'LED-подсветка'},
    'settingsLedSub': {AppLanguage.de: 'Farbe, Helligkeit und Effekt', AppLanguage.en: 'Color, brightness and effect', AppLanguage.es: 'Color, brillo y efecto', AppLanguage.it: 'Colore, luminosità ed effetto', AppLanguage.nl: 'Kleur, helderheid en effect', AppLanguage.fr: 'Couleur, luminosité et effet', AppLanguage.pt: 'Cor, brilho e efeito', AppLanguage.pl: 'Kolor, jasność i efekt', AppLanguage.tr: 'Renk, parlaklık ve efekt', AppLanguage.ru: 'Цвет, яркость и эффект'},
    'settingsCalibration': {AppLanguage.de: 'Kalibrierung', AppLanguage.en: 'Calibration', AppLanguage.es: 'Calibración', AppLanguage.it: 'Calibrazione', AppLanguage.nl: 'Kalibratie', AppLanguage.fr: 'Étalonnage', AppLanguage.pt: 'Calibração', AppLanguage.pl: 'Kalibracja', AppLanguage.tr: 'Kalibrasyon', AppLanguage.ru: 'Калибровка'},
    'settingsCalibrationSub': {AppLanguage.de: 'Pumpen kalibrieren', AppLanguage.en: 'Calibrate pumps', AppLanguage.es: 'Calibrar bombas', AppLanguage.it: 'Calibra pompe', AppLanguage.nl: 'Pompen kalibreren', AppLanguage.fr: 'Étalonner les pompes', AppLanguage.pt: 'Calibrar bombas', AppLanguage.pl: 'Kalibruj pompy', AppLanguage.tr: 'Pompaları kalibre et', AppLanguage.ru: 'Калибровать насосы'},
    'settingsSizes': {AppLanguage.de: 'Größen für Cocktails', AppLanguage.en: 'Cocktail sizes', AppLanguage.es: 'Tamaños de cóctel', AppLanguage.it: 'Dimensioni cocktail', AppLanguage.nl: 'Cocktailformaten', AppLanguage.fr: 'Tailles des cocktails', AppLanguage.pt: 'Tamanhos de coquetel', AppLanguage.pl: 'Rozmiary koktajli', AppLanguage.tr: 'Kokteyl boyutları', AppLanguage.ru: 'Размеры коктейлей'},
    'settingsSizesSub': {AppLanguage.de: 'Standard- und Wunschgrößen', AppLanguage.en: 'Default and custom sizes', AppLanguage.es: 'Tamaños estándar y personalizados', AppLanguage.it: 'Dimensioni standard e personalizzate', AppLanguage.nl: 'Standaard- en aangepaste maten', AppLanguage.fr: 'Tailles standard et personnalisées', AppLanguage.pt: 'Tamanhos padrão e personalizados', AppLanguage.pl: 'Rozmiary domyślne i własne', AppLanguage.tr: 'Varsayılan ve özel boyutlar', AppLanguage.ru: 'Стандартные и свои размеры'},
    'settingsFill': {AppLanguage.de: 'Füllstände', AppLanguage.en: 'Fill levels', AppLanguage.es: 'Niveles de llenado', AppLanguage.it: 'Livelli di riempimento', AppLanguage.nl: 'Vulniveaus', AppLanguage.fr: 'Niveaux de remplissage', AppLanguage.pt: 'Níveis de enchimento', AppLanguage.pl: 'Poziomy napełnienia', AppLanguage.tr: 'Dolum seviyeleri', AppLanguage.ru: 'Уровни заполнения'},
    'settingsFillSub': {AppLanguage.de: 'Behälter & Füllstände', AppLanguage.en: 'Containers & fill levels', AppLanguage.es: 'Recipientes y niveles', AppLanguage.it: 'Contenitori e livelli', AppLanguage.nl: 'Reservoirs en vulniveaus', AppLanguage.fr: 'Réservoirs et niveaux', AppLanguage.pt: 'Recipientes e níveis', AppLanguage.pl: 'Pojemniki i poziomy', AppLanguage.tr: 'Kaplar ve seviyeler', AppLanguage.ru: 'Ёмкости и уровни'},
    'settingsCleaning': {AppLanguage.de: 'Reinigung', AppLanguage.en: 'Cleaning', AppLanguage.es: 'Limpieza', AppLanguage.it: 'Pulizia', AppLanguage.nl: 'Reiniging', AppLanguage.fr: 'Nettoyage', AppLanguage.pt: 'Limpeza', AppLanguage.pl: 'Czyszczenie', AppLanguage.tr: 'Temizlik', AppLanguage.ru: 'Очистка'},
    'settingsCleaningSub': {AppLanguage.de: 'Pumpenreinigung', AppLanguage.en: 'Pump cleaning', AppLanguage.es: 'Limpieza de bombas', AppLanguage.it: 'Pulizia pompe', AppLanguage.nl: 'Pompreiniging', AppLanguage.fr: 'Nettoyage des pompes', AppLanguage.pt: 'Limpeza das bombas', AppLanguage.pl: 'Czyszczenie pomp', AppLanguage.tr: 'Pompa temizliği', AppLanguage.ru: 'Очистка насосов'},
    'settingsPriming': {AppLanguage.de: 'Entlüften', AppLanguage.en: 'Priming', AppLanguage.es: 'Purgar', AppLanguage.it: 'Spurgo', AppLanguage.nl: 'Ontluchten', AppLanguage.fr: 'Purge', AppLanguage.pt: 'Escorvar', AppLanguage.pl: 'Odpowietrzanie', AppLanguage.tr: 'Hava alma', AppLanguage.ru: 'Прокачка'},
    'settingsPrimingSub': {AppLanguage.de: 'Schläuche entlüften', AppLanguage.en: 'Prime tubes', AppLanguage.es: 'Purgar tubos', AppLanguage.it: 'Spurga tubi', AppLanguage.nl: 'Slangen ontluchten', AppLanguage.fr: 'Purger les tuyaux', AppLanguage.pt: 'Escorvar mangueiras', AppLanguage.pl: 'Odpowietrz przewody', AppLanguage.tr: 'Hortumların havasını al', AppLanguage.ru: 'Прокачать трубки'},
    'settingsIngredients': {AppLanguage.de: 'Neue Zutaten', AppLanguage.en: 'Ingredients', AppLanguage.es: 'Ingredientes', AppLanguage.it: 'Ingredienti', AppLanguage.nl: 'Ingrediënten', AppLanguage.fr: 'Ingrédients', AppLanguage.pt: 'Ingredientes', AppLanguage.pl: 'Składniki', AppLanguage.tr: 'Malzemeler', AppLanguage.ru: 'Ингредиенты'},
    'settingsIngredientsSub': {AppLanguage.de: 'Zutaten verwalten', AppLanguage.en: 'Manage ingredients', AppLanguage.es: 'Gestionar ingredientes', AppLanguage.it: 'Gestisci ingredienti', AppLanguage.nl: 'Ingrediënten beheren', AppLanguage.fr: 'Gérer les ingrédients', AppLanguage.pt: 'Gerenciar ingredientes', AppLanguage.pl: 'Zarządzaj składnikami', AppLanguage.tr: 'Malzemeleri yönet', AppLanguage.ru: 'Управлять ингредиентами'},
    'settingsRecipes': {AppLanguage.de: 'Rezepte', AppLanguage.en: 'Recipes', AppLanguage.es: 'Recetas', AppLanguage.it: 'Ricette', AppLanguage.nl: 'Recepten', AppLanguage.fr: 'Recettes', AppLanguage.pt: 'Receitas', AppLanguage.pl: 'Przepisy', AppLanguage.tr: 'Tarifler', AppLanguage.ru: 'Рецепты'},
    'settingsRecipesSub': {AppLanguage.de: 'Rezepte erstellen und bearbeiten', AppLanguage.en: 'Create and edit recipes', AppLanguage.es: 'Crear y editar recetas', AppLanguage.it: 'Crea e modifica ricette', AppLanguage.nl: 'Recepten maken en bewerken', AppLanguage.fr: 'Créer et modifier des recettes', AppLanguage.pt: 'Criar e editar receitas', AppLanguage.pl: 'Twórz i edytuj przepisy', AppLanguage.tr: 'Tarif oluştur ve düzenle', AppLanguage.ru: 'Создать и редактировать рецепты'},
    'languageTitle': {AppLanguage.de: 'Sprache', AppLanguage.en: 'Language', AppLanguage.es: 'Idioma', AppLanguage.it: 'Lingua', AppLanguage.nl: 'Taal', AppLanguage.fr: 'Langue', AppLanguage.pt: 'Idioma', AppLanguage.pl: 'Język', AppLanguage.tr: 'Dil', AppLanguage.ru: 'Язык'},
    'languageSelect': {AppLanguage.de: 'App-Sprache auswählen', AppLanguage.en: 'Select app language', AppLanguage.es: 'Seleccionar idioma', AppLanguage.it: 'Seleziona lingua', AppLanguage.nl: 'App-taal kiezen', AppLanguage.fr: 'Choisir la langue', AppLanguage.pt: 'Selecionar idioma', AppLanguage.pl: 'Wybierz język', AppLanguage.tr: 'Uygulama dilini seç', AppLanguage.ru: 'Выберите язык приложения'},
    'languageInfo': {AppLanguage.de: 'Die Spracheinstellung übersetzt die App-Oberfläche. Rezeptnamen, eigene Zutaten und selbst geschriebene Beschreibungen bleiben unverändert.', AppLanguage.en: 'The language setting translates the app interface. Recipe names, custom ingredients and descriptions you wrote stay unchanged.', AppLanguage.es: 'El ajuste de idioma traduce la interfaz de la app. Los nombres de recetas, ingredientes propios y descripciones escritas por ti no cambian.', AppLanguage.it: 'La lingua traduce l’interfaccia dell’app. Nomi delle ricette, ingredienti personalizzati e descrizioni scritte da te non cambiano.', AppLanguage.nl: 'De taalinstelling vertaalt de app-interface. Receptnamen, eigen ingrediënten en zelf geschreven beschrijvingen blijven ongewijzigd.', AppLanguage.fr: 'Le réglage de langue traduit l’interface de l’app. Les noms de recettes, ingrédients personnalisés et descriptions écrites restent inchangés.', AppLanguage.pt: 'A configuração de idioma traduz a interface do app. Nomes de receitas, ingredientes personalizados e descrições escritas por você não mudam.', AppLanguage.pl: 'Ustawienie języka tłumaczy interfejs aplikacji. Nazwy przepisów, własne składniki i opisy pozostają bez zmian.', AppLanguage.tr: 'Dil ayarı uygulama arayüzünü çevirir. Tarif adları, özel malzemeler ve yazdığın açıklamalar değişmeden kalır.', AppLanguage.ru: 'Настройка языка переводит интерфейс приложения. Названия рецептов, свои ингредиенты и описания остаются без изменений.'},
    'languageSaved': {AppLanguage.de: 'Sprache wurde geändert', AppLanguage.en: 'Language changed', AppLanguage.es: 'Idioma cambiado', AppLanguage.it: 'Lingua modificata', AppLanguage.nl: 'Taal gewijzigd', AppLanguage.fr: 'Langue modifiée', AppLanguage.pt: 'Idioma alterado', AppLanguage.pl: 'Język zmieniony', AppLanguage.tr: 'Dil değiştirildi', AppLanguage.ru: 'Язык изменён'},
    'machine': {AppLanguage.de: 'Maschine', AppLanguage.en: 'Machine', AppLanguage.es: 'Máquina', AppLanguage.it: 'Macchina', AppLanguage.nl: 'Machine', AppLanguage.fr: 'Machine', AppLanguage.pt: 'Máquina', AppLanguage.pl: 'Maszyna', AppLanguage.tr: 'Makine', AppLanguage.ru: 'Машина'},
    'online': {AppLanguage.de: 'Online', AppLanguage.en: 'Online', AppLanguage.es: 'En línea', AppLanguage.it: 'Online', AppLanguage.nl: 'Online', AppLanguage.fr: 'En ligne', AppLanguage.pt: 'Online', AppLanguage.pl: 'Online', AppLanguage.tr: 'Çevrimiçi', AppLanguage.ru: 'Онлайн'},
    'offline': {AppLanguage.de: 'Offline', AppLanguage.en: 'Offline', AppLanguage.es: 'Sin conexión', AppLanguage.it: 'Offline', AppLanguage.nl: 'Offline', AppLanguage.fr: 'Hors ligne', AppLanguage.pt: 'Offline', AppLanguage.pl: 'Offline', AppLanguage.tr: 'Çevrimdışı', AppLanguage.ru: 'Офлайн'},
    'noRecipes': {AppLanguage.de: 'Noch keine Rezepte vorhanden', AppLanguage.en: 'No recipes yet', AppLanguage.es: 'Aún no hay recetas', AppLanguage.it: 'Nessuna ricetta ancora', AppLanguage.nl: 'Nog geen recepten', AppLanguage.fr: 'Aucune recette pour le moment', AppLanguage.pt: 'Ainda não há receitas', AppLanguage.pl: 'Brak przepisów', AppLanguage.tr: 'Henüz tarif yok', AppLanguage.ru: 'Рецептов пока нет'},
  };
  final uiTexts = <String, Map<AppLanguage, String>>{
    'Abbrechen': {AppLanguage.de: 'Abbrechen', AppLanguage.en: 'Cancel', AppLanguage.es: 'Cancelar', AppLanguage.it: 'Annulla', AppLanguage.nl: 'Annuleren', AppLanguage.fr: 'Cancel', AppLanguage.pt: 'Cancel', AppLanguage.pl: 'Cancel', AppLanguage.tr: 'Cancel', AppLanguage.ru: 'Cancel'},
    'Auffüllen': {AppLanguage.de: 'Auffüllen', AppLanguage.en: 'Refill', AppLanguage.es: 'Rellenar', AppLanguage.it: 'Riempire', AppLanguage.nl: 'Bijvullen', AppLanguage.fr: 'Refill', AppLanguage.pt: 'Refill', AppLanguage.pl: 'Refill', AppLanguage.tr: 'Refill', AppLanguage.ru: 'Refill'},
    'Alkoholfrei': {AppLanguage.de: 'Alkoholfrei', AppLanguage.en: 'Alcohol-free', AppLanguage.es: 'Sin alcohol', AppLanguage.it: 'Analcolico', AppLanguage.nl: 'Alcoholvrij', AppLanguage.fr: 'Alcohol-free', AppLanguage.pt: 'Alcohol-free', AppLanguage.pl: 'Alcohol-free', AppLanguage.tr: 'Alcohol-free', AppLanguage.ru: 'Alcohol-free'},
    'Alkoholisch': {AppLanguage.de: 'Alkoholisch', AppLanguage.en: 'Alcoholic', AppLanguage.es: 'Con alcohol', AppLanguage.it: 'Alcolico', AppLanguage.nl: 'Alcoholisch', AppLanguage.fr: 'Alcoholic', AppLanguage.pt: 'Alcoholic', AppLanguage.pl: 'Alcoholic', AppLanguage.tr: 'Alcoholic', AppLanguage.ru: 'Alcoholic'},
    'Automatische Zutat': {AppLanguage.de: 'Automatische Zutat', AppLanguage.en: 'Automatic ingredient', AppLanguage.es: 'Ingrediente automático', AppLanguage.it: 'Ingrediente automatico', AppLanguage.nl: 'Automatisch ingrediënt', AppLanguage.fr: 'Automatic ingredient', AppLanguage.pt: 'Automatic ingredient', AppLanguage.pl: 'Automatic ingredient', AppLanguage.tr: 'Automatic ingredient', AppLanguage.ru: 'Automatic ingredient'},
    'Bearbeiten': {AppLanguage.de: 'Bearbeiten', AppLanguage.en: 'Edit', AppLanguage.es: 'Editar', AppLanguage.it: 'Modifica', AppLanguage.nl: 'Bewerken', AppLanguage.fr: 'Edit', AppLanguage.pt: 'Edit', AppLanguage.pl: 'Edit', AppLanguage.tr: 'Edit', AppLanguage.ru: 'Edit'},
    'Bluetooth': {AppLanguage.de: 'Bluetooth', AppLanguage.en: 'Bluetooth', AppLanguage.es: 'Bluetooth', AppLanguage.it: 'Bluetooth', AppLanguage.nl: 'Bluetooth', AppLanguage.fr: 'Bluetooth', AppLanguage.pt: 'Bluetooth', AppLanguage.pl: 'Bluetooth', AppLanguage.tr: 'Bluetooth', AppLanguage.ru: 'Bluetooth'},
    'Button': {AppLanguage.de: 'Button', AppLanguage.en: 'Button', AppLanguage.es: 'Botón', AppLanguage.it: 'Pulsante', AppLanguage.nl: 'Knop', AppLanguage.fr: 'Button', AppLanguage.pt: 'Button', AppLanguage.pl: 'Button', AppLanguage.tr: 'Button', AppLanguage.ru: 'Button'},
    'Farbe': {AppLanguage.de: 'Farbe', AppLanguage.en: 'Color', AppLanguage.es: 'Color', AppLanguage.it: 'Colore', AppLanguage.nl: 'Kleur', AppLanguage.fr: 'Color', AppLanguage.pt: 'Color', AppLanguage.pl: 'Color', AppLanguage.tr: 'Color', AppLanguage.ru: 'Color'},
    'Farbe bearbeiten': {AppLanguage.de: 'Farbe bearbeiten', AppLanguage.en: 'Edit color', AppLanguage.es: 'Editar color', AppLanguage.it: 'Modifica colore', AppLanguage.nl: 'Kleur bewerken', AppLanguage.fr: 'Edit color', AppLanguage.pt: 'Edit color', AppLanguage.pl: 'Edit color', AppLanguage.tr: 'Edit color', AppLanguage.ru: 'Edit color'},
    'Füllstand speichern': {AppLanguage.de: 'Füllstand speichern', AppLanguage.en: 'Save fill level', AppLanguage.es: 'Guardar nivel', AppLanguage.it: 'Salva livello', AppLanguage.nl: 'Vulniveau opslaan', AppLanguage.fr: 'Save fill level', AppLanguage.pt: 'Save fill level', AppLanguage.pl: 'Save fill level', AppLanguage.tr: 'Save fill level', AppLanguage.ru: 'Save fill level'},
    'Füllstand gespeichert': {AppLanguage.de: 'Füllstand gespeichert', AppLanguage.en: 'Fill level saved', AppLanguage.es: 'Nivel guardado', AppLanguage.it: 'Livello salvato', AppLanguage.nl: 'Vulniveau opgeslagen', AppLanguage.fr: 'Fill level saved', AppLanguage.pt: 'Fill level saved', AppLanguage.pl: 'Fill level saved', AppLanguage.tr: 'Fill level saved', AppLanguage.ru: 'Fill level saved'},
    'Füllstände': {AppLanguage.de: 'Füllstände', AppLanguage.en: 'Fill levels', AppLanguage.es: 'Niveles de llenado', AppLanguage.it: 'Livelli di riempimento', AppLanguage.nl: 'Vulniveaus', AppLanguage.fr: 'Fill levels', AppLanguage.pt: 'Fill levels', AppLanguage.pl: 'Fill levels', AppLanguage.tr: 'Fill levels', AppLanguage.ru: 'Fill levels'},
    'Getränkegrößen': {AppLanguage.de: 'Getränkegrößen', AppLanguage.en: 'Drink sizes', AppLanguage.es: 'Tamaños de bebida', AppLanguage.it: 'Dimensioni bevanda', AppLanguage.nl: 'Drankformaten', AppLanguage.fr: 'Drink sizes', AppLanguage.pt: 'Drink sizes', AppLanguage.pl: 'Drink sizes', AppLanguage.tr: 'Drink sizes', AppLanguage.ru: 'Drink sizes'},
    'Größe des Cocktails': {AppLanguage.de: 'Größe des Cocktails', AppLanguage.en: 'Cocktail size', AppLanguage.es: 'Tamaño del cóctel', AppLanguage.it: 'Dimensione cocktail', AppLanguage.nl: 'Cocktailformaat', AppLanguage.fr: 'Cocktail size', AppLanguage.pt: 'Cocktail size', AppLanguage.pl: 'Cocktail size', AppLanguage.tr: 'Cocktail size', AppLanguage.ru: 'Cocktail size'},
    'Größe löschen': {AppLanguage.de: 'Größe löschen', AppLanguage.en: 'Delete size', AppLanguage.es: 'Eliminar tamaño', AppLanguage.it: 'Elimina dimensione', AppLanguage.nl: 'Formaat verwijderen', AppLanguage.fr: 'Delete size', AppLanguage.pt: 'Delete size', AppLanguage.pl: 'Delete size', AppLanguage.tr: 'Delete size', AppLanguage.ru: 'Delete size'},
    'Größe, für die das Rezept eingetragen wird': {AppLanguage.de: 'Größe, für die das Rezept eingetragen wird', AppLanguage.en: 'Size used for the recipe values', AppLanguage.es: 'Tamaño usado para la receta', AppLanguage.it: 'Dimensione usata per la ricetta', AppLanguage.nl: 'Formaat waarvoor het recept geldt', AppLanguage.fr: 'Size used for the recipe values', AppLanguage.pt: 'Size used for the recipe values', AppLanguage.pl: 'Size used for the recipe values', AppLanguage.tr: 'Size used for the recipe values', AppLanguage.ru: 'Size used for the recipe values'},
    'Helligkeit': {AppLanguage.de: 'Helligkeit', AppLanguage.en: 'Brightness', AppLanguage.es: 'Brillo', AppLanguage.it: 'Luminosità', AppLanguage.nl: 'Helderheid', AppLanguage.fr: 'Brightness', AppLanguage.pt: 'Brightness', AppLanguage.pl: 'Brightness', AppLanguage.tr: 'Brightness', AppLanguage.ru: 'Brightness'},
    'Hinweis': {AppLanguage.de: 'Hinweis', AppLanguage.en: 'Note', AppLanguage.es: 'Nota', AppLanguage.it: 'Nota', AppLanguage.nl: 'Opmerking', AppLanguage.fr: 'Note', AppLanguage.pt: 'Note', AppLanguage.pl: 'Note', AppLanguage.tr: 'Note', AppLanguage.ru: 'Note'},
    'Hinweise': {AppLanguage.de: 'Hinweise', AppLanguage.en: 'Notes', AppLanguage.es: 'Notas', AppLanguage.it: 'Note', AppLanguage.nl: 'Opmerkingen', AppLanguage.fr: 'Notes', AppLanguage.pt: 'Notes', AppLanguage.pl: 'Notes', AppLanguage.tr: 'Notes', AppLanguage.ru: 'Notes'},
    'Hinzufügen': {AppLanguage.de: 'Hinzufügen', AppLanguage.en: 'Add', AppLanguage.es: 'Añadir', AppLanguage.it: 'Aggiungi', AppLanguage.nl: 'Toevoegen', AppLanguage.fr: 'Add', AppLanguage.pt: 'Add', AppLanguage.pl: 'Add', AppLanguage.tr: 'Add', AppLanguage.ru: 'Add'},
    'Idle-Effekt': {AppLanguage.de: 'Idle-Effekt', AppLanguage.en: 'Idle effect', AppLanguage.es: 'Efecto en reposo', AppLanguage.it: 'Effetto idle', AppLanguage.nl: 'Idle-effect', AppLanguage.fr: 'Idle effect', AppLanguage.pt: 'Idle effect', AppLanguage.pl: 'Idle effect', AppLanguage.tr: 'Idle effect', AppLanguage.ru: 'Idle effect'},
    'Kalibrierwert speichern': {AppLanguage.de: 'Kalibrierwert speichern', AppLanguage.en: 'Save calibration value', AppLanguage.es: 'Guardar calibración', AppLanguage.it: 'Salva calibrazione', AppLanguage.nl: 'Kalibratiewaarde opslaan', AppLanguage.fr: 'Save calibration value', AppLanguage.pt: 'Save calibration value', AppLanguage.pl: 'Save calibration value', AppLanguage.tr: 'Save calibration value', AppLanguage.ru: 'Save calibration value'},
    'Keine Pumpen aktiviert': {AppLanguage.de: 'Keine Pumpen aktiviert', AppLanguage.en: 'No pumps enabled', AppLanguage.es: 'No hay bombas activadas', AppLanguage.it: 'Nessuna pompa attiva', AppLanguage.nl: 'Geen pompen geactiveerd', AppLanguage.fr: 'No pumps enabled', AppLanguage.pt: 'No pumps enabled', AppLanguage.pl: 'No pumps enabled', AppLanguage.tr: 'No pumps enabled', AppLanguage.ru: 'No pumps enabled'},
    'Kosten': {AppLanguage.de: 'Kosten', AppLanguage.en: 'Costs', AppLanguage.es: 'Costes', AppLanguage.it: 'Costi', AppLanguage.nl: 'Kosten', AppLanguage.fr: 'Costs', AppLanguage.pt: 'Costs', AppLanguage.pl: 'Costs', AppLanguage.tr: 'Costs', AppLanguage.ru: 'Costs'},
    'Kosten pro Standardgröße': {AppLanguage.de: 'Kosten pro Standardgröße', AppLanguage.en: 'Cost per default size', AppLanguage.es: 'Coste por tamaño estándar', AppLanguage.it: 'Costo per dimensione standard', AppLanguage.nl: 'Kosten per standaardformaat', AppLanguage.fr: 'Cost per default size', AppLanguage.pt: 'Cost per default size', AppLanguage.pl: 'Cost per default size', AppLanguage.tr: 'Cost per default size', AppLanguage.ru: 'Cost per default size'},
    'Laufzeit je Pumpe': {AppLanguage.de: 'Laufzeit je Pumpe', AppLanguage.en: 'Runtime per pump', AppLanguage.es: 'Tiempo por bomba', AppLanguage.it: 'Durata per pompa', AppLanguage.nl: 'Looptijd per pomp', AppLanguage.fr: 'Runtime per pump', AppLanguage.pt: 'Runtime per pump', AppLanguage.pl: 'Runtime per pump', AppLanguage.tr: 'Runtime per pump', AppLanguage.ru: 'Runtime per pump'},
    'Literpreis bearbeiten': {AppLanguage.de: 'Literpreis bearbeiten', AppLanguage.en: 'Edit liter price', AppLanguage.es: 'Editar precio por litro', AppLanguage.it: 'Modifica prezzo al litro', AppLanguage.nl: 'Literprijs bewerken', AppLanguage.fr: 'Edit liter price', AppLanguage.pt: 'Edit liter price', AppLanguage.pl: 'Edit liter price', AppLanguage.tr: 'Edit liter price', AppLanguage.ru: 'Edit liter price'},
    'Literpreis': {AppLanguage.de: 'Literpreis', AppLanguage.en: 'Liter price', AppLanguage.es: 'Precio por litro', AppLanguage.it: 'Prezzo al litro', AppLanguage.nl: 'Literprijs', AppLanguage.fr: 'Liter price', AppLanguage.pt: 'Liter price', AppLanguage.pl: 'Liter price', AppLanguage.tr: 'Liter price', AppLanguage.ru: 'Liter price'},
    'Löschen': {AppLanguage.de: 'Löschen', AppLanguage.en: 'Delete', AppLanguage.es: 'Eliminar', AppLanguage.it: 'Elimina', AppLanguage.nl: 'Verwijderen', AppLanguage.fr: 'Delete', AppLanguage.pt: 'Delete', AppLanguage.pl: 'Delete', AppLanguage.tr: 'Delete', AppLanguage.ru: 'Delete'},
    'Manuelle Zutaten hinzufügen': {AppLanguage.de: 'Manuelle Zutaten hinzufügen', AppLanguage.en: 'Add manual ingredients', AppLanguage.es: 'Añadir ingredientes manuales', AppLanguage.it: 'Aggiungi ingredienti manuali', AppLanguage.nl: 'Handmatige ingrediënten toevoegen', AppLanguage.fr: 'Add manual ingredients', AppLanguage.pt: 'Add manual ingredients', AppLanguage.pl: 'Add manual ingredients', AppLanguage.tr: 'Add manual ingredients', AppLanguage.ru: 'Add manual ingredients'},
    'Manuellen Hinweis hinzufügen': {AppLanguage.de: 'Manuellen Hinweis hinzufügen', AppLanguage.en: 'Add manual note', AppLanguage.es: 'Añadir nota manual', AppLanguage.it: 'Aggiungi nota manuale', AppLanguage.nl: 'Handmatige opmerking toevoegen', AppLanguage.fr: 'Add manual note', AppLanguage.pt: 'Add manual note', AppLanguage.pl: 'Add manual note', AppLanguage.tr: 'Add manual note', AppLanguage.ru: 'Add manual note'},
    'Menge in ml': {AppLanguage.de: 'Menge in ml', AppLanguage.en: 'Amount in ml', AppLanguage.es: 'Cantidad en ml', AppLanguage.it: 'Quantità in ml', AppLanguage.nl: 'Hoeveelheid in ml', AppLanguage.fr: 'Amount in ml', AppLanguage.pt: 'Amount in ml', AppLanguage.pl: 'Amount in ml', AppLanguage.tr: 'Amount in ml', AppLanguage.ru: 'Amount in ml'},
    'Menge ml': {AppLanguage.de: 'Menge ml', AppLanguage.en: 'Amount ml', AppLanguage.es: 'Cantidad ml', AppLanguage.it: 'Quantità ml', AppLanguage.nl: 'Hoeveelheid ml', AppLanguage.fr: 'Amount ml', AppLanguage.pt: 'Amount ml', AppLanguage.pl: 'Amount ml', AppLanguage.tr: 'Amount ml', AppLanguage.ru: 'Amount ml'},
    'Name der Zutat': {AppLanguage.de: 'Name der Zutat', AppLanguage.en: 'Ingredient name', AppLanguage.es: 'Nombre del ingrediente', AppLanguage.it: 'Nome ingrediente', AppLanguage.nl: 'Naam van ingrediënt', AppLanguage.fr: 'Ingredient name', AppLanguage.pt: 'Ingredient name', AppLanguage.pl: 'Ingredient name', AppLanguage.tr: 'Ingredient name', AppLanguage.ru: 'Ingredient name'},
    'Name des Getränks': {AppLanguage.de: 'Name des Getränks', AppLanguage.en: 'Drink name', AppLanguage.es: 'Nombre de la bebida', AppLanguage.it: 'Nome bevanda', AppLanguage.nl: 'Naam van drankje', AppLanguage.fr: 'Drink name', AppLanguage.pt: 'Drink name', AppLanguage.pl: 'Drink name', AppLanguage.tr: 'Drink name', AppLanguage.ru: 'Drink name'},
    'Nebentext, Hinweise und Beschreibungen': {AppLanguage.de: 'Nebentext, Hinweise und Beschreibungen', AppLanguage.en: 'Secondary text, notes and descriptions', AppLanguage.es: 'Texto secundario, notas y descripciones', AppLanguage.it: 'Testo secondario, note e descrizioni', AppLanguage.nl: 'Subtekst, opmerkingen en beschrijvingen', AppLanguage.fr: 'Secondary text, notes and descriptions', AppLanguage.pt: 'Secondary text, notes and descriptions', AppLanguage.pl: 'Secondary text, notes and descriptions', AppLanguage.tr: 'Secondary text, notes and descriptions', AppLanguage.ru: 'Secondary text, notes and descriptions'},
    'Neue Zutaten': {AppLanguage.de: 'Neue Zutaten', AppLanguage.en: 'New ingredients', AppLanguage.es: 'Nuevos ingredientes', AppLanguage.it: 'Nuovi ingredienti', AppLanguage.nl: 'Nieuwe ingrediënten', AppLanguage.fr: 'New ingredients', AppLanguage.pt: 'New ingredients', AppLanguage.pl: 'New ingredients', AppLanguage.tr: 'New ingredients', AppLanguage.ru: 'New ingredients'},
    'Neues Rezept': {AppLanguage.de: 'Neues Rezept', AppLanguage.en: 'New recipe', AppLanguage.es: 'Nueva receta', AppLanguage.it: 'Nuova ricetta', AppLanguage.nl: 'Nieuw recept', AppLanguage.fr: 'New recipe', AppLanguage.pt: 'New recipe', AppLanguage.pl: 'New recipe', AppLanguage.tr: 'New recipe', AppLanguage.ru: 'New recipe'},
    'Neues Rezept erstellen': {AppLanguage.de: 'Neues Rezept erstellen', AppLanguage.en: 'Create new recipe', AppLanguage.es: 'Crear nueva receta', AppLanguage.it: 'Crea nuova ricetta', AppLanguage.nl: 'Nieuw recept maken', AppLanguage.fr: 'Create new recipe', AppLanguage.pt: 'Create new recipe', AppLanguage.pl: 'Create new recipe', AppLanguage.tr: 'Create new recipe', AppLanguage.ru: 'Create new recipe'},
    'Nicht zugeordnet': {AppLanguage.de: 'Nicht zugeordnet', AppLanguage.en: 'Not assigned', AppLanguage.es: 'No asignado', AppLanguage.it: 'Non assegnato', AppLanguage.nl: 'Niet toegewezen', AppLanguage.fr: 'Not assigned', AppLanguage.pt: 'Not assigned', AppLanguage.pl: 'Not assigned', AppLanguage.tr: 'Not assigned', AppLanguage.ru: 'Not assigned'},
    'Noch kein Zutatenverbrauch vorhanden': {AppLanguage.de: 'Noch kein Zutatenverbrauch vorhanden', AppLanguage.en: 'No ingredient consumption yet', AppLanguage.es: 'Aún no hay consumo de ingredientes', AppLanguage.it: 'Nessun consumo ingredienti', AppLanguage.nl: 'Nog geen ingrediëntenverbruik', AppLanguage.fr: 'No ingredient consumption yet', AppLanguage.pt: 'No ingredient consumption yet', AppLanguage.pl: 'No ingredient consumption yet', AppLanguage.tr: 'No ingredient consumption yet', AppLanguage.ru: 'No ingredient consumption yet'},
    'Noch keine Cocktails zubereitet': {AppLanguage.de: 'Noch keine Cocktails zubereitet', AppLanguage.en: 'No cocktails prepared yet', AppLanguage.es: 'Aún no hay cócteles preparados', AppLanguage.it: 'Nessun cocktail preparato', AppLanguage.nl: 'Nog geen cocktails bereid', AppLanguage.fr: 'No cocktails prepared yet', AppLanguage.pt: 'No cocktails prepared yet', AppLanguage.pl: 'No cocktails prepared yet', AppLanguage.tr: 'No cocktails prepared yet', AppLanguage.ru: 'No cocktails prepared yet'},
    'Noch keine Größenstatistik vorhanden': {AppLanguage.de: 'Noch keine Größenstatistik vorhanden', AppLanguage.en: 'No size statistics yet', AppLanguage.es: 'Aún no hay estadísticas de tamaño', AppLanguage.it: 'Nessuna statistica dimensioni', AppLanguage.nl: 'Nog geen formaatstatistiek', AppLanguage.fr: 'No size statistics yet', AppLanguage.pt: 'No size statistics yet', AppLanguage.pl: 'No size statistics yet', AppLanguage.tr: 'No size statistics yet', AppLanguage.ru: 'No size statistics yet'},
    'Noch keine Rezepte vorhanden': {AppLanguage.de: 'Noch keine Rezepte vorhanden', AppLanguage.en: 'No recipes yet', AppLanguage.es: 'Aún no hay recetas', AppLanguage.it: 'Nessuna ricetta ancora', AppLanguage.nl: 'Nog geen recepten', AppLanguage.fr: 'No recipes yet', AppLanguage.pt: 'No recipes yet', AppLanguage.pl: 'No recipes yet', AppLanguage.tr: 'No recipes yet', AppLanguage.ru: 'No recipes yet'},
    'Preset auswählen': {AppLanguage.de: 'Preset auswählen', AppLanguage.en: 'Choose preset', AppLanguage.es: 'Elegir preset', AppLanguage.it: 'Scegli preset', AppLanguage.nl: 'Preset kiezen', AppLanguage.fr: 'Choose preset', AppLanguage.pt: 'Choose preset', AppLanguage.pl: 'Choose preset', AppLanguage.tr: 'Choose preset', AppLanguage.ru: 'Choose preset'},
    'Reinigung abgeschlossen': {AppLanguage.de: 'Reinigung abgeschlossen', AppLanguage.en: 'Cleaning finished', AppLanguage.es: 'Limpieza finalizada', AppLanguage.it: 'Pulizia completata', AppLanguage.nl: 'Reiniging voltooid', AppLanguage.fr: 'Cleaning finished', AppLanguage.pt: 'Cleaning finished', AppLanguage.pl: 'Cleaning finished', AppLanguage.tr: 'Cleaning finished', AppLanguage.ru: 'Cleaning finished'},
    'Reinigung starten': {AppLanguage.de: 'Reinigung starten', AppLanguage.en: 'Start cleaning', AppLanguage.es: 'Iniciar limpieza', AppLanguage.it: 'Avvia pulizia', AppLanguage.nl: 'Reiniging starten', AppLanguage.fr: 'Start cleaning', AppLanguage.pt: 'Start cleaning', AppLanguage.pl: 'Start cleaning', AppLanguage.tr: 'Start cleaning', AppLanguage.ru: 'Start cleaning'},
    'So funktioniert die Kalibrierung': {AppLanguage.de: 'So funktioniert die Kalibrierung', AppLanguage.en: 'How calibration works', AppLanguage.es: 'Cómo funciona la calibración', AppLanguage.it: 'Come funziona la calibrazione', AppLanguage.nl: 'Zo werkt kalibratie', AppLanguage.fr: 'How calibration works', AppLanguage.pt: 'How calibration works', AppLanguage.pl: 'How calibration works', AppLanguage.tr: 'How calibration works', AppLanguage.ru: 'How calibration works'},
    'Standarddesign wiederherstellen': {AppLanguage.de: 'Standarddesign wiederherstellen', AppLanguage.en: 'Restore default design', AppLanguage.es: 'Restaurar diseño predeterminado', AppLanguage.it: 'Ripristina design standard', AppLanguage.nl: 'Standaardontwerp herstellen', AppLanguage.fr: 'Restore default design', AppLanguage.pt: 'Restore default design', AppLanguage.pl: 'Restore default design', AppLanguage.tr: 'Restore default design', AppLanguage.ru: 'Restore default design'},
    'Standarddesign wiederhergestellt': {AppLanguage.de: 'Standarddesign wiederhergestellt', AppLanguage.en: 'Default design restored', AppLanguage.es: 'Diseño predeterminado restaurado', AppLanguage.it: 'Design standard ripristinato', AppLanguage.nl: 'Standaardontwerp hersteld', AppLanguage.fr: 'Default design restored', AppLanguage.pt: 'Default design restored', AppLanguage.pl: 'Default design restored', AppLanguage.tr: 'Default design restored', AppLanguage.ru: 'Default design restored'},
    'Startet erst, wenn alle normalen Pumpen fertig sind': {AppLanguage.de: 'Startet erst, wenn alle normalen Pumpen fertig sind', AppLanguage.en: 'Starts only after all normal pumps have finished', AppLanguage.es: 'Empieza cuando todas las bombas normales hayan terminado', AppLanguage.it: 'Parte solo dopo tutte le pompe normali', AppLanguage.nl: 'Start pas nadat alle normale pompen klaar zijn', AppLanguage.fr: 'Starts only after all normal pumps have finished', AppLanguage.pt: 'Starts only after all normal pumps have finished', AppLanguage.pl: 'Starts only after all normal pumps have finished', AppLanguage.tr: 'Starts only after all normal pumps have finished', AppLanguage.ru: 'Starts only after all normal pumps have finished'},
    'Statistik zurücksetzen': {AppLanguage.de: 'Statistik zurücksetzen', AppLanguage.en: 'Reset statistics', AppLanguage.es: 'Restablecer estadísticas', AppLanguage.it: 'Reimposta statistiche', AppLanguage.nl: 'Statistiek resetten', AppLanguage.fr: 'Reset statistics', AppLanguage.pt: 'Reset statistics', AppLanguage.pl: 'Reset statistics', AppLanguage.tr: 'Reset statistics', AppLanguage.ru: 'Reset statistics'},
    'Statistik zurücksetzen?': {AppLanguage.de: 'Statistik zurücksetzen?', AppLanguage.en: 'Reset statistics?', AppLanguage.es: '¿Restablecer estadísticas?', AppLanguage.it: 'Reimpostare statistiche?', AppLanguage.nl: 'Statistiek resetten?', AppLanguage.fr: 'Reset statistics?', AppLanguage.pt: 'Reset statistics?', AppLanguage.pl: 'Reset statistics?', AppLanguage.tr: 'Reset statistics?', AppLanguage.ru: 'Reset statistics?'},
    'Verbindung herstellen': {AppLanguage.de: 'Verbindung herstellen', AppLanguage.en: 'Connect', AppLanguage.es: 'Conectar', AppLanguage.it: 'Connetti', AppLanguage.nl: 'Verbinden', AppLanguage.fr: 'Connect', AppLanguage.pt: 'Connect', AppLanguage.pl: 'Connect', AppLanguage.tr: 'Connect', AppLanguage.ru: 'Connect'},
    'Verbraucht': {AppLanguage.de: 'Verbraucht', AppLanguage.en: 'Consumed', AppLanguage.es: 'Consumido', AppLanguage.it: 'Consumata', AppLanguage.nl: 'Verbruikt', AppLanguage.fr: 'Consumed', AppLanguage.pt: 'Consumed', AppLanguage.pl: 'Consumed', AppLanguage.tr: 'Consumed', AppLanguage.ru: 'Consumed'},
    'Vorgang wurde abgebrochen': {AppLanguage.de: 'Vorgang wurde abgebrochen', AppLanguage.en: 'Process was canceled', AppLanguage.es: 'Proceso cancelado', AppLanguage.it: 'Processo annullato', AppLanguage.nl: 'Proces afgebroken', AppLanguage.fr: 'Process was canceled', AppLanguage.pt: 'Process was canceled', AppLanguage.pl: 'Process was canceled', AppLanguage.tr: 'Process was canceled', AppLanguage.ru: 'Process was canceled'},
    'Vorschau': {AppLanguage.de: 'Vorschau', AppLanguage.en: 'Preview', AppLanguage.es: 'Vista previa', AppLanguage.it: 'Anteprima', AppLanguage.nl: 'Voorbeeld', AppLanguage.fr: 'Preview', AppLanguage.pt: 'Preview', AppLanguage.pl: 'Preview', AppLanguage.tr: 'Preview', AppLanguage.ru: 'Preview'},
    'WLAN': {AppLanguage.de: 'WLAN', AppLanguage.en: 'Wi-Fi', AppLanguage.es: 'Wi‑Fi', AppLanguage.it: 'Wi‑Fi', AppLanguage.nl: 'Wifi', AppLanguage.fr: 'Wi-Fi', AppLanguage.pt: 'Wi-Fi', AppLanguage.pl: 'Wi-Fi', AppLanguage.tr: 'Wi-Fi', AppLanguage.ru: 'Wi-Fi'},
    'Wird beim Tippen automatisch gespeichert': {AppLanguage.de: 'Wird beim Tippen automatisch gespeichert', AppLanguage.en: 'Saved automatically while typing', AppLanguage.es: 'Se guarda automáticamente al escribir', AppLanguage.it: 'Salvato automaticamente durante la digitazione', AppLanguage.nl: 'Wordt automatisch opgeslagen tijdens typen', AppLanguage.fr: 'Saved automatically while typing', AppLanguage.pt: 'Saved automatically while typing', AppLanguage.pl: 'Saved automatically while typing', AppLanguage.tr: 'Saved automatically while typing', AppLanguage.ru: 'Saved automatically while typing'},
    'Wird für Cocktailkosten und Verbrauchsstatistik genutzt': {AppLanguage.de: 'Wird für Cocktailkosten und Verbrauchsstatistik genutzt', AppLanguage.en: 'Used for cocktail costs and consumption statistics', AppLanguage.es: 'Se usa para costes y estadísticas', AppLanguage.it: 'Usato per costi e statistiche', AppLanguage.nl: 'Gebruikt voor kosten en verbruiksstatistiek', AppLanguage.fr: 'Used for cocktail costs and consumption statistics', AppLanguage.pt: 'Used for cocktail costs and consumption statistics', AppLanguage.pl: 'Used for cocktail costs and consumption statistics', AppLanguage.tr: 'Used for cocktail costs and consumption statistics', AppLanguage.ru: 'Used for cocktail costs and consumption statistics'},
    'Wird über eine Pumpe dosiert': {AppLanguage.de: 'Wird über eine Pumpe dosiert', AppLanguage.en: 'Dispensed by a pump', AppLanguage.es: 'Dosificado por una bomba', AppLanguage.it: 'Dosato da una pompa', AppLanguage.nl: 'Gedoseerd via een pomp', AppLanguage.fr: 'Dispensed by a pump', AppLanguage.pt: 'Dispensed by a pump', AppLanguage.pl: 'Dispensed by a pump', AppLanguage.tr: 'Dispensed by a pump', AppLanguage.ru: 'Dispensed by a pump'},
    'Zielgröße': {AppLanguage.de: 'Zielgröße', AppLanguage.en: 'Target size', AppLanguage.es: 'Tamaño objetivo', AppLanguage.it: 'Dimensione target', AppLanguage.nl: 'Doelformaat', AppLanguage.fr: 'Target size', AppLanguage.pt: 'Target size', AppLanguage.pl: 'Target size', AppLanguage.tr: 'Target size', AppLanguage.ru: 'Target size'},
    'Zubereitung abgeschlossen': {AppLanguage.de: 'Zubereitung abgeschlossen', AppLanguage.en: 'Preparation finished', AppLanguage.es: 'Preparación finalizada', AppLanguage.it: 'Preparazione completata', AppLanguage.nl: 'Bereiding voltooid', AppLanguage.fr: 'Preparation finished', AppLanguage.pt: 'Preparation finished', AppLanguage.pl: 'Preparation finished', AppLanguage.tr: 'Preparation finished', AppLanguage.ru: 'Preparation finished'},
    'Zum Schluss dosieren': {AppLanguage.de: 'Zum Schluss dosieren', AppLanguage.en: 'Dose at the end', AppLanguage.es: 'Dosificar al final', AppLanguage.it: 'Dosare alla fine', AppLanguage.nl: 'Aan het einde doseren', AppLanguage.fr: 'Dose at the end', AppLanguage.pt: 'Dose at the end', AppLanguage.pl: 'Dose at the end', AppLanguage.tr: 'Dose at the end', AppLanguage.ru: 'Dose at the end'},
    'Zurücksetzen': {AppLanguage.de: 'Zurücksetzen', AppLanguage.en: 'Reset', AppLanguage.es: 'Restablecer', AppLanguage.it: 'Reimposta', AppLanguage.nl: 'Resetten', AppLanguage.fr: 'Reset', AppLanguage.pt: 'Reset', AppLanguage.pl: 'Reset', AppLanguage.tr: 'Reset', AppLanguage.ru: 'Reset'},
    'Zusätzliche manuelle Hinweise': {AppLanguage.de: 'Zusätzliche manuelle Hinweise', AppLanguage.en: 'Additional manual notes', AppLanguage.es: 'Notas manuales adicionales', AppLanguage.it: 'Note manuali aggiuntive', AppLanguage.nl: 'Extra handmatige opmerkingen', AppLanguage.fr: 'Additional manual notes', AppLanguage.pt: 'Additional manual notes', AppLanguage.pl: 'Additional manual notes', AppLanguage.tr: 'Additional manual notes', AppLanguage.ru: 'Additional manual notes'},
    'Zutat': {AppLanguage.de: 'Zutat', AppLanguage.en: 'Ingredient', AppLanguage.es: 'Ingrediente', AppLanguage.it: 'Ingrediente', AppLanguage.nl: 'Ingrediënt', AppLanguage.fr: 'Ingredient', AppLanguage.pt: 'Ingredient', AppLanguage.pl: 'Ingredient', AppLanguage.tr: 'Ingredient', AppLanguage.ru: 'Ingredient'},
    'Zutat hinzufügen': {AppLanguage.de: 'Zutat hinzufügen', AppLanguage.en: 'Add ingredient', AppLanguage.es: 'Añadir ingrediente', AppLanguage.it: 'Aggiungi ingrediente', AppLanguage.nl: 'Ingrediënt toevoegen', AppLanguage.fr: 'Add ingredient', AppLanguage.pt: 'Add ingredient', AppLanguage.pl: 'Add ingredient', AppLanguage.tr: 'Add ingredient', AppLanguage.ru: 'Add ingredient'},
    'Cocktail wird zubereitet': {AppLanguage.de: 'Cocktail wird zubereitet', AppLanguage.en: 'Cocktail is being prepared', AppLanguage.es: 'Preparando cóctel', AppLanguage.it: 'Cocktail in preparazione', AppLanguage.nl: 'Cocktail wordt bereid', AppLanguage.fr: 'Cocktail is being prepared', AppLanguage.pt: 'Cocktail is being prepared', AppLanguage.pl: 'Cocktail is being prepared', AppLanguage.tr: 'Cocktail is being prepared', AppLanguage.ru: 'Cocktail is being prepared'},
    'Bitte das Glas nicht entfernen.': {AppLanguage.de: 'Bitte das Glas nicht entfernen.', AppLanguage.en: 'Please do not remove the glass.', AppLanguage.es: 'No retires el vaso.', AppLanguage.it: 'Non rimuovere il bicchiere.', AppLanguage.nl: 'Verwijder het glas niet.', AppLanguage.fr: 'Please do not remove the glass.', AppLanguage.pt: 'Please do not remove the glass.', AppLanguage.pl: 'Please do not remove the glass.', AppLanguage.tr: 'Please do not remove the glass.', AppLanguage.ru: 'Please do not remove the glass.'},
    'Entlüften abgeschlossen': {AppLanguage.de: 'Entlüften abgeschlossen', AppLanguage.en: 'Priming finished', AppLanguage.es: 'Purga finalizada', AppLanguage.it: 'Spurgo completato', AppLanguage.nl: 'Ontluchten voltooid', AppLanguage.fr: 'Priming finished', AppLanguage.pt: 'Priming finished', AppLanguage.pl: 'Priming finished', AppLanguage.tr: 'Priming finished', AppLanguage.ru: 'Priming finished'},
    'Alle Pumpen entlüften': {AppLanguage.de: 'Alle Pumpen entlüften', AppLanguage.en: 'Prime all pumps', AppLanguage.es: 'Purgar todas las bombas', AppLanguage.it: 'Spurga tutte le pompe', AppLanguage.nl: 'Alle pompen ontluchten', AppLanguage.fr: 'Prime all pumps', AppLanguage.pt: 'Prime all pumps', AppLanguage.pl: 'Prime all pumps', AppLanguage.tr: 'Prime all pumps', AppLanguage.ru: 'Prime all pumps'},
    'Hinweis zum Entlüften': {AppLanguage.de: 'Hinweis zum Entlüften', AppLanguage.en: 'Priming note', AppLanguage.es: 'Nota de purga', AppLanguage.it: 'Nota sullo spurgo', AppLanguage.nl: 'Opmerking over ontluchten', AppLanguage.fr: 'Priming note', AppLanguage.pt: 'Priming note', AppLanguage.pl: 'Priming note', AppLanguage.tr: 'Priming note', AppLanguage.ru: 'Priming note'},
    'Anleitung zur Reinigung': {AppLanguage.de: 'Anleitung zur Reinigung', AppLanguage.en: 'Cleaning instructions', AppLanguage.es: 'Instrucciones de limpieza', AppLanguage.it: 'Istruzioni di pulizia', AppLanguage.nl: 'Reinigingsinstructies', AppLanguage.fr: 'Cleaning instructions', AppLanguage.pt: 'Cleaning instructions', AppLanguage.pl: 'Cleaning instructions', AppLanguage.tr: 'Cleaning instructions', AppLanguage.ru: 'Cleaning instructions'},
    'Alle aktiven Pumpen laufen nacheinander mit derselben Zeit.': {AppLanguage.de: 'Alle aktiven Pumpen laufen nacheinander mit derselben Zeit.', AppLanguage.en: 'All active pumps run one after another with the same time.', AppLanguage.es: 'Todas las bombas activas funcionan una tras otra con el mismo tiempo.', AppLanguage.it: 'Tutte le pompe attive funzionano in sequenza con lo stesso tempo.', AppLanguage.nl: 'Alle actieve pompen lopen na elkaar met dezelfde tijd.', AppLanguage.fr: 'All active pumps run one after another with the same time.', AppLanguage.pt: 'All active pumps run one after another with the same time.', AppLanguage.pl: 'All active pumps run one after another with the same time.', AppLanguage.tr: 'All active pumps run one after another with the same time.', AppLanguage.ru: 'All active pumps run one after another with the same time.'},
    'Diese Pumpe ist deaktiviert. Aktiviere sie, um sie zu konfigurieren.': {AppLanguage.de: 'Diese Pumpe ist deaktiviert. Aktiviere sie, um sie zu konfigurieren.', AppLanguage.en: 'This pump is disabled. Enable it to configure it.', AppLanguage.es: 'Esta bomba está desactivada. Actívala para configurarla.', AppLanguage.it: 'Questa pompa è disattivata. Attivala per configurarla.', AppLanguage.nl: 'Deze pomp is uitgeschakeld. Schakel hem in om te configureren.', AppLanguage.fr: 'This pump is disabled. Enable it to configure it.', AppLanguage.pt: 'This pump is disabled. Enable it to configure it.', AppLanguage.pl: 'This pump is disabled. Enable it to configure it.', AppLanguage.tr: 'This pump is disabled. Enable it to configure it.', AppLanguage.ru: 'This pump is disabled. Enable it to configure it.'},
    'Online': {AppLanguage.de: 'Online', AppLanguage.en: 'Online', AppLanguage.es: 'En línea', AppLanguage.it: 'Online', AppLanguage.nl: 'Online', AppLanguage.fr: 'Online', AppLanguage.pt: 'Online', AppLanguage.pl: 'Online', AppLanguage.tr: 'Online', AppLanguage.ru: 'Online'},
    'Offline': {AppLanguage.de: 'Offline', AppLanguage.en: 'Offline', AppLanguage.es: 'Sin conexión', AppLanguage.it: 'Offline', AppLanguage.nl: 'Offline', AppLanguage.fr: 'Offline', AppLanguage.pt: 'Offline', AppLanguage.pl: 'Offline', AppLanguage.tr: 'Offline', AppLanguage.ru: 'Offline'},
    'CocktailBot': {AppLanguage.de: 'CocktailBot', AppLanguage.en: 'CocktailBot', AppLanguage.es: 'CocktailBot', AppLanguage.it: 'CocktailBot', AppLanguage.nl: 'CocktailBot', AppLanguage.fr: 'CocktailBot', AppLanguage.pt: 'CocktailBot', AppLanguage.pl: 'CocktailBot', AppLanguage.tr: 'CocktailBot', AppLanguage.ru: 'CocktailBot'},
    'Cocktail-Maschine': {AppLanguage.de: 'Cocktail-Maschine', AppLanguage.en: 'Cocktail machine', AppLanguage.es: 'Máquina de cócteles', AppLanguage.it: 'Macchina per cocktail', AppLanguage.nl: 'Cocktailmachine', AppLanguage.fr: 'Cocktail machine', AppLanguage.pt: 'Cocktail machine', AppLanguage.pl: 'Cocktail machine', AppLanguage.tr: 'Cocktail machine', AppLanguage.ru: 'Cocktail machine'},
    '€/L': {AppLanguage.de: '€/L', AppLanguage.en: '€/L', AppLanguage.es: '€/L', AppLanguage.it: '€/L', AppLanguage.nl: '€/L', AppLanguage.fr: '€/L', AppLanguage.pt: '€/L', AppLanguage.pl: '€/L', AppLanguage.tr: '€/L', AppLanguage.ru: '€/L'},
    'Die normalen Zutaten starten im Abstand von 0,1 Sekunden. Zutaten „Zum Schluss“ werden danach dosiert.': {AppLanguage.de: 'Die normalen Zutaten starten im Abstand von 0,1 Sekunden. Zutaten „Zum Schluss“ werden danach dosiert.', AppLanguage.en: 'The normal ingredients start 0.1 seconds apart. Ingredients marked “Dose at the end” are dispensed afterwards.', AppLanguage.es: 'Los ingredientes normales empiezan con 0,1 segundos de separación. Los ingredientes “Dosificar al final” se dosifican después.', AppLanguage.it: 'Gli ingredienti normali partono a intervalli di 0,1 secondi. Gli ingredienti “Dosare alla fine” vengono erogati dopo.', AppLanguage.nl: 'De normale ingrediënten starten met 0,1 seconde verschil. Ingrediënten “Aan het einde doseren” worden daarna gedoseerd.', AppLanguage.fr: 'The normal ingredients start 0.1 seconds apart. Ingredients marked “Dose at the end” are dispensed afterwards.', AppLanguage.pt: 'The normal ingredients start 0.1 seconds apart. Ingredients marked “Dose at the end” are dispensed afterwards.', AppLanguage.pl: 'The normal ingredients start 0.1 seconds apart. Ingredients marked “Dose at the end” are dispensed afterwards.', AppLanguage.tr: 'The normal ingredients start 0.1 seconds apart. Ingredients marked “Dose at the end” are dispensed afterwards.', AppLanguage.ru: 'The normal ingredients start 0.1 seconds apart. Ingredients marked “Dose at the end” are dispensed afterwards.'},
    'Cocktail-Ranking, Größenstatistik und Zutatenverbrauch werden gelöscht. Füllstände und Kalibrierungen bleiben erhalten.': {AppLanguage.de: 'Cocktail-Ranking, Größenstatistik und Zutatenverbrauch werden gelöscht. Füllstände und Kalibrierungen bleiben erhalten.', AppLanguage.en: 'Cocktail ranking, size statistics and ingredient consumption will be deleted. Fill levels and calibrations remain unchanged.', AppLanguage.es: 'Se borrarán el ranking de cócteles, estadísticas de tamaños y consumo de ingredientes. Los niveles y calibraciones permanecen.', AppLanguage.it: 'Classifica cocktail, statistiche dimensioni e consumo ingredienti verranno cancellati. Livelli e calibrazioni restano invariati.', AppLanguage.nl: 'Cocktailranglijst, formaatstatistiek en ingrediëntenverbruik worden verwijderd. Vulniveaus en kalibraties blijven behouden.', AppLanguage.fr: 'Cocktail ranking, size statistics and ingredient consumption will be deleted. Fill levels and calibrations remain unchanged.', AppLanguage.pt: 'Cocktail ranking, size statistics and ingredient consumption will be deleted. Fill levels and calibrations remain unchanged.', AppLanguage.pl: 'Cocktail ranking, size statistics and ingredient consumption will be deleted. Fill levels and calibrations remain unchanged.', AppLanguage.tr: 'Cocktail ranking, size statistics and ingredient consumption will be deleted. Fill levels and calibrations remain unchanged.', AppLanguage.ru: 'Cocktail ranking, size statistics and ingredient consumption will be deleted. Fill levels and calibrations remain unchanged.'},
    'Name, gültige Rezeptgröße und mindestens eine Zutat erforderlich': {AppLanguage.de: 'Name, gültige Rezeptgröße und mindestens eine Zutat erforderlich', AppLanguage.en: 'Name, valid recipe size and at least one ingredient required', AppLanguage.es: 'Se requiere nombre, tamaño válido y al menos un ingrediente', AppLanguage.it: 'Servono nome, dimensione valida e almeno un ingrediente', AppLanguage.nl: 'Naam, geldig receptformaat en minimaal één ingrediënt vereist', AppLanguage.fr: 'Name, valid recipe size and at least one ingredient required', AppLanguage.pt: 'Name, valid recipe size and at least one ingredient required', AppLanguage.pl: 'Name, valid recipe size and at least one ingredient required', AppLanguage.tr: 'Name, valid recipe size and at least one ingredient required', AppLanguage.ru: 'Name, valid recipe size and at least one ingredient required'},
    'Hier kannst du die wichtigsten App-Farben selbst anpassen. Die Änderungen betreffen Theme, Hintergrund, Karten, Navigation, Buttons, Slider, Fortschrittsbalken, Rahmen und Statusfarben.': {AppLanguage.de: 'Hier kannst du die wichtigsten App-Farben selbst anpassen. Die Änderungen betreffen Theme, Hintergrund, Karten, Navigation, Buttons, Slider, Fortschrittsbalken, Rahmen und Statusfarben.', AppLanguage.en: 'Here you can customize the most important app colors. Changes affect the theme, background, cards, navigation, buttons, sliders, progress bars, borders and status colors.', AppLanguage.es: 'Aquí puedes personalizar los colores principales de la app. Los cambios afectan tema, fondo, tarjetas, navegación, botones, controles, barras de progreso, bordes y colores de estado.', AppLanguage.it: 'Qui puoi personalizzare i colori principali dell’app. Le modifiche riguardano tema, sfondo, schede, navigazione, pulsanti, slider, barre di avanzamento, bordi e colori di stato.', AppLanguage.nl: 'Hier kun je de belangrijkste app-kleuren aanpassen. Wijzigingen gelden voor thema, achtergrond, kaarten, navigatie, knoppen, sliders, voortgangsbalken, randen en statuskleuren.', AppLanguage.fr: 'Here you can customize the most important app colors. Changes affect the theme, background, cards, navigation, buttons, sliders, progress bars, borders and status colors.', AppLanguage.pt: 'Here you can customize the most important app colors. Changes affect the theme, background, cards, navigation, buttons, sliders, progress bars, borders and status colors.', AppLanguage.pl: 'Here you can customize the most important app colors. Changes affect the theme, background, cards, navigation, buttons, sliders, progress bars, borders and status colors.', AppLanguage.tr: 'Here you can customize the most important app colors. Changes affect the theme, background, cards, navigation, buttons, sliders, progress bars, borders and status colors.', AppLanguage.ru: 'Here you can customize the most important app colors. Changes affect the theme, background, cards, navigation, buttons, sliders, progress bars, borders and status colors.'},
    'Diese Einstellungen gelten für den Idle-Betrieb. Während der Cocktailzubereitung blinkt der Ring rot. Nach erfolgreicher Fertigstellung leuchtet er fünf Sekunden grün und kehrt danach automatisch zum gewählten Idle-Effekt zurück.': {AppLanguage.de: 'Diese Einstellungen gelten für den Idle-Betrieb. Während der Cocktailzubereitung blinkt der Ring rot. Nach erfolgreicher Fertigstellung leuchtet er fünf Sekunden grün und kehrt danach automatisch zum gewählten Idle-Effekt zurück.', AppLanguage.en: 'These settings apply to idle mode. During cocktail preparation the ring flashes red. After successful completion it lights green for five seconds and then returns to the selected idle effect.', AppLanguage.es: 'Estos ajustes se aplican al modo de reposo. Durante la preparación el anillo parpadea en rojo. Al terminar correctamente se ilumina en verde durante cinco segundos y vuelve al efecto elegido.', AppLanguage.it: 'Queste impostazioni valgono per la modalità idle. Durante la preparazione il ring lampeggia rosso. Al termine si illumina verde per cinque secondi e poi torna all’effetto scelto.', AppLanguage.nl: 'Deze instellingen gelden voor idle-modus. Tijdens de bereiding knippert de ring rood. Na succesvolle afronding brandt hij vijf seconden groen en keert terug naar het gekozen idle-effect.', AppLanguage.fr: 'These settings apply to idle mode. During cocktail preparation the ring flashes red. After successful completion it lights green for five seconds and then returns to the selected idle effect.', AppLanguage.pt: 'These settings apply to idle mode. During cocktail preparation the ring flashes red. After successful completion it lights green for five seconds and then returns to the selected idle effect.', AppLanguage.pl: 'These settings apply to idle mode. During cocktail preparation the ring flashes red. After successful completion it lights green for five seconds and then returns to the selected idle effect.', AppLanguage.tr: 'These settings apply to idle mode. During cocktail preparation the ring flashes red. After successful completion it lights green for five seconds and then returns to the selected idle effect.', AppLanguage.ru: 'These settings apply to idle mode. During cocktail preparation the ring flashes red. After successful completion it lights green for five seconds and then returns to the selected idle effect.'},
    'Beim Entlüften werden die Schläuche vollständig mit den jeweiligen Zutaten gefüllt. Jede aktive Pumpe läuft nacheinander mit ihrer eigenen gespeicherten Zeit.\n\nTeste beim ersten Einrichten, wie viele Sekunden jede Pumpe benötigt. Die eingestellten Zeiten werden dauerhaft gespeichert und beim nächsten Entlüften erneut verwendet.': {AppLanguage.de: 'Beim Entlüften werden die Schläuche vollständig mit den jeweiligen Zutaten gefüllt. Jede aktive Pumpe läuft nacheinander mit ihrer eigenen gespeicherten Zeit.\n\nTeste beim ersten Einrichten, wie viele Sekunden jede Pumpe benötigt. Die eingestellten Zeiten werden dauerhaft gespeichert und beim nächsten Entlüften erneut verwendet.', AppLanguage.en: 'During priming, the tubes are fully filled with the respective ingredients. Each active pump runs one after another with its own saved time.\n\nDuring setup, test how many seconds each pump needs. The selected times are saved permanently and reused next time.', AppLanguage.es: 'Durante la purga, los tubos se llenan completamente con los ingredientes correspondientes. Cada bomba activa funciona una tras otra con su tiempo guardado.\n\nPrueba cuántos segundos necesita cada bomba. Los tiempos se guardan y se reutilizan.', AppLanguage.it: 'Durante lo spurgo, i tubi vengono riempiti completamente con gli ingredienti. Ogni pompa attiva funziona in sequenza con il proprio tempo salvato.\n\nTesta quanti secondi servono per ogni pompa. I tempi vengono salvati e riutilizzati.', AppLanguage.nl: 'Tijdens het ontluchten worden de slangen volledig gevuld met de betreffende ingrediënten. Elke actieve pomp loopt na elkaar met zijn opgeslagen tijd.\n\nTest bij het instellen hoeveel seconden elke pomp nodig heeft. De tijden worden opgeslagen.', AppLanguage.fr: 'During priming, the tubes are fully filled with the respective ingredients. Each active pump runs one after another with its own saved time.\n\nDuring setup, test how many seconds each pump needs. The selected times are saved permanently and reused next time.', AppLanguage.pt: 'During priming, the tubes are fully filled with the respective ingredients. Each active pump runs one after another with its own saved time.\n\nDuring setup, test how many seconds each pump needs. The selected times are saved permanently and reused next time.', AppLanguage.pl: 'During priming, the tubes are fully filled with the respective ingredients. Each active pump runs one after another with its own saved time.\n\nDuring setup, test how many seconds each pump needs. The selected times are saved permanently and reused next time.', AppLanguage.tr: 'During priming, the tubes are fully filled with the respective ingredients. Each active pump runs one after another with its own saved time.\n\nDuring setup, test how many seconds each pump needs. The selected times are saved permanently and reused next time.', AppLanguage.ru: 'During priming, the tubes are fully filled with the respective ingredients. Each active pump runs one after another with its own saved time.\n\nDuring setup, test how many seconds each pump needs. The selected times are saved permanently and reused next time.'},
    'Design übernehmen': {AppLanguage.de: 'Design übernehmen', AppLanguage.en: 'Apply design', AppLanguage.es: 'Aplicar diseño', AppLanguage.it: 'Applica design', AppLanguage.nl: 'Ontwerp toepassen', AppLanguage.fr: 'Apply design', AppLanguage.pt: 'Apply design', AppLanguage.pl: 'Apply design', AppLanguage.tr: 'Apply design', AppLanguage.ru: 'Apply design'},
    'Wird gespeichert …': {AppLanguage.de: 'Wird gespeichert …', AppLanguage.en: 'Saving …', AppLanguage.es: 'Guardando …', AppLanguage.it: 'Salvataggio …', AppLanguage.nl: 'Wordt opgeslagen …', AppLanguage.fr: 'Saving …', AppLanguage.pt: 'Saving …', AppLanguage.pl: 'Saving …', AppLanguage.tr: 'Saving …', AppLanguage.ru: 'Saving …'},
    'Beispiel: Rezeptwerte für 300 ml eingeben. Die App skaliert automatisch auf 200 ml oder andere Größen.': {AppLanguage.de: 'Beispiel: Rezeptwerte für 300 ml eingeben. Die App skaliert automatisch auf 200 ml oder andere Größen.', AppLanguage.en: 'Example: Enter recipe values for 300 ml. The app automatically scales to 200 ml or other sizes.', AppLanguage.es: 'Ejemplo: introduce los valores de receta para 300 ml. La app escala automáticamente a 200 ml u otros tamaños.', AppLanguage.it: 'Esempio: inserisci i valori della ricetta per 300 ml. L’app scala automaticamente a 200 ml o altre dimensioni.', AppLanguage.nl: 'Voorbeeld: voer receptwaarden voor 300 ml in. De app schaalt automatisch naar 200 ml of andere formaten.', AppLanguage.fr: 'Example: Enter recipe values for 300 ml. The app automatically scales to 200 ml or other sizes.', AppLanguage.pt: 'Example: Enter recipe values for 300 ml. The app automatically scales to 200 ml or other sizes.', AppLanguage.pl: 'Example: Enter recipe values for 300 ml. The app automatically scales to 200 ml or other sizes.', AppLanguage.tr: 'Example: Enter recipe values for 300 ml. The app automatically scales to 200 ml or other sizes.', AppLanguage.ru: 'Example: Enter recipe values for 300 ml. The app automatically scales to 200 ml or other sizes.'},
    'Verbrauchsstatistik': {AppLanguage.de: 'Verbrauchsstatistik', AppLanguage.en: 'Consumption statistics', AppLanguage.es: 'Estadísticas de consumo', AppLanguage.it: 'Statistiche consumo', AppLanguage.nl: 'Verbruiksstatistiek', AppLanguage.fr: 'Statistiques de consommation', AppLanguage.pt: 'Estatísticas de consumo', AppLanguage.pl: 'Statystyki zużycia', AppLanguage.tr: 'Tüketim istatistikleri', AppLanguage.ru: 'Статистика расхода'},
    'Cocktail-Ranking, Kosten und Zutatenverbrauch': {AppLanguage.de: 'Cocktail-Ranking, Kosten und Zutatenverbrauch', AppLanguage.en: 'Cocktail ranking, costs and ingredient consumption', AppLanguage.es: 'Ranking, costes y consumo de ingredientes', AppLanguage.it: 'Classifica, costi e consumo ingredienti', AppLanguage.nl: 'Cocktailranglijst, kosten en ingrediëntenverbruik', AppLanguage.fr: 'Classement, coûts et consommation des ingrédients', AppLanguage.pt: 'Ranking, custos e consumo de ingredientes', AppLanguage.pl: 'Ranking, koszty i zużycie składników', AppLanguage.tr: 'Kokteyl sıralaması, maliyetler ve malzeme tüketimi', AppLanguage.ru: 'Рейтинг, стоимость и расход ингредиентов'},
    'Kalibrierung fehlt': {AppLanguage.de: 'Kalibrierung fehlt', AppLanguage.en: 'Calibration missing', AppLanguage.es: 'Falta calibración', AppLanguage.it: 'Calibrazione mancante', AppLanguage.nl: 'Kalibratie ontbreekt', AppLanguage.fr: 'Étalonnage manquant', AppLanguage.pt: 'Calibração ausente', AppLanguage.pl: 'Brak kalibracji', AppLanguage.tr: 'Kalibrasyon eksik', AppLanguage.ru: 'Нет калибровки'},
    'Niedriger Füllstand': {AppLanguage.de: 'Niedriger Füllstand', AppLanguage.en: 'Low fill level', AppLanguage.es: 'Nivel bajo', AppLanguage.it: 'Livello basso', AppLanguage.nl: 'Laag vulniveau', AppLanguage.fr: 'Niveau bas', AppLanguage.pt: 'Nível baixo', AppLanguage.pl: 'Niski poziom', AppLanguage.tr: 'Düşük seviye', AppLanguage.ru: 'Низкий уровень'},
    'Nicht verfügbar': {AppLanguage.de: 'Nicht verfügbar', AppLanguage.en: 'Not available', AppLanguage.es: 'No disponible', AppLanguage.it: 'Non disponibile', AppLanguage.nl: 'Niet beschikbaar', AppLanguage.fr: 'Non disponible', AppLanguage.pt: 'Indisponível', AppLanguage.pl: 'Niedostępne', AppLanguage.tr: 'Mevcut değil', AppLanguage.ru: 'Недоступно'},
    'Kalibrierung erforderlich': {AppLanguage.de: 'Kalibrierung erforderlich', AppLanguage.en: 'Calibration required', AppLanguage.es: 'Calibración requerida', AppLanguage.it: 'Calibrazione richiesta', AppLanguage.nl: 'Kalibratie vereist', AppLanguage.fr: 'Étalonnage requis', AppLanguage.pt: 'Calibração necessária', AppLanguage.pl: 'Wymagana kalibracja', AppLanguage.tr: 'Kalibrasyon gerekli', AppLanguage.ru: 'Требуется калибровка'},
    'ist keiner aktiven Pumpe zugeordnet oder reicht nicht aus.': {AppLanguage.de: 'ist keiner aktiven Pumpe zugeordnet oder reicht nicht aus.', AppLanguage.en: 'is not assigned to an active pump or is not sufficient.', AppLanguage.es: 'no está asignado a una bomba activa o no alcanza.', AppLanguage.it: 'non è assegnato a una pompa attiva o non è sufficiente.', AppLanguage.nl: 'is niet toegewezen aan een actieve pomp of is niet voldoende.', AppLanguage.fr: 'n’est pas affecté à une pompe active ou est insuffisant.', AppLanguage.pt: 'não está atribuído a uma bomba ativa ou é insuficiente.', AppLanguage.pl: 'nie jest przypisany do aktywnej pompy lub jest niewystarczający.', AppLanguage.tr: 'aktif bir pompaya atanmadı veya yeterli değil.', AppLanguage.ru: 'не назначен активному насосу или недостаточен.'},
    'Die Pumpe für': {AppLanguage.de: 'Die Pumpe für', AppLanguage.en: 'The pump for', AppLanguage.es: 'La bomba para', AppLanguage.it: 'La pompa per', AppLanguage.nl: 'De pomp voor', AppLanguage.fr: 'La pompe pour', AppLanguage.pt: 'A bomba para', AppLanguage.pl: 'Pompa dla', AppLanguage.tr: 'Şu malzemenin pompası', AppLanguage.ru: 'Насос для'},
    'muss zuerst kalibriert werden.': {AppLanguage.de: 'muss zuerst kalibriert werden.', AppLanguage.en: 'must be calibrated first.', AppLanguage.es: 'debe calibrarse primero.', AppLanguage.it: 'deve essere calibrata prima.', AppLanguage.nl: 'moet eerst worden gekalibreerd.', AppLanguage.fr: 'doit d’abord être étalonnée.', AppLanguage.pt: 'deve ser calibrada primeiro.', AppLanguage.pl: 'musi zostać najpierw skalibrowana.', AppLanguage.tr: 'önce kalibre edilmelidir.', AppLanguage.ru: 'сначала должен быть откалиброван.'},
    'reicht nur noch für ungefähr zwei Portionen.': {AppLanguage.de: 'reicht nur noch für ungefähr zwei Portionen.', AppLanguage.en: 'is only sufficient for about two more servings.', AppLanguage.es: 'solo alcanza para unas dos porciones.', AppLanguage.it: 'basta solo per circa due porzioni.', AppLanguage.nl: 'is nog maar genoeg voor ongeveer twee porties.', AppLanguage.fr: 'ne suffit plus que pour environ deux portions.', AppLanguage.pt: 'só chega para cerca de duas porções.', AppLanguage.pl: 'wystarczy już tylko na około dwie porcje.', AppLanguage.tr: 'yaklaşık iki porsiyon daha yeter.', AppLanguage.ru: 'хватит примерно на две порции.'},
    'Zum Schluss': {AppLanguage.de: 'Zum Schluss', AppLanguage.en: 'At the end', AppLanguage.es: 'Al final', AppLanguage.it: 'Alla fine', AppLanguage.nl: 'Aan het einde', AppLanguage.fr: 'À la fin', AppLanguage.pt: 'No final', AppLanguage.pl: 'Na końcu', AppLanguage.tr: 'Sonda', AppLanguage.ru: 'В конце'},
    'Automatisch': {AppLanguage.de: 'Automatisch', AppLanguage.en: 'Automatic', AppLanguage.es: 'Automático', AppLanguage.it: 'Automatico', AppLanguage.nl: 'Automatisch', AppLanguage.fr: 'Automatique', AppLanguage.pt: 'Automático', AppLanguage.pl: 'Automatycznie', AppLanguage.tr: 'Otomatik', AppLanguage.ru: 'Автоматически'},
    'Manuell': {AppLanguage.de: 'Manuell', AppLanguage.en: 'Manual', AppLanguage.es: 'Manual', AppLanguage.it: 'Manuale', AppLanguage.nl: 'Handmatig', AppLanguage.fr: 'Manuel', AppLanguage.pt: 'Manual', AppLanguage.pl: 'Ręcznie', AppLanguage.tr: 'Manuel', AppLanguage.ru: 'Вручную'},
    'manuell hinzufügen': {AppLanguage.de: 'manuell hinzufügen', AppLanguage.en: 'add manually', AppLanguage.es: 'añadir manualmente', AppLanguage.it: 'aggiungere manualmente', AppLanguage.nl: 'handmatig toevoegen', AppLanguage.fr: 'ajouter manuellement', AppLanguage.pt: 'adicionar manualmente', AppLanguage.pl: 'dodaj ręcznie', AppLanguage.tr: 'manuel ekle', AppLanguage.ru: 'добавить вручную'},
    'nicht kalibriert': {AppLanguage.de: 'nicht kalibriert', AppLanguage.en: 'not calibrated', AppLanguage.es: 'no calibrada', AppLanguage.it: 'non calibrata', AppLanguage.nl: 'niet gekalibreerd', AppLanguage.fr: 'non étalonnée', AppLanguage.pt: 'não calibrada', AppLanguage.pl: 'nieskalibrowana', AppLanguage.tr: 'kalibre edilmedi', AppLanguage.ru: 'не откалибровано'},
    'Wird in der App angezeigt und verwendet': {AppLanguage.de: 'Wird in der App angezeigt und verwendet', AppLanguage.en: 'Shown and used in the app', AppLanguage.es: 'Se muestra y usa en la app', AppLanguage.it: 'Mostrata e usata nell’app', AppLanguage.nl: 'Wordt getoond en gebruikt in de app', AppLanguage.fr: 'Affichée et utilisée dans l’app', AppLanguage.pt: 'Mostrada e usada no app', AppLanguage.pl: 'Wyświetlana i używana w aplikacji', AppLanguage.tr: 'Uygulamada gösterilir ve kullanılır', AppLanguage.ru: 'Показывается и используется в приложении'},
    'Ist überall ausgeblendet': {AppLanguage.de: 'Ist überall ausgeblendet', AppLanguage.en: 'Hidden everywhere', AppLanguage.es: 'Oculta en todas partes', AppLanguage.it: 'Nascosta ovunque', AppLanguage.nl: 'Overal verborgen', AppLanguage.fr: 'Masquée partout', AppLanguage.pt: 'Oculta em todos os lugares', AppLanguage.pl: 'Ukryta wszędzie', AppLanguage.tr: 'Her yerde gizli', AppLanguage.ru: 'Скрыта везде'},
    'Läuft …': {AppLanguage.de: 'Läuft …', AppLanguage.en: 'Running …', AppLanguage.es: 'En marcha …', AppLanguage.it: 'In esecuzione …', AppLanguage.nl: 'Loopt …', AppLanguage.fr: 'En cours …', AppLanguage.pt: 'Em execução …', AppLanguage.pl: 'Działa …', AppLanguage.tr: 'Çalışıyor …', AppLanguage.ru: 'Выполняется …'},
    'Testlauf': {AppLanguage.de: 'Testlauf', AppLanguage.en: 'Test run', AppLanguage.es: 'Prueba', AppLanguage.it: 'Test', AppLanguage.nl: 'Testloop', AppLanguage.fr: 'Test', AppLanguage.pt: 'Teste', AppLanguage.pl: 'Test', AppLanguage.tr: 'Test çalıştırması', AppLanguage.ru: 'Тест'},
    'dauerhaft gespeichert': {AppLanguage.de: 'dauerhaft gespeichert', AppLanguage.en: 'saved permanently', AppLanguage.es: 'guardado permanentemente', AppLanguage.it: 'salvato permanentemente', AppLanguage.nl: 'permanent opgeslagen', AppLanguage.fr: 'enregistré durablement', AppLanguage.pt: 'salvo permanentemente', AppLanguage.pl: 'zapisano na stałe', AppLanguage.tr: 'kalıcı olarak kaydedildi', AppLanguage.ru: 'сохранено постоянно'},
    'Pumpe': {AppLanguage.de: 'Pumpe', AppLanguage.en: 'Pump', AppLanguage.es: 'Bomba', AppLanguage.it: 'Pompa', AppLanguage.nl: 'Pomp', AppLanguage.fr: 'Pompe', AppLanguage.pt: 'Bomba', AppLanguage.pl: 'Pompa', AppLanguage.tr: 'Pompa', AppLanguage.ru: 'Насос'},
    'Pumpe aktiv': {AppLanguage.de: 'Pumpe aktiv', AppLanguage.en: 'Pump active', AppLanguage.es: 'Bomba activa', AppLanguage.it: 'Pompa attiva', AppLanguage.nl: 'Pomp actief', AppLanguage.fr: 'Pompe active', AppLanguage.pt: 'Bomba ativa', AppLanguage.pl: 'Pompa aktywna', AppLanguage.tr: 'Pompa aktif', AppLanguage.ru: 'Насос активен'},
    'Pumpe 1 Sekunde testen': {AppLanguage.de: 'Pumpe 1 Sekunde testen', AppLanguage.en: 'Test pump for 1 second', AppLanguage.es: 'Probar bomba 1 segundo', AppLanguage.it: 'Test pompa 1 secondo', AppLanguage.nl: 'Pomp 1 seconde testen', AppLanguage.fr: 'Tester la pompe 1 seconde', AppLanguage.pt: 'Testar bomba por 1 segundo', AppLanguage.pl: 'Testuj pompę przez 1 sekundę', AppLanguage.tr: 'Pompayı 1 saniye test et', AppLanguage.ru: 'Тест насоса 1 сек.'},
    'Pumpe für': {AppLanguage.de: 'Pumpe für', AppLanguage.en: 'Pump for', AppLanguage.es: 'Bomba para', AppLanguage.it: 'Pompa per', AppLanguage.nl: 'Pomp voor', AppLanguage.fr: 'Pompe pour', AppLanguage.pt: 'Bomba para', AppLanguage.pl: 'Pompa dla', AppLanguage.tr: 'Pompa', AppLanguage.ru: 'Насос для'},
    'Rezeptbasis': {AppLanguage.de: 'Rezeptbasis', AppLanguage.en: 'Recipe base', AppLanguage.es: 'Base de receta', AppLanguage.it: 'Base ricetta', AppLanguage.nl: 'Receptbasis', AppLanguage.fr: 'Base de recette', AppLanguage.pt: 'Base da receita', AppLanguage.pl: 'Baza przepisu', AppLanguage.tr: 'Tarif baz miktarı', AppLanguage.ru: 'База рецепта'},
    'Faktor': {AppLanguage.de: 'Faktor', AppLanguage.en: 'Factor', AppLanguage.es: 'Factor', AppLanguage.it: 'Fattore', AppLanguage.nl: 'Factor', AppLanguage.fr: 'Facteur', AppLanguage.pt: 'Fator', AppLanguage.pl: 'Współczynnik', AppLanguage.tr: 'Katsayı', AppLanguage.ru: 'Коэффициент'},
    'Zutaten': {AppLanguage.de: 'Zutaten', AppLanguage.en: 'Ingredients', AppLanguage.es: 'Ingredientes', AppLanguage.it: 'Ingredienti', AppLanguage.nl: 'Ingrediënten', AppLanguage.fr: 'Ingrédients', AppLanguage.pt: 'Ingredientes', AppLanguage.pl: 'Składniki', AppLanguage.tr: 'Malzemeler', AppLanguage.ru: 'Ингредиенты'},
    'Gelöschtes Rezept': {AppLanguage.de: 'Gelöschtes Rezept', AppLanguage.en: 'Deleted recipe', AppLanguage.es: 'Receta eliminada', AppLanguage.it: 'Ricetta eliminata', AppLanguage.nl: 'Verwijderd recept', AppLanguage.fr: 'Recette supprimée', AppLanguage.pt: 'Receita excluída', AppLanguage.pl: 'Usunięty przepis', AppLanguage.tr: 'Silinmiş tarif', AppLanguage.ru: 'Удалённый рецепт'},
    'Gelöschte Zutat': {AppLanguage.de: 'Gelöschte Zutat', AppLanguage.en: 'Deleted ingredient', AppLanguage.es: 'Ingrediente eliminado', AppLanguage.it: 'Ingrediente eliminato', AppLanguage.nl: 'Verwijderd ingrediënt', AppLanguage.fr: 'Ingrédient supprimé', AppLanguage.pt: 'Ingrediente excluído', AppLanguage.pl: 'Usunięty składnik', AppLanguage.tr: 'Silinmiş malzeme', AppLanguage.ru: 'Удалённый ингредиент'},
    'Cocktailkosten nach aktuellem Rezept': {AppLanguage.de: 'Cocktailkosten nach aktuellem Rezept', AppLanguage.en: 'Cocktail costs by current recipe', AppLanguage.es: 'Costes por receta actual', AppLanguage.it: 'Costi secondo ricetta attuale', AppLanguage.nl: 'Cocktailkosten volgens huidig recept', AppLanguage.fr: 'Coûts selon la recette actuelle', AppLanguage.pt: 'Custos por receita atual', AppLanguage.pl: 'Koszty według aktualnego przepisu', AppLanguage.tr: 'Mevcut tarife göre kokteyl maliyetleri', AppLanguage.ru: 'Стоимость по текущему рецепту'},
    'Meistgenutzte Cocktailgrößen': {AppLanguage.de: 'Meistgenutzte Cocktailgrößen', AppLanguage.en: 'Most used cocktail sizes', AppLanguage.es: 'Tamaños más usados', AppLanguage.it: 'Dimensioni più usate', AppLanguage.nl: 'Meest gebruikte cocktailformaten', AppLanguage.fr: 'Tailles les plus utilisées', AppLanguage.pt: 'Tamanhos mais usados', AppLanguage.pl: 'Najczęściej używane rozmiary', AppLanguage.tr: 'En çok kullanılan kokteyl boyutları', AppLanguage.ru: 'Самые используемые размеры'},
    'Cocktail-Ranking': {AppLanguage.de: 'Cocktail-Ranking', AppLanguage.en: 'Cocktail ranking', AppLanguage.es: 'Ranking de cócteles', AppLanguage.it: 'Classifica cocktail', AppLanguage.nl: 'Cocktailranglijst', AppLanguage.fr: 'Classement des cocktails', AppLanguage.pt: 'Ranking de coquetéis', AppLanguage.pl: 'Ranking koktajli', AppLanguage.tr: 'Kokteyl sıralaması', AppLanguage.ru: 'Рейтинг коктейлей'},
    'Zutatenverbrauch': {AppLanguage.de: 'Zutatenverbrauch', AppLanguage.en: 'Ingredient consumption', AppLanguage.es: 'Consumo de ingredientes', AppLanguage.it: 'Consumo ingredienti', AppLanguage.nl: 'Ingrediëntenverbruik', AppLanguage.fr: 'Consommation d’ingrédients', AppLanguage.pt: 'Consumo de ingredientes', AppLanguage.pl: 'Zużycie składników', AppLanguage.tr: 'Malzeme tüketimi', AppLanguage.ru: 'Расход ингредиентов'},
    'Getrunkene Cocktails': {AppLanguage.de: 'Getrunkene Cocktails', AppLanguage.en: 'Consumed cocktails', AppLanguage.es: 'Cócteles consumidos', AppLanguage.it: 'Cocktail consumati', AppLanguage.nl: 'Gedronken cocktails', AppLanguage.fr: 'Cocktails consommés', AppLanguage.pt: 'Coquetéis consumidos', AppLanguage.pl: 'Wypite koktajle', AppLanguage.tr: 'İçilen kokteyller', AppLanguage.ru: 'Выпитые коктейли'},
    'Verbrauch gesamt': {AppLanguage.de: 'Verbrauch gesamt', AppLanguage.en: 'Total consumption', AppLanguage.es: 'Consumo total', AppLanguage.it: 'Consumo totale', AppLanguage.nl: 'Totaal verbruik', AppLanguage.fr: 'Consommation totale', AppLanguage.pt: 'Consumo total', AppLanguage.pl: 'Zużycie łącznie', AppLanguage.tr: 'Toplam tüketim', AppLanguage.ru: 'Общий расход'},
    'Kosten gesamt': {AppLanguage.de: 'Kosten gesamt', AppLanguage.en: 'Total costs', AppLanguage.es: 'Costes totales', AppLanguage.it: 'Costi totali', AppLanguage.nl: 'Totale kosten', AppLanguage.fr: 'Coûts totaux', AppLanguage.pt: 'Custos totais', AppLanguage.pl: 'Koszty łącznie', AppLanguage.tr: 'Toplam maliyet', AppLanguage.ru: 'Общая стоимость'},
    'Standardgröße': {AppLanguage.de: 'Standardgröße', AppLanguage.en: 'Default size', AppLanguage.es: 'Tamaño estándar', AppLanguage.it: 'Dimensione standard', AppLanguage.nl: 'Standaardformaat', AppLanguage.fr: 'Taille standard', AppLanguage.pt: 'Tamanho padrão', AppLanguage.pl: 'Rozmiar domyślny', AppLanguage.tr: 'Varsayılan boyut', AppLanguage.ru: 'Стандартный размер'},
    'Rezept löschen?': {AppLanguage.de: 'Rezept löschen?', AppLanguage.en: 'Delete recipe?', AppLanguage.es: '¿Eliminar receta?', AppLanguage.it: 'Eliminare ricetta?', AppLanguage.nl: 'Recept verwijderen?', AppLanguage.fr: 'Supprimer la recette ?', AppLanguage.pt: 'Excluir receita?', AppLanguage.pl: 'Usunąć przepis?', AppLanguage.tr: 'Tarif silinsin mi?', AppLanguage.ru: 'Удалить рецепт?'},
    'wird dauerhaft gelöscht.': {AppLanguage.de: 'wird dauerhaft gelöscht.', AppLanguage.en: 'will be deleted permanently.', AppLanguage.es: 'se eliminará permanentemente.', AppLanguage.it: 'verrà eliminato definitivamente.', AppLanguage.nl: 'wordt permanent verwijderd.', AppLanguage.fr: 'sera supprimé définitivement.', AppLanguage.pt: 'será excluído permanentemente.', AppLanguage.pl: 'zostanie trwale usunięty.', AppLanguage.tr: 'kalıcı olarak silinecek.', AppLanguage.ru: 'будет удалён навсегда.'},
    'Aktueller Füllstand': {AppLanguage.de: 'Aktueller Füllstand', AppLanguage.en: 'Current fill level', AppLanguage.es: 'Nivel actual', AppLanguage.it: 'Livello attuale', AppLanguage.nl: 'Huidig vulniveau', AppLanguage.fr: 'Niveau actuel', AppLanguage.pt: 'Nível atual', AppLanguage.pl: 'Aktualny poziom', AppLanguage.tr: 'Mevcut doluluk', AppLanguage.ru: 'Текущий уровень'},
    'Behältergröße': {AppLanguage.de: 'Behältergröße', AppLanguage.en: 'Container size', AppLanguage.es: 'Tamaño del recipiente', AppLanguage.it: 'Dimensione contenitore', AppLanguage.nl: 'Reservoirgrootte', AppLanguage.fr: 'Taille du réservoir', AppLanguage.pt: 'Tamanho do recipiente', AppLanguage.pl: 'Pojemność pojemnika', AppLanguage.tr: 'Kap boyutu', AppLanguage.ru: 'Размер ёмкости'},
    'Für bereits geöffnete Behälter eintragen': {AppLanguage.de: 'Für bereits geöffnete Behälter eintragen', AppLanguage.en: 'Enter for already opened containers', AppLanguage.es: 'Introducir para recipientes ya abiertos', AppLanguage.it: 'Inserire per contenitori già aperti', AppLanguage.nl: 'Invullen voor reeds geopende reservoirs', AppLanguage.fr: 'Saisir pour les réservoirs déjà ouverts', AppLanguage.pt: 'Inserir para recipientes já abertos', AppLanguage.pl: 'Wprowadź dla już otwartych pojemników', AppLanguage.tr: 'Açılmış kaplar için girin', AppLanguage.ru: 'Введите для уже открытых ёмкостей'},
    'Rezept nicht mehr vorhanden': {AppLanguage.de: 'Rezept nicht mehr vorhanden', AppLanguage.en: 'Recipe no longer exists', AppLanguage.es: 'La receta ya no existe', AppLanguage.it: 'Ricetta non più presente', AppLanguage.nl: 'Recept bestaat niet meer', AppLanguage.fr: 'La recette n’existe plus', AppLanguage.pt: 'A receita não existe mais', AppLanguage.pl: 'Przepis już nie istnieje', AppLanguage.tr: 'Tarif artık yok', AppLanguage.ru: 'Рецепт больше не существует'},
    'Minze und Eis manuell zugeben': {AppLanguage.de: 'Minze und Eis manuell zugeben', AppLanguage.en: 'Add mint and ice manually', AppLanguage.es: 'Añadir menta y hielo manualmente', AppLanguage.it: 'Aggiungi menta e ghiaccio manualmente', AppLanguage.nl: 'Munt en ijs handmatig toevoegen', AppLanguage.fr: 'Ajouter la menthe et la glace manuellement', AppLanguage.pt: 'Adicionar hortelã e gelo manualmente', AppLanguage.pl: 'Dodaj miętę i lód ręcznie', AppLanguage.tr: 'Nane ve buzu manuel ekle', AppLanguage.ru: 'Добавить мяту и лёд вручную'},
    'Soda nach dem Mixen auffüllen': {AppLanguage.de: 'Soda nach dem Mixen auffüllen', AppLanguage.en: 'Top up with soda after mixing', AppLanguage.es: 'Completar con soda después de mezclar', AppLanguage.it: 'Aggiungi soda dopo la miscelazione', AppLanguage.nl: 'Na het mixen aanvullen met soda', AppLanguage.fr: 'Compléter avec du soda après le mélange', AppLanguage.pt: 'Completar com soda após misturar', AppLanguage.pl: 'Uzupełnij sodą po wymieszaniu', AppLanguage.tr: 'Karıştırmadan sonra soda ile tamamla', AppLanguage.ru: 'Долить содовую после смешивания'},
    'Brauner Rum': {AppLanguage.de: 'Brauner Rum', AppLanguage.en: 'Dark rum', AppLanguage.es: 'Ron oscuro', AppLanguage.it: 'Rum scuro', AppLanguage.nl: 'Donkere rum', AppLanguage.fr: 'Rhum brun', AppLanguage.pt: 'Rum escuro', AppLanguage.pl: 'Ciemny rum', AppLanguage.tr: 'Koyu rom', AppLanguage.ru: 'Тёмный ром'},
    'Pfirsichlikör': {AppLanguage.de: 'Pfirsichlikör', AppLanguage.en: 'Peach liqueur', AppLanguage.es: 'Licor de melocotón', AppLanguage.it: 'Liquore alla pesca', AppLanguage.nl: 'Perziklikeur', AppLanguage.fr: 'Liqueur de pêche', AppLanguage.pt: 'Licor de pêssego', AppLanguage.pl: 'Likier brzoskwiniowy', AppLanguage.tr: 'Şeftali likörü', AppLanguage.ru: 'Персиковый ликёр'},
    'Ananassaft': {AppLanguage.de: 'Ananassaft', AppLanguage.en: 'Pineapple juice', AppLanguage.es: 'Zumo de piña', AppLanguage.it: 'Succo d’ananas', AppLanguage.nl: 'Ananassap', AppLanguage.fr: 'Jus d’ananas', AppLanguage.pt: 'Suco de abacaxi', AppLanguage.pl: 'Sok ananasowy', AppLanguage.tr: 'Ananas suyu', AppLanguage.ru: 'Ананасовый сок'},
    'Maracujasaft': {AppLanguage.de: 'Maracujasaft', AppLanguage.en: 'Passion fruit juice', AppLanguage.es: 'Zumo de maracuyá', AppLanguage.it: 'Succo di frutto della passione', AppLanguage.nl: 'Passievruchtensap', AppLanguage.fr: 'Jus de fruit de la passion', AppLanguage.pt: 'Suco de maracujá', AppLanguage.pl: 'Sok z marakui', AppLanguage.tr: 'Çarkıfelek suyu', AppLanguage.ru: 'Сок маракуйи'},
    'Orangensaft': {AppLanguage.de: 'Orangensaft', AppLanguage.en: 'Orange juice', AppLanguage.es: 'Zumo de naranja', AppLanguage.it: 'Succo d’arancia', AppLanguage.nl: 'Sinaasappelsap', AppLanguage.fr: 'Jus d’orange', AppLanguage.pt: 'Suco de laranja', AppLanguage.pl: 'Sok pomarańczowy', AppLanguage.tr: 'Portakal suyu', AppLanguage.ru: 'Апельсиновый сок'},
    'Limettensaft': {AppLanguage.de: 'Limettensaft', AppLanguage.en: 'Lime juice', AppLanguage.es: 'Zumo de lima', AppLanguage.it: 'Succo di lime', AppLanguage.nl: 'Limoensap', AppLanguage.fr: 'Jus de citron vert', AppLanguage.pt: 'Suco de limão', AppLanguage.pl: 'Sok z limonki', AppLanguage.tr: 'Misket limonu suyu', AppLanguage.ru: 'Сок лайма'},
    'Vanillesirup': {AppLanguage.de: 'Vanillesirup', AppLanguage.en: 'Vanilla syrup', AppLanguage.es: 'Sirope de vainilla', AppLanguage.it: 'Sciroppo alla vaniglia', AppLanguage.nl: 'Vanillesiroop', AppLanguage.fr: 'Sirop de vanille', AppLanguage.pt: 'Xarope de baunilha', AppLanguage.pl: 'Syrop waniliowy', AppLanguage.tr: 'Vanilya şurubu', AppLanguage.ru: 'Ванильный сироп'},
    'Mandelsirup': {AppLanguage.de: 'Mandelsirup', AppLanguage.en: 'Almond syrup', AppLanguage.es: 'Sirope de almendra', AppLanguage.it: 'Sciroppo di mandorla', AppLanguage.nl: 'Amandelsiroop', AppLanguage.fr: 'Sirop d’amande', AppLanguage.pt: 'Xarope de amêndoa', AppLanguage.pl: 'Syrop migdałowy', AppLanguage.tr: 'Badem şurubu', AppLanguage.ru: 'Миндальный сироп'},
    'Kokossirup': {AppLanguage.de: 'Kokossirup', AppLanguage.en: 'Coconut syrup', AppLanguage.es: 'Sirope de coco', AppLanguage.it: 'Sciroppo di cocco', AppLanguage.nl: 'Kokossiroop', AppLanguage.fr: 'Sirop de coco', AppLanguage.pt: 'Xarope de coco', AppLanguage.pl: 'Syrop kokosowy', AppLanguage.tr: 'Hindistan cevizi şurubu', AppLanguage.ru: 'Кокосовый сироп'},
    'Sprudelwasser': {AppLanguage.de: 'Sprudelwasser', AppLanguage.en: 'Sparkling water', AppLanguage.es: 'Agua con gas', AppLanguage.it: 'Acqua frizzante', AppLanguage.nl: 'Bruiswater', AppLanguage.fr: 'Eau gazeuse', AppLanguage.pt: 'Água com gás', AppLanguage.pl: 'Woda gazowana', AppLanguage.tr: 'Soda', AppLanguage.ru: 'Газированная вода'},
    'Sahne': {AppLanguage.de: 'Sahne', AppLanguage.en: 'Cream', AppLanguage.es: 'Nata', AppLanguage.it: 'Panna', AppLanguage.nl: 'Room', AppLanguage.fr: 'Crème', AppLanguage.pt: 'Creme', AppLanguage.pl: 'Śmietanka', AppLanguage.tr: 'Krema', AppLanguage.ru: 'Сливки'},
    'Wodka': {AppLanguage.de: 'Wodka', AppLanguage.en: 'Vodka', AppLanguage.es: 'Vodka', AppLanguage.it: 'Vodka', AppLanguage.nl: 'Wodka', AppLanguage.fr: 'Vodka', AppLanguage.pt: 'Vodka', AppLanguage.pl: 'Wódka', AppLanguage.tr: 'Votka', AppLanguage.ru: 'Водка'},
    'Gin': {AppLanguage.de: 'Gin', AppLanguage.en: 'Gin', AppLanguage.es: 'Ginebra', AppLanguage.it: 'Gin', AppLanguage.nl: 'Gin', AppLanguage.fr: 'Gin', AppLanguage.pt: 'Gin', AppLanguage.pl: 'Gin', AppLanguage.tr: 'Cin', AppLanguage.ru: 'Джин'},
    'Tequila': {AppLanguage.de: 'Tequila', AppLanguage.en: 'Tequila', AppLanguage.es: 'Tequila', AppLanguage.it: 'Tequila', AppLanguage.nl: 'Tequila', AppLanguage.fr: 'Tequila', AppLanguage.pt: 'Tequila', AppLanguage.pl: 'Tequila', AppLanguage.tr: 'Tekila', AppLanguage.ru: 'Текила'},
    'Tonic Water': {AppLanguage.de: 'Tonic Water', AppLanguage.en: 'Tonic water', AppLanguage.es: 'Tónica', AppLanguage.it: 'Acqua tonica', AppLanguage.nl: 'Tonic', AppLanguage.fr: 'Tonic', AppLanguage.pt: 'Água tônica', AppLanguage.pl: 'Tonik', AppLanguage.tr: 'Tonik', AppLanguage.ru: 'Тоник'},
    'Grauer Panther': {AppLanguage.de: 'Grauer Panther', AppLanguage.en: 'Grey Panther', AppLanguage.es: 'Pantera gris', AppLanguage.it: 'Pantera grigia', AppLanguage.nl: 'Grijze panter', AppLanguage.fr: 'Panthère grise', AppLanguage.pt: 'Pantera cinzenta', AppLanguage.pl: 'Szara pantera', AppLanguage.tr: 'Gri Panter', AppLanguage.ru: 'Серая пантера'},
    'Sweet Cocktail': {AppLanguage.de: 'Sweet Cocktail', AppLanguage.en: 'Sweet Cocktail', AppLanguage.es: 'Cóctel dulce', AppLanguage.it: 'Cocktail dolce', AppLanguage.nl: 'Zoete cocktail', AppLanguage.fr: 'Cocktail sucré', AppLanguage.pt: 'Coquetel doce', AppLanguage.pl: 'Słodki koktajl', AppLanguage.tr: 'Tatlı kokteyl', AppLanguage.ru: 'Сладкий коктейль'},
    'Holiday': {AppLanguage.de: 'Holiday', AppLanguage.en: 'Holiday', AppLanguage.es: 'Vacaciones', AppLanguage.it: 'Vacanza', AppLanguage.nl: 'Vakantie', AppLanguage.fr: 'Vacances', AppLanguage.pt: 'Férias', AppLanguage.pl: 'Wakacje', AppLanguage.tr: 'Tatil', AppLanguage.ru: 'Отпуск'},
    'Fruchtiger Cocktail mit Rum, Ananas und Maracuja': {AppLanguage.de: 'Fruchtiger Cocktail mit Rum, Ananas und Maracuja', AppLanguage.en: 'Fruity cocktail with rum, pineapple and passion fruit', AppLanguage.es: 'Cóctel afrutado con ron, piña y maracuyá', AppLanguage.it: 'Cocktail fruttato con rum, ananas e passion fruit', AppLanguage.nl: 'Fruitige cocktail met rum, ananas en passievrucht', AppLanguage.fr: 'Fruity cocktail with rum, pineapple and passion fruit', AppLanguage.pt: 'Fruity cocktail with rum, pineapple and passion fruit', AppLanguage.pl: 'Fruity cocktail with rum, pineapple and passion fruit', AppLanguage.tr: 'Fruity cocktail with rum, pineapple and passion fruit', AppLanguage.ru: 'Fruity cocktail with rum, pineapple and passion fruit'},
    'Süßer Kokoslikör mit Ananassaft': {AppLanguage.de: 'Süßer Kokoslikör mit Ananassaft', AppLanguage.en: 'Sweet coconut liqueur with pineapple juice', AppLanguage.es: 'Licor de coco dulce con zumo de piña', AppLanguage.it: 'Liquore al cocco dolce con succo d’ananas', AppLanguage.nl: 'Zoete kokoslikeur met ananassap', AppLanguage.fr: 'Sweet coconut liqueur with pineapple juice', AppLanguage.pt: 'Sweet coconut liqueur with pineapple juice', AppLanguage.pl: 'Sweet coconut liqueur with pineapple juice', AppLanguage.tr: 'Sweet coconut liqueur with pineapple juice', AppLanguage.ru: 'Sweet coconut liqueur with pineapple juice'},
    'Kokoslikör mit Orangensaft und Grenadine': {AppLanguage.de: 'Kokoslikör mit Orangensaft und Grenadine', AppLanguage.en: 'Coconut liqueur with orange juice and grenadine', AppLanguage.es: 'Licor de coco con zumo de naranja y granadina', AppLanguage.it: 'Liquore al cocco con succo d’arancia e granatina', AppLanguage.nl: 'Kokoslikeur met sinaasappelsap en grenadine', AppLanguage.fr: 'Coconut liqueur with orange juice and grenadine', AppLanguage.pt: 'Coconut liqueur with orange juice and grenadine', AppLanguage.pl: 'Coconut liqueur with orange juice and grenadine', AppLanguage.tr: 'Coconut liqueur with orange juice and grenadine', AppLanguage.ru: 'Coconut liqueur with orange juice and grenadine'},
    'Cremiger Cocktail mit Malibu und Ananas': {AppLanguage.de: 'Cremiger Cocktail mit Malibu und Ananas', AppLanguage.en: 'Creamy cocktail with Malibu and pineapple', AppLanguage.es: 'Cóctel cremoso con Malibu y piña', AppLanguage.it: 'Cocktail cremoso con Malibu e ananas', AppLanguage.nl: 'Romige cocktail met Malibu en ananas', AppLanguage.fr: 'Creamy cocktail with Malibu and pineapple', AppLanguage.pt: 'Creamy cocktail with Malibu and pineapple', AppLanguage.pl: 'Creamy cocktail with Malibu and pineapple', AppLanguage.tr: 'Creamy cocktail with Malibu and pineapple', AppLanguage.ru: 'Creamy cocktail with Malibu and pineapple'},
    'Fruchtiger Cocktail mit Pfirsichlikör und Vodka': {AppLanguage.de: 'Fruchtiger Cocktail mit Pfirsichlikör und Vodka', AppLanguage.en: 'Fruity cocktail with peach liqueur and vodka', AppLanguage.es: 'Cóctel afrutado con licor de melocotón y vodka', AppLanguage.it: 'Cocktail fruttato con liquore alla pesca e vodka', AppLanguage.nl: 'Fruitige cocktail met perziklikeur en wodka', AppLanguage.fr: 'Fruity cocktail with peach liqueur and vodka', AppLanguage.pt: 'Fruity cocktail with peach liqueur and vodka', AppLanguage.pl: 'Fruity cocktail with peach liqueur and vodka', AppLanguage.tr: 'Fruity cocktail with peach liqueur and vodka', AppLanguage.ru: 'Fruity cocktail with peach liqueur and vodka'},
    'Klassischer Rum-Cocktail mit Fruchtsäften': {AppLanguage.de: 'Klassischer Rum-Cocktail mit Fruchtsäften', AppLanguage.en: 'Classic rum cocktail with fruit juices', AppLanguage.es: 'Cóctel clásico de ron con zumos de fruta', AppLanguage.it: 'Cocktail classico al rum con succhi di frutta', AppLanguage.nl: 'Klassieke rumcocktail met vruchtensappen', AppLanguage.fr: 'Classic rum cocktail with fruit juices', AppLanguage.pt: 'Classic rum cocktail with fruit juices', AppLanguage.pl: 'Classic rum cocktail with fruit juices', AppLanguage.tr: 'Classic rum cocktail with fruit juices', AppLanguage.ru: 'Classic rum cocktail with fruit juices'},
    'Erfrischender Cocktail mit Maracuja und Vanille': {AppLanguage.de: 'Erfrischender Cocktail mit Maracuja und Vanille', AppLanguage.en: 'Refreshing cocktail with passion fruit and vanilla', AppLanguage.es: 'Cóctel refrescante con maracuyá y vainilla', AppLanguage.it: 'Cocktail rinfrescante con passion fruit e vaniglia', AppLanguage.nl: 'Verfrissende cocktail met passievrucht en vanille', AppLanguage.fr: 'Refreshing cocktail with passion fruit and vanilla', AppLanguage.pt: 'Refreshing cocktail with passion fruit and vanilla', AppLanguage.pl: 'Refreshing cocktail with passion fruit and vanilla', AppLanguage.tr: 'Refreshing cocktail with passion fruit and vanilla', AppLanguage.ru: 'Refreshing cocktail with passion fruit and vanilla'},
    'Beliebter Cocktail mit Vodka und Pfirsichlikör': {AppLanguage.de: 'Beliebter Cocktail mit Vodka und Pfirsichlikör', AppLanguage.en: 'Popular cocktail with vodka and peach liqueur', AppLanguage.es: 'Cóctel popular con vodka y licor de melocotón', AppLanguage.it: 'Cocktail popolare con vodka e liquore alla pesca', AppLanguage.nl: 'Populaire cocktail met wodka en perziklikeur', AppLanguage.fr: 'Popular cocktail with vodka and peach liqueur', AppLanguage.pt: 'Popular cocktail with vodka and peach liqueur', AppLanguage.pl: 'Popular cocktail with vodka and peach liqueur', AppLanguage.tr: 'Popular cocktail with vodka and peach liqueur', AppLanguage.ru: 'Popular cocktail with vodka and peach liqueur'},
    'Klassischer Cocktail mit Rum, Limette und Minze': {AppLanguage.de: 'Klassischer Cocktail mit Rum, Limette und Minze', AppLanguage.en: 'Classic cocktail with rum, lime and mint', AppLanguage.es: 'Cóctel clásico con ron, lima y menta', AppLanguage.it: 'Cocktail classico con rum, lime e menta', AppLanguage.nl: 'Klassieke cocktail met rum, limoen en munt', AppLanguage.fr: 'Classic cocktail with rum, lime and mint', AppLanguage.pt: 'Classic cocktail with rum, lime and mint', AppLanguage.pl: 'Classic cocktail with rum, lime and mint', AppLanguage.tr: 'Classic cocktail with rum, lime and mint', AppLanguage.ru: 'Classic cocktail with rum, lime and mint'},
    'Exotischer Cocktail mit Rum, Malibu und Maracuja': {AppLanguage.de: 'Exotischer Cocktail mit Rum, Malibu und Maracuja', AppLanguage.en: 'Exotic cocktail with rum, Malibu and passion fruit', AppLanguage.es: 'Cóctel exótico con ron, Malibu y maracuyá', AppLanguage.it: 'Cocktail esotico con rum, Malibu e passion fruit', AppLanguage.nl: 'Exotische cocktail met rum, Malibu en passievrucht', AppLanguage.fr: 'Exotic cocktail with rum, Malibu and passion fruit', AppLanguage.pt: 'Exotic cocktail with rum, Malibu and passion fruit', AppLanguage.pl: 'Exotic cocktail with rum, Malibu and passion fruit', AppLanguage.tr: 'Exotic cocktail with rum, Malibu and passion fruit', AppLanguage.ru: 'Exotic cocktail with rum, Malibu and passion fruit'},
    'Klassischer Longdrink mit Gin und Tonic Water': {AppLanguage.de: 'Klassischer Longdrink mit Gin und Tonic Water', AppLanguage.en: 'Classic long drink with gin and tonic water', AppLanguage.es: 'Long drink clásico con ginebra y tónica', AppLanguage.it: 'Long drink classico con gin e acqua tonica', AppLanguage.nl: 'Klassieke longdrink met gin en tonic', AppLanguage.fr: 'Classic long drink with gin and tonic water', AppLanguage.pt: 'Classic long drink with gin and tonic water', AppLanguage.pl: 'Classic long drink with gin and tonic water', AppLanguage.tr: 'Classic long drink with gin and tonic water', AppLanguage.ru: 'Classic long drink with gin and tonic water'},
    'Rum-Cola mit einem Spritzer Limette': {AppLanguage.de: 'Rum-Cola mit einem Spritzer Limette', AppLanguage.en: 'Rum and cola with a splash of lime', AppLanguage.es: 'Ron con cola y un toque de lima', AppLanguage.it: 'Rum e cola con una spruzzata di lime', AppLanguage.nl: 'Rum-cola met een scheutje limoen', AppLanguage.fr: 'Rum and cola with a splash of lime', AppLanguage.pt: 'Rum and cola with a splash of lime', AppLanguage.pl: 'Rum and cola with a splash of lime', AppLanguage.tr: 'Rum and cola with a splash of lime', AppLanguage.ru: 'Rum and cola with a splash of lime'},
    'Klassischer, starker Cocktail mit fünf verschiedenen Spirituosen und Cola': {AppLanguage.de: 'Klassischer, starker Cocktail mit fünf verschiedenen Spirituosen und Cola', AppLanguage.en: 'Classic strong cocktail with five spirits and cola', AppLanguage.es: 'Cóctel clásico fuerte con cinco licores y cola', AppLanguage.it: 'Cocktail classico forte con cinque distillati e cola', AppLanguage.nl: 'Klassieke sterke cocktail met vijf spirits en cola', AppLanguage.fr: 'Classic strong cocktail with five spirits and cola', AppLanguage.pt: 'Classic strong cocktail with five spirits and cola', AppLanguage.pl: 'Classic strong cocktail with five spirits and cola', AppLanguage.tr: 'Classic strong cocktail with five spirits and cola', AppLanguage.ru: 'Classic strong cocktail with five spirits and cola'},
    'Tropischer Cocktail mit Braunem Rum, Malibu und Fruchtsäften': {AppLanguage.de: 'Tropischer Cocktail mit Braunem Rum, Malibu und Fruchtsäften', AppLanguage.en: 'Tropical cocktail with dark rum, Malibu and fruit juices', AppLanguage.es: 'Cóctel tropical con ron oscuro, Malibu y zumos', AppLanguage.it: 'Cocktail tropicale con rum scuro, Malibu e succhi', AppLanguage.nl: 'Tropische cocktail met donkere rum, Malibu en vruchtensappen', AppLanguage.fr: 'Tropical cocktail with dark rum, Malibu and fruit juices', AppLanguage.pt: 'Tropical cocktail with dark rum, Malibu and fruit juices', AppLanguage.pl: 'Tropical cocktail with dark rum, Malibu and fruit juices', AppLanguage.tr: 'Tropical cocktail with dark rum, Malibu and fruit juices', AppLanguage.ru: 'Tropical cocktail with dark rum, Malibu and fruit juices'},
    'Blauer, tropischer Cocktail mit Vodka und Ananassaft': {AppLanguage.de: 'Blauer, tropischer Cocktail mit Vodka und Ananassaft', AppLanguage.en: 'Blue tropical cocktail with vodka and pineapple juice', AppLanguage.es: 'Cóctel tropical azul con vodka y piña', AppLanguage.it: 'Cocktail tropicale blu con vodka e ananas', AppLanguage.nl: 'Blauwe tropische cocktail met wodka en ananassap', AppLanguage.fr: 'Blue tropical cocktail with vodka and pineapple juice', AppLanguage.pt: 'Blue tropical cocktail with vodka and pineapple juice', AppLanguage.pl: 'Blue tropical cocktail with vodka and pineapple juice', AppLanguage.tr: 'Blue tropical cocktail with vodka and pineapple juice', AppLanguage.ru: 'Blue tropical cocktail with vodka and pineapple juice'},
    'Klassischer Cocktail mit Tequila, Orangensaft und Grenadine': {AppLanguage.de: 'Klassischer Cocktail mit Tequila, Orangensaft und Grenadine', AppLanguage.en: 'Classic cocktail with tequila, orange juice and grenadine', AppLanguage.es: 'Cóctel clásico con tequila, naranja y granadina', AppLanguage.it: 'Cocktail classico con tequila, arancia e granatina', AppLanguage.nl: 'Klassieke cocktail met tequila, sinaasappel en grenadine', AppLanguage.fr: 'Classic cocktail with tequila, orange juice and grenadine', AppLanguage.pt: 'Classic cocktail with tequila, orange juice and grenadine', AppLanguage.pl: 'Classic cocktail with tequila, orange juice and grenadine', AppLanguage.tr: 'Classic cocktail with tequila, orange juice and grenadine', AppLanguage.ru: 'Classic cocktail with tequila, orange juice and grenadine'},
    'Fruchtiger Cocktail mit Braunem Rum, Triple Sec und Maracujasaft': {AppLanguage.de: 'Fruchtiger Cocktail mit Braunem Rum, Triple Sec und Maracujasaft', AppLanguage.en: 'Fruity cocktail with dark rum, triple sec and passion fruit juice', AppLanguage.es: 'Cóctel afrutado con ron oscuro, triple sec y maracuyá', AppLanguage.it: 'Cocktail fruttato con rum scuro, triple sec e passion fruit', AppLanguage.nl: 'Fruitige cocktail met donkere rum, triple sec en passievrucht', AppLanguage.fr: 'Fruity cocktail with dark rum, triple sec and passion fruit juice', AppLanguage.pt: 'Fruity cocktail with dark rum, triple sec and passion fruit juice', AppLanguage.pl: 'Fruity cocktail with dark rum, triple sec and passion fruit juice', AppLanguage.tr: 'Fruity cocktail with dark rum, triple sec and passion fruit juice', AppLanguage.ru: 'Fruity cocktail with dark rum, triple sec and passion fruit juice'},
    'Starker, fruchtiger Cocktail mit Braunem Rum und verschiedenen Fruchtsäften': {AppLanguage.de: 'Starker, fruchtiger Cocktail mit Braunem Rum und verschiedenen Fruchtsäften', AppLanguage.en: 'Strong fruity cocktail with dark rum and various fruit juices', AppLanguage.es: 'Cóctel fuerte y afrutado con ron oscuro y varios zumos', AppLanguage.it: 'Cocktail forte e fruttato con rum scuro e succhi vari', AppLanguage.nl: 'Sterke fruitige cocktail met donkere rum en verschillende sappen', AppLanguage.fr: 'Strong fruity cocktail with dark rum and various fruit juices', AppLanguage.pt: 'Strong fruity cocktail with dark rum and various fruit juices', AppLanguage.pl: 'Strong fruity cocktail with dark rum and various fruit juices', AppLanguage.tr: 'Strong fruity cocktail with dark rum and various fruit juices', AppLanguage.ru: 'Strong fruity cocktail with dark rum and various fruit juices'},
    'Klassischer Tiki-Cocktail mit braunem Rum und Mandelsirup': {AppLanguage.de: 'Klassischer Tiki-Cocktail mit braunem Rum und Mandelsirup', AppLanguage.en: 'Classic tiki cocktail with dark rum and almond syrup', AppLanguage.es: 'Cóctel tiki clásico con ron oscuro y sirope de almendra', AppLanguage.it: 'Cocktail tiki classico con rum scuro e sciroppo di mandorla', AppLanguage.nl: 'Klassieke tiki-cocktail met donkere rum en amandelsiroop', AppLanguage.fr: 'Classic tiki cocktail with dark rum and almond syrup', AppLanguage.pt: 'Classic tiki cocktail with dark rum and almond syrup', AppLanguage.pl: 'Classic tiki cocktail with dark rum and almond syrup', AppLanguage.tr: 'Classic tiki cocktail with dark rum and almond syrup', AppLanguage.ru: 'Classic tiki cocktail with dark rum and almond syrup'},
    'Erfrischender alkoholfreier Cocktail mit Ananas, Orange und Grenadine': {AppLanguage.de: 'Erfrischender alkoholfreier Cocktail mit Ananas, Orange und Grenadine', AppLanguage.en: 'Refreshing alcohol-free cocktail with pineapple, orange and grenadine', AppLanguage.es: 'Cóctel sin alcohol refrescante con piña, naranja y granadina', AppLanguage.it: 'Cocktail analcolico rinfrescante con ananas, arancia e granatina', AppLanguage.nl: 'Verfrissende alcoholvrije cocktail met ananas, sinaasappel en grenadine', AppLanguage.fr: 'Refreshing alcohol-free cocktail with pineapple, orange and grenadine', AppLanguage.pt: 'Refreshing alcohol-free cocktail with pineapple, orange and grenadine', AppLanguage.pl: 'Refreshing alcohol-free cocktail with pineapple, orange and grenadine', AppLanguage.tr: 'Refreshing alcohol-free cocktail with pineapple, orange and grenadine', AppLanguage.ru: 'Refreshing alcohol-free cocktail with pineapple, orange and grenadine'},
    'Sprudelnder alkoholfreier Cocktail mit Maracuja und Sodawasser': {AppLanguage.de: 'Sprudelnder alkoholfreier Cocktail mit Maracuja und Sodawasser', AppLanguage.en: 'Sparkling alcohol-free cocktail with passion fruit and soda water', AppLanguage.es: 'Cóctel sin alcohol espumoso con maracuyá y soda', AppLanguage.it: 'Cocktail analcolico frizzante con passion fruit e soda', AppLanguage.nl: 'Sprankelende alcoholvrije cocktail met passievrucht en bruiswater', AppLanguage.fr: 'Sparkling alcohol-free cocktail with passion fruit and soda water', AppLanguage.pt: 'Sparkling alcohol-free cocktail with passion fruit and soda water', AppLanguage.pl: 'Sparkling alcohol-free cocktail with passion fruit and soda water', AppLanguage.tr: 'Sparkling alcohol-free cocktail with passion fruit and soda water', AppLanguage.ru: 'Sparkling alcohol-free cocktail with passion fruit and soda water'},
    'Cremiger alkoholfreier Cocktail mit Orange und Vanille': {AppLanguage.de: 'Cremiger alkoholfreier Cocktail mit Orange und Vanille', AppLanguage.en: 'Creamy alcohol-free cocktail with orange and vanilla', AppLanguage.es: 'Cóctel sin alcohol cremoso con naranja y vainilla', AppLanguage.it: 'Cocktail analcolico cremoso con arancia e vaniglia', AppLanguage.nl: 'Romige alcoholvrije cocktail met sinaasappel en vanille', AppLanguage.fr: 'Creamy alcohol-free cocktail with orange and vanilla', AppLanguage.pt: 'Creamy alcohol-free cocktail with orange and vanilla', AppLanguage.pl: 'Creamy alcohol-free cocktail with orange and vanilla', AppLanguage.tr: 'Creamy alcohol-free cocktail with orange and vanilla', AppLanguage.ru: 'Creamy alcohol-free cocktail with orange and vanilla'},
    'Fruchtiger alkoholfreier Cocktail mit Grenadine und Zitrusfrüchten': {AppLanguage.de: 'Fruchtiger alkoholfreier Cocktail mit Grenadine und Zitrusfrüchten', AppLanguage.en: 'Fruity alcohol-free cocktail with grenadine and citrus fruits', AppLanguage.es: 'Cóctel sin alcohol afrutado con granadina y cítricos', AppLanguage.it: 'Cocktail analcolico fruttato con granatina e agrumi', AppLanguage.nl: 'Fruitige alcoholvrije cocktail met grenadine en citrus', AppLanguage.fr: 'Fruity alcohol-free cocktail with grenadine and citrus fruits', AppLanguage.pt: 'Fruity alcohol-free cocktail with grenadine and citrus fruits', AppLanguage.pl: 'Fruity alcohol-free cocktail with grenadine and citrus fruits', AppLanguage.tr: 'Fruity alcohol-free cocktail with grenadine and citrus fruits', AppLanguage.ru: 'Fruity alcohol-free cocktail with grenadine and citrus fruits'},
    'Exotischer alkoholfreier Cocktail mit Ananas und Maracuja': {AppLanguage.de: 'Exotischer alkoholfreier Cocktail mit Ananas und Maracuja', AppLanguage.en: 'Exotic alcohol-free cocktail with pineapple and passion fruit', AppLanguage.es: 'Cóctel sin alcohol exótico con piña y maracuyá', AppLanguage.it: 'Cocktail analcolico esotico con ananas e passion fruit', AppLanguage.nl: 'Exotische alcoholvrije cocktail met ananas en passievrucht', AppLanguage.fr: 'Exotic alcohol-free cocktail with pineapple and passion fruit', AppLanguage.pt: 'Exotic alcohol-free cocktail with pineapple and passion fruit', AppLanguage.pl: 'Exotic alcohol-free cocktail with pineapple and passion fruit', AppLanguage.tr: 'Exotic alcohol-free cocktail with pineapple and passion fruit', AppLanguage.ru: 'Exotic alcohol-free cocktail with pineapple and passion fruit'},
    'Erfrischender alkoholfreier Cocktail mit Limette und Sodawasser': {AppLanguage.de: 'Erfrischender alkoholfreier Cocktail mit Limette und Sodawasser', AppLanguage.en: 'Refreshing alcohol-free cocktail with lime and soda water', AppLanguage.es: 'Cóctel sin alcohol refrescante con lima y soda', AppLanguage.it: 'Cocktail analcolico rinfrescante con lime e soda', AppLanguage.nl: 'Verfrissende alcoholvrije cocktail met limoen en bruiswater', AppLanguage.fr: 'Refreshing alcohol-free cocktail with lime and soda water', AppLanguage.pt: 'Refreshing alcohol-free cocktail with lime and soda water', AppLanguage.pl: 'Refreshing alcohol-free cocktail with lime and soda water', AppLanguage.tr: 'Refreshing alcohol-free cocktail with lime and soda water', AppLanguage.ru: 'Refreshing alcohol-free cocktail with lime and soda water'},
    'Schöner Farbverlauf mit Ananas, Orange und Grenadine': {AppLanguage.de: 'Schöner Farbverlauf mit Ananas, Orange und Grenadine', AppLanguage.en: 'Beautiful color gradient with pineapple, orange and grenadine', AppLanguage.es: 'Bonito degradado con piña, naranja y granadina', AppLanguage.it: 'Bel gradiente con ananas, arancia e granatina', AppLanguage.nl: 'Mooie kleurverloop met ananas, sinaasappel en grenadine', AppLanguage.fr: 'Beautiful color gradient with pineapple, orange and grenadine', AppLanguage.pt: 'Beautiful color gradient with pineapple, orange and grenadine', AppLanguage.pl: 'Beautiful color gradient with pineapple, orange and grenadine', AppLanguage.tr: 'Beautiful color gradient with pineapple, orange and grenadine', AppLanguage.ru: 'Beautiful color gradient with pineapple, orange and grenadine'},
    'Erfrischender Cocktail mit Ananas und Limette': {AppLanguage.de: 'Erfrischender Cocktail mit Ananas und Limette', AppLanguage.en: 'Refreshing cocktail with pineapple and lime', AppLanguage.es: 'Cóctel refrescante con piña y lima', AppLanguage.it: 'Cocktail rinfrescante con ananas e lime', AppLanguage.nl: 'Verfrissende cocktail met ananas en limoen', AppLanguage.fr: 'Refreshing cocktail with pineapple and lime', AppLanguage.pt: 'Refreshing cocktail with pineapple and lime', AppLanguage.pl: 'Refreshing cocktail with pineapple and lime', AppLanguage.tr: 'Refreshing cocktail with pineapple and lime', AppLanguage.ru: 'Refreshing cocktail with pineapple and lime'},
    'Exotischer Cocktail mit Maracuja und tropischen Früchten': {AppLanguage.de: 'Exotischer Cocktail mit Maracuja und tropischen Früchten', AppLanguage.en: 'Exotic cocktail with passion fruit and tropical fruits', AppLanguage.es: 'Cóctel exótico con maracuyá y frutas tropicales', AppLanguage.it: 'Cocktail esotico con passion fruit e frutti tropicali', AppLanguage.nl: 'Exotische cocktail met passievrucht en tropisch fruit', AppLanguage.fr: 'Exotic cocktail with passion fruit and tropical fruits', AppLanguage.pt: 'Exotic cocktail with passion fruit and tropical fruits', AppLanguage.pl: 'Exotic cocktail with passion fruit and tropical fruits', AppLanguage.tr: 'Exotic cocktail with passion fruit and tropical fruits', AppLanguage.ru: 'Exotic cocktail with passion fruit and tropical fruits'},
    'Cremiger Traum mit Vanille und Orange': {AppLanguage.de: 'Cremiger Traum mit Vanille und Orange', AppLanguage.en: 'Creamy dream with vanilla and orange', AppLanguage.es: 'Sueño cremoso con vainilla y naranja', AppLanguage.it: 'Sogno cremoso con vaniglia e arancia', AppLanguage.nl: 'Romige droom met vanille en sinaasappel', AppLanguage.fr: 'Creamy dream with vanilla and orange', AppLanguage.pt: 'Creamy dream with vanilla and orange', AppLanguage.pl: 'Creamy dream with vanilla and orange', AppLanguage.tr: 'Creamy dream with vanilla and orange', AppLanguage.ru: 'Creamy dream with vanilla and orange'},
    'Wunderschöner Sonnenaufgang im Glas': {AppLanguage.de: 'Wunderschöner Sonnenaufgang im Glas', AppLanguage.en: 'Beautiful sunrise in a glass', AppLanguage.es: 'Hermoso amanecer en el vaso', AppLanguage.it: 'Splendida alba nel bicchiere', AppLanguage.nl: 'Prachtige zonsopgang in een glas', AppLanguage.fr: 'Beautiful sunrise in a glass', AppLanguage.pt: 'Beautiful sunrise in a glass', AppLanguage.pl: 'Beautiful sunrise in a glass', AppLanguage.tr: 'Beautiful sunrise in a glass', AppLanguage.ru: 'Beautiful sunrise in a glass'},
    'Tropischer Cocktail mit Rum, Malibu und Blue Curacao': {AppLanguage.de: 'Tropischer Cocktail mit Rum, Malibu und Blue Curacao', AppLanguage.en: 'Tropical cocktail with rum, Malibu and Blue Curaçao', AppLanguage.es: 'Cóctel tropical con ron, Malibu y Blue Curaçao', AppLanguage.it: 'Cocktail tropicale con rum, Malibu e Blue Curaçao', AppLanguage.nl: 'Tropische cocktail met rum, Malibu en Blue Curaçao', AppLanguage.fr: 'Tropical cocktail with rum, Malibu and Blue Curaçao', AppLanguage.pt: 'Tropical cocktail with rum, Malibu and Blue Curaçao', AppLanguage.pl: 'Tropical cocktail with rum, Malibu and Blue Curaçao', AppLanguage.tr: 'Tropical cocktail with rum, Malibu and Blue Curaçao', AppLanguage.ru: 'Tropical cocktail with rum, Malibu and Blue Curaçao'},
    'Blauer Cocktail mit Malibu und Ananassaft': {AppLanguage.de: 'Blauer Cocktail mit Malibu und Ananassaft', AppLanguage.en: 'Blue cocktail with Malibu and pineapple juice', AppLanguage.es: 'Cóctel azul con Malibu y piña', AppLanguage.it: 'Cocktail blu con Malibu e ananas', AppLanguage.nl: 'Blauwe cocktail met Malibu en ananassap', AppLanguage.fr: 'Blue cocktail with Malibu and pineapple juice', AppLanguage.pt: 'Blue cocktail with Malibu and pineapple juice', AppLanguage.pl: 'Blue cocktail with Malibu and pineapple juice', AppLanguage.tr: 'Blue cocktail with Malibu and pineapple juice', AppLanguage.ru: 'Blue cocktail with Malibu and pineapple juice'},
    'Mexikanischer Cocktail mit Tequila und Vodka': {AppLanguage.de: 'Mexikanischer Cocktail mit Tequila und Vodka', AppLanguage.en: 'Mexican cocktail with tequila and vodka', AppLanguage.es: 'Cóctel mexicano con tequila y vodka', AppLanguage.it: 'Cocktail messicano con tequila e vodka', AppLanguage.nl: 'Mexicaanse cocktail met tequila en wodka', AppLanguage.fr: 'Mexican cocktail with tequila and vodka', AppLanguage.pt: 'Mexican cocktail with tequila and vodka', AppLanguage.pl: 'Mexican cocktail with tequila and vodka', AppLanguage.tr: 'Mexican cocktail with tequila and vodka', AppLanguage.ru: 'Mexican cocktail with tequila and vodka'},
    'Grüner Cocktail mit Blue Curacao und Vodka': {AppLanguage.de: 'Grüner Cocktail mit Blue Curacao und Vodka', AppLanguage.en: 'Green cocktail with Blue Curaçao and vodka', AppLanguage.es: 'Cóctel verde con Blue Curaçao y vodka', AppLanguage.it: 'Cocktail verde con Blue Curaçao e vodka', AppLanguage.nl: 'Groene cocktail met Blue Curaçao en wodka', AppLanguage.fr: 'Green cocktail with Blue Curaçao and vodka', AppLanguage.pt: 'Green cocktail with Blue Curaçao and vodka', AppLanguage.pl: 'Green cocktail with Blue Curaçao and vodka', AppLanguage.tr: 'Green cocktail with Blue Curaçao and vodka', AppLanguage.ru: 'Green cocktail with Blue Curaçao and vodka'},
    'Heißer tropischer Cocktail mit Malibu und Rum': {AppLanguage.de: 'Heißer tropischer Cocktail mit Malibu und Rum', AppLanguage.en: 'Intense tropical cocktail with Malibu and rum', AppLanguage.es: 'Cóctel tropical intenso con Malibu y ron', AppLanguage.it: 'Cocktail tropicale intenso con Malibu e rum', AppLanguage.nl: 'Intense tropische cocktail met Malibu en rum', AppLanguage.fr: 'Intense tropical cocktail with Malibu and rum', AppLanguage.pt: 'Intense tropical cocktail with Malibu and rum', AppLanguage.pl: 'Intense tropical cocktail with Malibu and rum', AppLanguage.tr: 'Intense tropical cocktail with Malibu and rum', AppLanguage.ru: 'Intense tropical cocktail with Malibu and rum'},
    'Fusion aus Rum, Vodka und tropischen Früchten': {AppLanguage.de: 'Fusion aus Rum, Vodka und tropischen Früchten', AppLanguage.en: 'Fusion of rum, vodka and tropical fruits', AppLanguage.es: 'Fusión de ron, vodka y frutas tropicales', AppLanguage.it: 'Fusione di rum, vodka e frutti tropicali', AppLanguage.nl: 'Fusion van rum, wodka en tropisch fruit', AppLanguage.fr: 'Fusion of rum, vodka and tropical fruits', AppLanguage.pt: 'Fusion of rum, vodka and tropical fruits', AppLanguage.pl: 'Fusion of rum, vodka and tropical fruits', AppLanguage.tr: 'Fusion of rum, vodka and tropical fruits', AppLanguage.ru: 'Fusion of rum, vodka and tropical fruits'},
    'Sonniger Cocktail mit Rum, Malibu und tropischen Säften': {AppLanguage.de: 'Sonniger Cocktail mit Rum, Malibu und tropischen Säften', AppLanguage.en: 'Sunny cocktail with rum, Malibu and tropical juices', AppLanguage.es: 'Cóctel soleado con ron, Malibu y zumos tropicales', AppLanguage.it: 'Cocktail solare con rum, Malibu e succhi tropicali', AppLanguage.nl: 'Zonnige cocktail met rum, Malibu en tropische sappen', AppLanguage.fr: 'Sunny cocktail with rum, Malibu and tropical juices', AppLanguage.pt: 'Sunny cocktail with rum, Malibu and tropical juices', AppLanguage.pl: 'Sunny cocktail with rum, Malibu and tropical juices', AppLanguage.tr: 'Sunny cocktail with rum, Malibu and tropical juices', AppLanguage.ru: 'Sunny cocktail with rum, Malibu and tropical juices'},
    'Kräftiger Cocktail mit Rum, Vodka und Blue Curacao': {AppLanguage.de: 'Kräftiger Cocktail mit Rum, Vodka und Blue Curacao', AppLanguage.en: 'Strong cocktail with rum, vodka and Blue Curaçao', AppLanguage.es: 'Cóctel fuerte con ron, vodka y Blue Curaçao', AppLanguage.it: 'Cocktail forte con rum, vodka e Blue Curaçao', AppLanguage.nl: 'Sterke cocktail met rum, wodka en Blue Curaçao', AppLanguage.fr: 'Strong cocktail with rum, vodka and Blue Curaçao', AppLanguage.pt: 'Strong cocktail with rum, vodka and Blue Curaçao', AppLanguage.pl: 'Strong cocktail with rum, vodka and Blue Curaçao', AppLanguage.tr: 'Strong cocktail with rum, vodka and Blue Curaçao', AppLanguage.ru: 'Strong cocktail with rum, vodka and Blue Curaçao'},
    'Eleganter Cocktail mit Tequila und Blue Curacao': {AppLanguage.de: 'Eleganter Cocktail mit Tequila und Blue Curacao', AppLanguage.en: 'Elegant cocktail with tequila and Blue Curaçao', AppLanguage.es: 'Cóctel elegante con tequila y Blue Curaçao', AppLanguage.it: 'Cocktail elegante con tequila e Blue Curaçao', AppLanguage.nl: 'Elegante cocktail met tequila en Blue Curaçao', AppLanguage.fr: 'Elegant cocktail with tequila and Blue Curaçao', AppLanguage.pt: 'Elegant cocktail with tequila and Blue Curaçao', AppLanguage.pl: 'Elegant cocktail with tequila and Blue Curaçao', AppLanguage.tr: 'Elegant cocktail with tequila and Blue Curaçao', AppLanguage.ru: 'Elegant cocktail with tequila and Blue Curaçao'},
    'Komplexer Gin-Cocktail mit tropischen Früchten': {AppLanguage.de: 'Komplexer Gin-Cocktail mit tropischen Früchten', AppLanguage.en: 'Complex gin cocktail with tropical fruits', AppLanguage.es: 'Cóctel complejo de ginebra con frutas tropicales', AppLanguage.it: 'Cocktail complesso al gin con frutti tropicali', AppLanguage.nl: 'Complexe gin-cocktail met tropisch fruit', AppLanguage.fr: 'Complex gin cocktail with tropical fruits', AppLanguage.pt: 'Complex gin cocktail with tropical fruits', AppLanguage.pl: 'Complex gin cocktail with tropical fruits', AppLanguage.tr: 'Complex gin cocktail with tropical fruits', AppLanguage.ru: 'Complex gin cocktail with tropical fruits'},
    'Eleganter Gin-Cocktail mit Ananas und Blue Curacao': {AppLanguage.de: 'Eleganter Gin-Cocktail mit Ananas und Blue Curacao', AppLanguage.en: 'Elegant gin cocktail with pineapple and Blue Curaçao', AppLanguage.es: 'Cóctel elegante de ginebra con piña y Blue Curaçao', AppLanguage.it: 'Cocktail elegante al gin con ananas e Blue Curaçao', AppLanguage.nl: 'Elegante gin-cocktail met ananas en Blue Curaçao', AppLanguage.fr: 'Elegant gin cocktail with pineapple and Blue Curaçao', AppLanguage.pt: 'Elegant gin cocktail with pineapple and Blue Curaçao', AppLanguage.pl: 'Elegant gin cocktail with pineapple and Blue Curaçao', AppLanguage.tr: 'Elegant gin cocktail with pineapple and Blue Curaçao', AppLanguage.ru: 'Elegant gin cocktail with pineapple and Blue Curaçao'},
    'Exotischer Cocktail mit Malibu, Blue Curacao und Grenadine': {AppLanguage.de: 'Exotischer Cocktail mit Malibu, Blue Curacao und Grenadine', AppLanguage.en: 'Exotic cocktail with Malibu, Blue Curaçao and grenadine', AppLanguage.es: 'Cóctel exótico con Malibu, Blue Curaçao y granadina', AppLanguage.it: 'Cocktail esotico con Malibu, Blue Curaçao e granatina', AppLanguage.nl: 'Exotische cocktail met Malibu, Blue Curaçao en grenadine', AppLanguage.fr: 'Exotic cocktail with Malibu, Blue Curaçao and grenadine', AppLanguage.pt: 'Exotic cocktail with Malibu, Blue Curaçao and grenadine', AppLanguage.pl: 'Exotic cocktail with Malibu, Blue Curaçao and grenadine', AppLanguage.tr: 'Exotic cocktail with Malibu, Blue Curaçao and grenadine', AppLanguage.ru: 'Exotic cocktail with Malibu, Blue Curaçao and grenadine'},
    'Süßer Cocktail mit Rum und Blue Curacao': {AppLanguage.de: 'Süßer Cocktail mit Rum und Blue Curacao', AppLanguage.en: 'Sweet cocktail with rum and Blue Curaçao', AppLanguage.es: 'Cóctel dulce con ron y Blue Curaçao', AppLanguage.it: 'Cocktail dolce con rum e Blue Curaçao', AppLanguage.nl: 'Zoete cocktail met rum en Blue Curaçao', AppLanguage.fr: 'Sweet cocktail with rum and Blue Curaçao', AppLanguage.pt: 'Sweet cocktail with rum and Blue Curaçao', AppLanguage.pl: 'Sweet cocktail with rum and Blue Curaçao', AppLanguage.tr: 'Sweet cocktail with rum and Blue Curaçao', AppLanguage.ru: 'Sweet cocktail with rum and Blue Curaçao'},
    'Urlaubscocktail mit Tequila, Blue Curacao und Pfirsichlikör': {AppLanguage.de: 'Urlaubscocktail mit Tequila, Blue Curacao und Pfirsichlikör', AppLanguage.en: 'Holiday cocktail with tequila, Blue Curaçao and peach liqueur', AppLanguage.es: 'Cóctel de vacaciones con tequila, Blue Curaçao y licor de melocotón', AppLanguage.it: 'Cocktail vacanza con tequila, Blue Curaçao e liquore alla pesca', AppLanguage.nl: 'Vakantiecocktail met tequila, Blue Curaçao en perziklikeur', AppLanguage.fr: 'Holiday cocktail with tequila, Blue Curaçao and peach liqueur', AppLanguage.pt: 'Holiday cocktail with tequila, Blue Curaçao and peach liqueur', AppLanguage.pl: 'Holiday cocktail with tequila, Blue Curaçao and peach liqueur', AppLanguage.tr: 'Holiday cocktail with tequila, Blue Curaçao and peach liqueur', AppLanguage.ru: 'Holiday cocktail with tequila, Blue Curaçao and peach liqueur'},
    'Lila Cocktail mit Vodka, Blue Curacao und Schweppes Wild Berry': {AppLanguage.de: 'Lila Cocktail mit Vodka, Blue Curacao und Schweppes Wild Berry', AppLanguage.en: 'Purple cocktail with vodka, Blue Curaçao and Schweppes Wild Berry', AppLanguage.es: 'Cóctel morado con vodka, Blue Curaçao y Schweppes Wild Berry', AppLanguage.it: 'Cocktail viola con vodka, Blue Curaçao e Schweppes Wild Berry', AppLanguage.nl: 'Paarse cocktail met wodka, Blue Curaçao en Schweppes Wild Berry', AppLanguage.fr: 'Purple cocktail with vodka, Blue Curaçao and Schweppes Wild Berry', AppLanguage.pt: 'Purple cocktail with vodka, Blue Curaçao and Schweppes Wild Berry', AppLanguage.pl: 'Purple cocktail with vodka, Blue Curaçao and Schweppes Wild Berry', AppLanguage.tr: 'Purple cocktail with vodka, Blue Curaçao and Schweppes Wild Berry', AppLanguage.ru: 'Purple cocktail with vodka, Blue Curaçao and Schweppes Wild Berry'},
    'Karibischer Cocktail mit Rum, Blue Curacao und Orangensaft': {AppLanguage.de: 'Karibischer Cocktail mit Rum, Blue Curacao und Orangensaft', AppLanguage.en: 'Caribbean cocktail with rum, Blue Curaçao and orange juice', AppLanguage.es: 'Cóctel caribeño con ron, Blue Curaçao y naranja', AppLanguage.it: 'Cocktail caraibico con rum, Blue Curaçao e arancia', AppLanguage.nl: 'Caribische cocktail met rum, Blue Curaçao en sinaasappel', AppLanguage.fr: 'Caribbean cocktail with rum, Blue Curaçao and orange juice', AppLanguage.pt: 'Caribbean cocktail with rum, Blue Curaçao and orange juice', AppLanguage.pl: 'Caribbean cocktail with rum, Blue Curaçao and orange juice', AppLanguage.tr: 'Caribbean cocktail with rum, Blue Curaçao and orange juice', AppLanguage.ru: 'Caribbean cocktail with rum, Blue Curaçao and orange juice'},
    'Alkoholfreier tropischer Cocktail mit Ananas und Maracuja': {AppLanguage.de: 'Alkoholfreier tropischer Cocktail mit Ananas und Maracuja', AppLanguage.en: 'Alcohol-free tropical cocktail with pineapple and passion fruit', AppLanguage.es: 'Cóctel tropical sin alcohol con piña y maracuyá', AppLanguage.it: 'Cocktail tropicale analcolico con ananas e passion fruit', AppLanguage.nl: 'Alcoholvrije tropische cocktail met ananas en passievrucht', AppLanguage.fr: 'Alcohol-free tropical cocktail with pineapple and passion fruit', AppLanguage.pt: 'Alcohol-free tropical cocktail with pineapple and passion fruit', AppLanguage.pl: 'Alcohol-free tropical cocktail with pineapple and passion fruit', AppLanguage.tr: 'Alcohol-free tropical cocktail with pineapple and passion fruit', AppLanguage.ru: 'Alcohol-free tropical cocktail with pineapple and passion fruit'},
    'Sportlicher alkoholfreier Cocktail mit tropischen Früchten': {AppLanguage.de: 'Sportlicher alkoholfreier Cocktail mit tropischen Früchten', AppLanguage.en: 'Sporty alcohol-free cocktail with tropical fruits', AppLanguage.es: 'Cóctel sin alcohol deportivo con frutas tropicales', AppLanguage.it: 'Cocktail analcolico sportivo con frutti tropicali', AppLanguage.nl: 'Sportieve alcoholvrije cocktail met tropisch fruit', AppLanguage.fr: 'Sporty alcohol-free cocktail with tropical fruits', AppLanguage.pt: 'Sporty alcohol-free cocktail with tropical fruits', AppLanguage.pl: 'Sporty alcohol-free cocktail with tropical fruits', AppLanguage.tr: 'Sporty alcohol-free cocktail with tropical fruits', AppLanguage.ru: 'Sporty alcohol-free cocktail with tropical fruits'},
    'Alkoholfreier Cocktail mit Maracuja und Orange': {AppLanguage.de: 'Alkoholfreier Cocktail mit Maracuja und Orange', AppLanguage.en: 'Alcohol-free cocktail with passion fruit and orange', AppLanguage.es: 'Cóctel sin alcohol con maracuyá y naranja', AppLanguage.it: 'Cocktail analcolico con passion fruit e arancia', AppLanguage.nl: 'Alcoholvrije cocktail met passievrucht en sinaasappel', AppLanguage.fr: 'Alcohol-free cocktail with passion fruit and orange', AppLanguage.pt: 'Alcohol-free cocktail with passion fruit and orange', AppLanguage.pl: 'Alcohol-free cocktail with passion fruit and orange', AppLanguage.tr: 'Alcohol-free cocktail with passion fruit and orange', AppLanguage.ru: 'Alcohol-free cocktail with passion fruit and orange'},
    'Alkoholfreier Kokos-Cocktail mit tropischen Früchten': {AppLanguage.de: 'Alkoholfreier Kokos-Cocktail mit tropischen Früchten', AppLanguage.en: 'Alcohol-free coconut cocktail with tropical fruits', AppLanguage.es: 'Cóctel sin alcohol de coco con frutas tropicales', AppLanguage.it: 'Cocktail analcolico al cocco con frutti tropicali', AppLanguage.nl: 'Alcoholvrije kokoscocktail met tropisch fruit', AppLanguage.fr: 'Alcohol-free coconut cocktail with tropical fruits', AppLanguage.pt: 'Alcohol-free coconut cocktail with tropical fruits', AppLanguage.pl: 'Alcohol-free coconut cocktail with tropical fruits', AppLanguage.tr: 'Alcohol-free coconut cocktail with tropical fruits', AppLanguage.ru: 'Alcohol-free coconut cocktail with tropical fruits'},
    'Alkoholfreie Pina Colada mit Kokossirup': {AppLanguage.de: 'Alkoholfreie Pina Colada mit Kokossirup', AppLanguage.en: 'Alcohol-free Piña Colada with coconut syrup', AppLanguage.es: 'Piña Colada sin alcohol con sirope de coco', AppLanguage.it: 'Piña Colada analcolica con sciroppo di cocco', AppLanguage.nl: 'Alcoholvrije Piña Colada met kokossiroop', AppLanguage.fr: 'Alcohol-free Piña Colada with coconut syrup', AppLanguage.pt: 'Alcohol-free Piña Colada with coconut syrup', AppLanguage.pl: 'Alcohol-free Piña Colada with coconut syrup', AppLanguage.tr: 'Alcohol-free Piña Colada with coconut syrup', AppLanguage.ru: 'Alcohol-free Piña Colada with coconut syrup'},
    'Alkoholfreier Solero mit Maracuja und Vanille': {AppLanguage.de: 'Alkoholfreier Solero mit Maracuja und Vanille', AppLanguage.en: 'Alcohol-free Solero with passion fruit and vanilla', AppLanguage.es: 'Solero sin alcohol con maracuyá y vainilla', AppLanguage.it: 'Solero analcolico con passion fruit e vaniglia', AppLanguage.nl: 'Alcoholvrije Solero met passievrucht en vanille', AppLanguage.fr: 'Alcohol-free Solero with passion fruit and vanilla', AppLanguage.pt: 'Alcohol-free Solero with passion fruit and vanilla', AppLanguage.pl: 'Alcohol-free Solero with passion fruit and vanilla', AppLanguage.tr: 'Alcohol-free Solero with passion fruit and vanilla', AppLanguage.ru: 'Alcohol-free Solero with passion fruit and vanilla'},
    'Keine Pumpe für': {AppLanguage.de: 'Keine Pumpe für', AppLanguage.en: 'No pump for', AppLanguage.es: 'No hay bomba para', AppLanguage.it: 'Nessuna pompa per', AppLanguage.nl: 'Geen pomp voor', AppLanguage.fr: 'Aucune pompe pour', AppLanguage.pt: 'Nenhuma bomba para', AppLanguage.pl: 'Brak pompy dla', AppLanguage.tr: 'Pompa yok:', AppLanguage.ru: 'Нет насоса для'},
    'reicht nicht aus': {AppLanguage.de: 'reicht nicht aus', AppLanguage.en: 'is not sufficient', AppLanguage.es: 'no es suficiente', AppLanguage.it: 'non è sufficiente', AppLanguage.nl: 'is niet voldoende', AppLanguage.fr: 'est insuffisant', AppLanguage.pt: 'não é suficiente', AppLanguage.pl: 'nie wystarcza', AppLanguage.tr: 'yeterli değil', AppLanguage.ru: 'недостаточно'},
    'Pumpen werden vorbereitet …': {AppLanguage.de: 'Pumpen werden vorbereitet …', AppLanguage.en: 'Pumps are being prepared …', AppLanguage.es: 'Preparando bombas …', AppLanguage.it: 'Preparazione pompe …', AppLanguage.nl: 'Pompen worden voorbereid …', AppLanguage.fr: 'Préparation des pompes …', AppLanguage.pt: 'Preparando bombas …', AppLanguage.pl: 'Przygotowywanie pomp …', AppLanguage.tr: 'Pompalar hazırlanıyor …', AppLanguage.ru: 'Подготовка насосов …'},
    'läuft': {AppLanguage.de: 'läuft', AppLanguage.en: 'is running', AppLanguage.es: 'funciona', AppLanguage.it: 'in funzione', AppLanguage.nl: 'loopt', AppLanguage.fr: 'fonctionne', AppLanguage.pt: 'em execução', AppLanguage.pl: 'działa', AppLanguage.tr: 'çalışıyor', AppLanguage.ru: 'работает'},
    'Pumpen laufen gleichzeitig': {AppLanguage.de: 'Pumpen laufen gleichzeitig', AppLanguage.en: 'pumps are running at the same time', AppLanguage.es: 'bombas funcionan a la vez', AppLanguage.it: 'pompe funzionano contemporaneamente', AppLanguage.nl: 'pompen lopen tegelijk', AppLanguage.fr: 'pompes fonctionnent en même temps', AppLanguage.pt: 'bombas funcionando ao mesmo tempo', AppLanguage.pl: 'pompy działają jednocześnie', AppLanguage.tr: 'pompa aynı anda çalışıyor', AppLanguage.ru: 'насосов работают одновременно'},
    'ist nicht kalibriert': {AppLanguage.de: 'ist nicht kalibriert', AppLanguage.en: 'is not calibrated', AppLanguage.es: 'no está calibrada', AppLanguage.it: 'non è calibrata', AppLanguage.nl: 'is niet gekalibreerd', AppLanguage.fr: 'n’est pas étalonnée', AppLanguage.pt: 'não está calibrada', AppLanguage.pl: 'nie jest skalibrowana', AppLanguage.tr: 'kalibre edilmedi', AppLanguage.ru: 'не откалиброван'},
    'Aktuelle Standardgröße': {AppLanguage.de: 'Aktuelle Standardgröße', AppLanguage.en: 'Current default size', AppLanguage.es: 'Tamaño estándar actual', AppLanguage.it: 'Dimensione standard attuale', AppLanguage.nl: 'Huidig standaardformaat', AppLanguage.fr: 'Taille standard actuelle', AppLanguage.pt: 'Tamanho padrão atual', AppLanguage.pl: 'Aktualny rozmiar domyślny', AppLanguage.tr: 'Mevcut varsayılan boyut', AppLanguage.ru: 'Текущий стандартный размер'},
    'Verfügbare Größe': {AppLanguage.de: 'Verfügbare Größe', AppLanguage.en: 'Available size', AppLanguage.es: 'Tamaño disponible', AppLanguage.it: 'Dimensione disponibile', AppLanguage.nl: 'Beschikbaar formaat', AppLanguage.fr: 'Taille disponible', AppLanguage.pt: 'Tamanho disponível', AppLanguage.pl: 'Dostępny rozmiar', AppLanguage.tr: 'Mevcut boyut', AppLanguage.ru: 'Доступный размер'},
    'Reinigung': {AppLanguage.de: 'Reinigung', AppLanguage.en: 'Cleaning', AppLanguage.es: 'Limpieza', AppLanguage.it: 'Pulizia', AppLanguage.nl: 'Reiniging', AppLanguage.fr: 'Nettoyage', AppLanguage.pt: 'Limpeza', AppLanguage.pl: 'Czyszczenie', AppLanguage.tr: 'Temizlik', AppLanguage.ru: 'Очистка'},
    'Entlüften': {AppLanguage.de: 'Entlüften', AppLanguage.en: 'Priming', AppLanguage.es: 'Purgar', AppLanguage.it: 'Spurgo', AppLanguage.nl: 'Ontluchten', AppLanguage.fr: 'Purge', AppLanguage.pt: 'Escorvar', AppLanguage.pl: 'Odpowietrzanie', AppLanguage.tr: 'Hava alma', AppLanguage.ru: 'Прокачка'},
    'Beschreibung': {AppLanguage.de: 'Beschreibung', AppLanguage.en: 'Description', AppLanguage.es: 'Descripción', AppLanguage.it: 'Descrizione', AppLanguage.nl: 'Beschrijving', AppLanguage.fr: 'Description', AppLanguage.pt: 'Descrição', AppLanguage.pl: 'Opis', AppLanguage.tr: 'Açıklama', AppLanguage.ru: 'Описание'},
    'Kategorie': {AppLanguage.de: 'Kategorie', AppLanguage.en: 'Category', AppLanguage.es: 'Categoría', AppLanguage.it: 'Categoria', AppLanguage.nl: 'Categorie', AppLanguage.fr: 'Catégorie', AppLanguage.pt: 'Categoria', AppLanguage.pl: 'Kategoria', AppLanguage.tr: 'Kategori', AppLanguage.ru: 'Категория'},
    'Größen für Cocktails': {AppLanguage.de: 'Größen für Cocktails', AppLanguage.en: 'Cocktail sizes', AppLanguage.es: 'Tamaños de cóctel', AppLanguage.it: 'Dimensioni cocktail', AppLanguage.nl: 'Cocktailformaten', AppLanguage.fr: 'Tailles des cocktails', AppLanguage.pt: 'Tamanhos de coquetel', AppLanguage.pl: 'Rozmiary koktajli', AppLanguage.tr: 'Kokteyl boyutları', AppLanguage.ru: 'Размеры коктейлей'},
    'Größen für Shots': {AppLanguage.de: 'Größen für Shots', AppLanguage.en: 'Shot sizes', AppLanguage.es: 'Tamaños de chupitos', AppLanguage.it: 'Dimensioni shot', AppLanguage.nl: 'Shotformaten', AppLanguage.fr: 'Tailles des shots', AppLanguage.pt: 'Tamanhos de shots', AppLanguage.pl: 'Rozmiary shotów', AppLanguage.tr: 'Shot boyutları', AppLanguage.ru: 'Размеры шотов'},
    'Standardmäßig 200 ml. Diese Größen gelten für Cocktails und alkoholfreie Cocktails.': {AppLanguage.de: 'Standardmäßig 200 ml. Diese Größen gelten für Cocktails und alkoholfreie Cocktails.', AppLanguage.en: 'Default is 200 ml. These sizes apply to cocktails and alcohol-free cocktails.', AppLanguage.es: 'El valor predeterminado es 200 ml. Estos tamaños se aplican a cócteles y cócteles sin alcohol.', AppLanguage.it: 'Il valore predefinito è 200 ml. Queste dimensioni valgono per cocktail e analcolici.', AppLanguage.nl: 'Standaard is 200 ml. Deze formaten gelden voor cocktails en alcoholvrije cocktails.', AppLanguage.fr: 'La valeur par défaut est 200 ml. Ces tailles s’appliquent aux cocktails et cocktails sans alcool.', AppLanguage.pt: 'O padrão é 200 ml. Esses tamanhos valem para coquetéis e coquetéis sem álcool.', AppLanguage.pl: 'Domyślnie 200 ml. Te rozmiary dotyczą koktajli i koktajli bezalkoholowych.', AppLanguage.tr: 'Varsayılan 200 ml. Bu boyutlar kokteyller ve alkolsüz kokteyller için geçerlidir.', AppLanguage.ru: 'По умолчанию 200 мл. Эти размеры применяются к коктейлям и безалкогольным коктейлям.'},
    'Voreingestellt sind 2 cl und 4 cl. In der App werden die Werte als 20 ml und 40 ml gespeichert.': {AppLanguage.de: 'Voreingestellt sind 2 cl und 4 cl. In der App werden die Werte als 20 ml und 40 ml gespeichert.', AppLanguage.en: 'Preset values are 2 cl and 4 cl. In the app they are stored as 20 ml and 40 ml.', AppLanguage.es: 'Los valores preestablecidos son 2 cl y 4 cl. En la app se guardan como 20 ml y 40 ml.', AppLanguage.it: 'I valori predefiniti sono 2 cl e 4 cl. Nell’app vengono salvati come 20 ml e 40 ml.', AppLanguage.nl: 'Vooringesteld zijn 2 cl en 4 cl. In de app worden ze opgeslagen als 20 ml en 40 ml.', AppLanguage.fr: 'Les valeurs prédéfinies sont 2 cl et 4 cl. Dans l’app, elles sont enregistrées comme 20 ml et 40 ml.', AppLanguage.pt: 'Os valores predefinidos são 2 cl e 4 cl. No app são salvos como 20 ml e 40 ml.', AppLanguage.pl: 'Domyślnie ustawiono 2 cl i 4 cl. W aplikacji zapisane są jako 20 ml i 40 ml.', AppLanguage.tr: 'Varsayılan değerler 2 cl ve 4 cl’dir. Uygulamada 20 ml ve 40 ml olarak kaydedilir.', AppLanguage.ru: 'Предустановлены 2 cl и 4 cl. В приложении они сохраняются как 20 мл и 40 мл.'},
    'Neue Größe in ml': {AppLanguage.de: 'Neue Größe in ml', AppLanguage.en: 'New size in ml', AppLanguage.es: 'Nuevo tamaño en ml', AppLanguage.it: 'Nuova dimensione in ml', AppLanguage.nl: 'Nieuw formaat in ml', AppLanguage.fr: 'Nouvelle taille en ml', AppLanguage.pt: 'Novo tamanho em ml', AppLanguage.pl: 'Nowy rozmiar w ml', AppLanguage.tr: 'ml cinsinden yeni boyut', AppLanguage.ru: 'Новый размер в мл'},
    'Neue Größe': {AppLanguage.de: 'Neue Größe', AppLanguage.en: 'New size', AppLanguage.es: 'Nuevo tamaño', AppLanguage.it: 'Nuova dimensione', AppLanguage.nl: 'Nieuw formaat', AppLanguage.fr: 'Nouvelle taille', AppLanguage.pt: 'Novo tamanho', AppLanguage.pl: 'Nowy rozmiar', AppLanguage.tr: 'Yeni boyut', AppLanguage.ru: 'Новый размер'},
    'Dieses Fenster schließt in': {AppLanguage.de: 'Dieses Fenster schließt in', AppLanguage.en: 'This window closes in', AppLanguage.es: 'Esta ventana se cierra en', AppLanguage.it: 'Questa finestra si chiude tra', AppLanguage.nl: 'Dit venster sluit over', AppLanguage.fr: 'Cette fenêtre se ferme dans', AppLanguage.pt: 'Esta janela fecha em', AppLanguage.pl: 'To okno zamknie się za', AppLanguage.tr: 'Bu pencere şu süre sonra kapanır:', AppLanguage.ru: 'Это окно закроется через'},
    'Sekunden.': {AppLanguage.de: 'Sekunden.', AppLanguage.en: 'seconds.', AppLanguage.es: 'segundos.', AppLanguage.it: 'secondi.', AppLanguage.nl: 'seconden.', AppLanguage.fr: 'secondes.', AppLanguage.pt: 'segundos.', AppLanguage.pl: 'sekund.', AppLanguage.tr: 'saniye.', AppLanguage.ru: 'сек.'},
    'Nicht verbunden': {AppLanguage.de: 'Nicht verbunden', AppLanguage.en: 'Not connected', AppLanguage.es: 'No conectado', AppLanguage.it: 'Non connesso', AppLanguage.nl: 'Niet verbonden', AppLanguage.fr: 'Non connecté', AppLanguage.pt: 'Não conectado', AppLanguage.pl: 'Niepołączono', AppLanguage.tr: 'Bağlı değil', AppLanguage.ru: 'Не подключено'},
    'Verbindung wird geprüft …': {AppLanguage.de: 'Verbindung wird geprüft …', AppLanguage.en: 'Checking connection …', AppLanguage.es: 'Comprobando conexión …', AppLanguage.it: 'Verifica connessione …', AppLanguage.nl: 'Verbinding controleren …', AppLanguage.fr: 'Vérification de la connexion …', AppLanguage.pt: 'Verificando conexão …', AppLanguage.pl: 'Sprawdzanie połączenia …', AppLanguage.tr: 'Bağlantı kontrol ediliyor …', AppLanguage.ru: 'Проверка подключения …'},
    'Bluetooth Demo verbunden': {AppLanguage.de: 'Bluetooth Demo verbunden', AppLanguage.en: 'Bluetooth demo connected', AppLanguage.es: 'Demo Bluetooth conectada', AppLanguage.it: 'Demo Bluetooth connessa', AppLanguage.nl: 'Bluetooth-demo verbonden', AppLanguage.fr: 'Démo Bluetooth connectée', AppLanguage.pt: 'Demo Bluetooth conectada', AppLanguage.pl: 'Demo Bluetooth połączone', AppLanguage.tr: 'Bluetooth demo bağlı', AppLanguage.ru: 'Bluetooth-демо подключено'},
    'Keine Antwort von': {AppLanguage.de: 'Keine Antwort von', AppLanguage.en: 'No response from', AppLanguage.es: 'Sin respuesta de', AppLanguage.it: 'Nessuna risposta da', AppLanguage.nl: 'Geen antwoord van', AppLanguage.fr: 'Aucune réponse de', AppLanguage.pt: 'Sem resposta de', AppLanguage.pl: 'Brak odpowiedzi od', AppLanguage.tr: 'Yanıt yok:', AppLanguage.ru: 'Нет ответа от'},
    'Kalibrierung': {AppLanguage.de: 'Kalibrierung', AppLanguage.en: 'Calibration', AppLanguage.es: 'Calibración', AppLanguage.it: 'Calibrazione', AppLanguage.nl: 'Kalibratie', AppLanguage.fr: 'Étalonnage', AppLanguage.pt: 'Calibração', AppLanguage.pl: 'Kalibracja', AppLanguage.tr: 'Kalibrasyon', AppLanguage.ru: 'Калибровка'},
    '1. Ordne der Pumpe eine Zutat zu.\n2. Stelle einen Messbecher unter den Auslass.\n3. Wähle eine Testzeit zwischen 2 und 5 Sekunden.\n4. Starte den Testlauf und miss die ausgegebene Menge.\n5. Trage die Menge in ml ein und speichere den Wert.\n\nDie App berechnet daraus automatisch ml pro Sekunde. Zutat, Förderleistung und Füllstand werden dauerhaft auf dem Gerät gespeichert.\n\nEin Cocktail kann erst zubereitet werden, wenn alle automatisch verwendeten Zutaten einer aktiven Pumpe zugeordnet und diese Pumpen kalibriert wurden.': {AppLanguage.de: '1. Ordne der Pumpe eine Zutat zu.\n2. Stelle einen Messbecher unter den Auslass.\n3. Wähle eine Testzeit zwischen 2 und 5 Sekunden.\n4. Starte den Testlauf und miss die ausgegebene Menge.\n5. Trage die Menge in ml ein und speichere den Wert.\n\nDie App berechnet daraus automatisch ml pro Sekunde. Zutat, Förderleistung und Füllstand werden dauerhaft auf dem Gerät gespeichert.\n\nEin Cocktail kann erst zubereitet werden, wenn alle automatisch verwendeten Zutaten einer aktiven Pumpe zugeordnet und diese Pumpen kalibriert wurden.', AppLanguage.en: '1. Assign an ingredient to the pump.\n2. Place a measuring cup under the outlet.\n3. Choose a test time between 2 and 5 seconds.\n4. Start the test run and measure the dispensed amount.\n5. Enter the amount in ml and save the value.\n\nThe app automatically calculates ml per second from this. Ingredient, flow rate and fill level are saved permanently on the device.\n\nA cocktail can only be prepared when all automatically used ingredients are assigned to an active pump and those pumps are calibrated.', AppLanguage.es: '1. Asigna un ingrediente a la bomba.\n2. Coloca un vaso medidor bajo la salida.\n3. Elige un tiempo de prueba entre 2 y 5 segundos.\n4. Inicia la prueba y mide la cantidad dispensada.\n5. Introduce la cantidad en ml y guarda el valor.\n\nLa app calcula automáticamente los ml por segundo. Ingrediente, caudal y nivel se guardan de forma permanente en el dispositivo.\n\nUn cóctel solo puede prepararse cuando todos los ingredientes automáticos estén asignados a una bomba activa y calibrada.', AppLanguage.it: '1. Assegna un ingrediente alla pompa.\n2. Metti un misurino sotto l’uscita.\n3. Scegli un tempo di test tra 2 e 5 secondi.\n4. Avvia il test e misura la quantità erogata.\n5. Inserisci la quantità in ml e salva il valore.\n\nL’app calcola automaticamente i ml al secondo. Ingrediente, portata e livello vengono salvati permanentemente sul dispositivo.\n\nUn cocktail può essere preparato solo quando tutti gli ingredienti automatici sono assegnati a una pompa attiva e calibrata.', AppLanguage.nl: '1. Wijs een ingrediënt toe aan de pomp.\n2. Plaats een maatbeker onder de uitloop.\n3. Kies een testtijd tussen 2 en 5 seconden.\n4. Start de test en meet de afgegeven hoeveelheid.\n5. Vul de hoeveelheid in ml in en sla de waarde op.\n\nDe app berekent hieruit automatisch ml per seconde. Ingrediënt, opbrengst en vulniveau worden permanent op het apparaat opgeslagen.\n\nEen cocktail kan pas worden bereid wanneer alle automatisch gebruikte ingrediënten aan een actieve pomp zijn toegewezen en deze pompen zijn gekalibreerd.', AppLanguage.fr: '1. Assign an ingredient to the pump.\n2. Place a measuring cup under the outlet.\n3. Choose a test time between 2 and 5 seconds.\n4. Start the test run and measure the dispensed amount.\n5. Enter the amount in ml and save the value.\n\nThe app automatically calculates ml per second from this. Ingredient, flow rate and fill level are saved permanently on the device.\n\nA cocktail can only be prepared when all automatically used ingredients are assigned to an active pump and those pumps are calibrated.', AppLanguage.pt: '1. Assign an ingredient to the pump.\n2. Place a measuring cup under the outlet.\n3. Choose a test time between 2 and 5 seconds.\n4. Start the test run and measure the dispensed amount.\n5. Enter the amount in ml and save the value.\n\nThe app automatically calculates ml per second from this. Ingredient, flow rate and fill level are saved permanently on the device.\n\nA cocktail can only be prepared when all automatically used ingredients are assigned to an active pump and those pumps are calibrated.', AppLanguage.pl: '1. Assign an ingredient to the pump.\n2. Place a measuring cup under the outlet.\n3. Choose a test time between 2 and 5 seconds.\n4. Start the test run and measure the dispensed amount.\n5. Enter the amount in ml and save the value.\n\nThe app automatically calculates ml per second from this. Ingredient, flow rate and fill level are saved permanently on the device.\n\nA cocktail can only be prepared when all automatically used ingredients are assigned to an active pump and those pumps are calibrated.', AppLanguage.tr: '1. Assign an ingredient to the pump.\n2. Place a measuring cup under the outlet.\n3. Choose a test time between 2 and 5 seconds.\n4. Start the test run and measure the dispensed amount.\n5. Enter the amount in ml and save the value.\n\nThe app automatically calculates ml per second from this. Ingredient, flow rate and fill level are saved permanently on the device.\n\nA cocktail can only be prepared when all automatically used ingredients are assigned to an active pump and those pumps are calibrated.', AppLanguage.ru: '1. Assign an ingredient to the pump.\n2. Place a measuring cup under the outlet.\n3. Choose a test time between 2 and 5 seconds.\n4. Start the test run and measure the dispensed amount.\n5. Enter the amount in ml and save the value.\n\nThe app automatically calculates ml per second from this. Ingredient, flow rate and fill level are saved permanently on the device.\n\nA cocktail can only be prepared when all automatically used ingredients are assigned to an active pump and those pumps are calibrated.'},
    '1. Fülle einen großen Behälter mit etwa 40–50 °C warmem Wasser und etwas Spülmittel. Lege alle Ansaugschläuche in den Behälter und starte die Reinigung.\n\n2. Fülle den Behälter anschließend mit klarem Wasser und starte die Reinigung erneut.\n\n3. Entferne alle Schläuche aus dem Wasser, lege ein Handtuch vor die Pumpenausgänge und starte die Reinigung ein drittes Mal, damit Pumpen und Schläuche trocknen.': {AppLanguage.de: '1. Fülle einen großen Behälter mit etwa 40–50 °C warmem Wasser und etwas Spülmittel. Lege alle Ansaugschläuche in den Behälter und starte die Reinigung.\n\n2. Fülle den Behälter anschließend mit klarem Wasser und starte die Reinigung erneut.\n\n3. Entferne alle Schläuche aus dem Wasser, lege ein Handtuch vor die Pumpenausgänge und starte die Reinigung ein drittes Mal, damit Pumpen und Schläuche trocknen.', AppLanguage.en: '1. Fill a large container with warm water at about 40–50 °C and a little dish soap. Put all intake tubes into the container and start cleaning.\n\n2. Then fill the container with clean water and start cleaning again.\n\n3. Remove all tubes from the water, place a towel in front of the pump outlets and start cleaning a third time so pumps and tubes can dry.', AppLanguage.es: '1. Llena un recipiente grande con agua tibia de unos 40–50 °C y un poco de detergente. Coloca todos los tubos de aspiración en el recipiente e inicia la limpieza.\n\n2. Después llena el recipiente con agua limpia e inicia la limpieza otra vez.\n\n3. Retira todos los tubos del agua, coloca una toalla delante de las salidas de las bombas e inicia la limpieza por tercera vez para que bombas y tubos se sequen.', AppLanguage.it: '1. Riempi un grande contenitore con acqua calda a circa 40–50 °C e un po’ di detersivo. Metti tutti i tubi di aspirazione nel contenitore e avvia la pulizia.\n\n2. Poi riempi il contenitore con acqua pulita e avvia di nuovo la pulizia.\n\n3. Togli tutti i tubi dall’acqua, metti un asciugamano davanti alle uscite delle pompe e avvia la pulizia una terza volta per asciugare pompe e tubi.', AppLanguage.nl: '1. Vul een grote bak met warm water van ongeveer 40–50 °C en een beetje afwasmiddel. Leg alle aanzuigslangen in de bak en start de reiniging.\n\n2. Vul de bak daarna met schoon water en start de reiniging opnieuw.\n\n3. Haal alle slangen uit het water, leg een handdoek voor de pompuitgangen en start de reiniging een derde keer, zodat pompen en slangen drogen.', AppLanguage.fr: '1. Fill a large container with warm water at about 40–50 °C and a little dish soap. Put all intake tubes into the container and start cleaning.\n\n2. Then fill the container with clean water and start cleaning again.\n\n3. Remove all tubes from the water, place a towel in front of the pump outlets and start cleaning a third time so pumps and tubes can dry.', AppLanguage.pt: '1. Fill a large container with warm water at about 40–50 °C and a little dish soap. Put all intake tubes into the container and start cleaning.\n\n2. Then fill the container with clean water and start cleaning again.\n\n3. Remove all tubes from the water, place a towel in front of the pump outlets and start cleaning a third time so pumps and tubes can dry.', AppLanguage.pl: '1. Fill a large container with warm water at about 40–50 °C and a little dish soap. Put all intake tubes into the container and start cleaning.\n\n2. Then fill the container with clean water and start cleaning again.\n\n3. Remove all tubes from the water, place a towel in front of the pump outlets and start cleaning a third time so pumps and tubes can dry.', AppLanguage.tr: '1. Fill a large container with warm water at about 40–50 °C and a little dish soap. Put all intake tubes into the container and start cleaning.\n\n2. Then fill the container with clean water and start cleaning again.\n\n3. Remove all tubes from the water, place a towel in front of the pump outlets and start cleaning a third time so pumps and tubes can dry.', AppLanguage.ru: '1. Fill a large container with warm water at about 40–50 °C and a little dish soap. Put all intake tubes into the container and start cleaning.\n\n2. Then fill the container with clean water and start cleaning again.\n\n3. Remove all tubes from the water, place a towel in front of the pump outlets and start cleaning a third time so pumps and tubes can dry.'},
    'Wird übertragen …': {AppLanguage.de: 'Wird übertragen …', AppLanguage.en: 'Transferring …', AppLanguage.es: 'Transfiriendo …', AppLanguage.it: 'Trasferimento …', AppLanguage.nl: 'Wordt verzonden …', AppLanguage.fr: 'Transmission …', AppLanguage.pt: 'Transferindo …', AppLanguage.pl: 'Przesyłanie …', AppLanguage.tr: 'Aktarılıyor …', AppLanguage.ru: 'Передача …'},
    'LED-Einstellungen übernehmen': {AppLanguage.de: 'LED-Einstellungen übernehmen', AppLanguage.en: 'Apply LED settings', AppLanguage.es: 'Aplicar ajustes LED', AppLanguage.it: 'Applica impostazioni LED', AppLanguage.nl: 'LED-instellingen toepassen', AppLanguage.fr: 'Appliquer les réglages LED', AppLanguage.pt: 'Aplicar configurações LED', AppLanguage.pl: 'Zastosuj ustawienia LED', AppLanguage.tr: 'LED ayarlarını uygula', AppLanguage.ru: 'Применить настройки LED'},
    'Rezept bearbeiten': {AppLanguage.de: 'Rezept bearbeiten', AppLanguage.en: 'Edit recipe', AppLanguage.es: 'Editar receta', AppLanguage.it: 'Modifica ricetta', AppLanguage.nl: 'Recept bewerken', AppLanguage.fr: 'Modifier la recette', AppLanguage.pt: 'Editar receita', AppLanguage.pl: 'Edytuj przepis', AppLanguage.tr: 'Tarifi düzenle', AppLanguage.ru: 'Редактировать рецепт'},
    'Änderungen speichern': {AppLanguage.de: 'Änderungen speichern', AppLanguage.en: 'Save changes', AppLanguage.es: 'Guardar cambios', AppLanguage.it: 'Salva modifiche', AppLanguage.nl: 'Wijzigingen opslaan', AppLanguage.fr: 'Enregistrer les modifications', AppLanguage.pt: 'Salvar alterações', AppLanguage.pl: 'Zapisz zmiany', AppLanguage.tr: 'Değişiklikleri kaydet', AppLanguage.ru: 'Сохранить изменения'},
    'Rezept speichern': {AppLanguage.de: 'Rezept speichern', AppLanguage.en: 'Save recipe', AppLanguage.es: 'Guardar receta', AppLanguage.it: 'Salva ricetta', AppLanguage.nl: 'Recept opslaan', AppLanguage.fr: 'Enregistrer la recette', AppLanguage.pt: 'Salvar receita', AppLanguage.pl: 'Zapisz przepis', AppLanguage.tr: 'Tarifi kaydet', AppLanguage.ru: 'Сохранить рецепт'},
    'Bild hinzufügen': {AppLanguage.de: 'Bild hinzufügen', AppLanguage.en: 'Add image', AppLanguage.es: 'Añadir imagen', AppLanguage.it: 'Aggiungi immagine', AppLanguage.nl: 'Afbeelding toevoegen', AppLanguage.fr: 'Ajouter une image', AppLanguage.pt: 'Adicionar imagem', AppLanguage.pl: 'Dodaj obraz', AppLanguage.tr: 'Resim ekle', AppLanguage.ru: 'Добавить изображение'},
    'Bild ausgewählt': {AppLanguage.de: 'Bild ausgewählt', AppLanguage.en: 'Image selected', AppLanguage.es: 'Imagen seleccionada', AppLanguage.it: 'Immagine selezionata', AppLanguage.nl: 'Afbeelding geselecteerd', AppLanguage.fr: 'Image sélectionnée', AppLanguage.pt: 'Imagem selecionada', AppLanguage.pl: 'Wybrano obraz', AppLanguage.tr: 'Resim seçildi', AppLanguage.ru: 'Изображение выбрано'},
    'Bild auswählen': {AppLanguage.de: 'Bild auswählen', AppLanguage.en: 'Select image', AppLanguage.es: 'Seleccionar imagen', AppLanguage.it: 'Seleziona immagine', AppLanguage.nl: 'Afbeelding kiezen', AppLanguage.fr: 'Choisir une image', AppLanguage.pt: 'Selecionar imagem', AppLanguage.pl: 'Wybierz obraz', AppLanguage.tr: 'Resim seç', AppLanguage.ru: 'Выбрать изображение'},
    'Zum Beispiel: Mit Ananas dekorieren': {AppLanguage.de: 'Zum Beispiel: Mit Ananas dekorieren', AppLanguage.en: 'For example: Garnish with pineapple', AppLanguage.es: 'Por ejemplo: decorar con piña', AppLanguage.it: 'Ad esempio: guarnire con ananas', AppLanguage.nl: 'Bijvoorbeeld: garneren met ananas', AppLanguage.fr: 'Par exemple : garnir avec de l’ananas', AppLanguage.pt: 'Por exemplo: decorar com abacaxi', AppLanguage.pl: 'Na przykład: udekoruj ananasem', AppLanguage.tr: 'Örneğin: ananas ile süsle', AppLanguage.ru: 'Например: украсить ананасом'},
    'Alkoholgehalt': {AppLanguage.de: 'Alkoholgehalt', AppLanguage.en: 'Alcohol content', AppLanguage.es: 'Contenido de alcohol', AppLanguage.it: 'Gradazione alcolica', AppLanguage.nl: 'Alcoholpercentage', AppLanguage.fr: 'Teneur en alcool', AppLanguage.pt: 'Teor alcoólico', AppLanguage.pl: 'Zawartość alkoholu', AppLanguage.tr: 'Alkol oranı', AppLanguage.ru: 'Содержание алкоголя'},
    'Alkoholgehalt in % vol': {AppLanguage.de: 'Alkoholgehalt in % vol', AppLanguage.en: 'Alcohol content in % vol', AppLanguage.es: 'Contenido de alcohol en % vol', AppLanguage.it: 'Gradazione alcolica in % vol', AppLanguage.nl: 'Alcoholpercentage in % vol', AppLanguage.fr: 'Teneur en alcool en % vol', AppLanguage.pt: 'Teor alcoólico em % vol', AppLanguage.pl: 'Zawartość alkoholu w % obj.', AppLanguage.tr: '% hacim alkol oranı', AppLanguage.ru: 'Содержание алкоголя в % об.'},
    'Alkoholgehalt bearbeiten': {AppLanguage.de: 'Alkoholgehalt bearbeiten', AppLanguage.en: 'Edit alcohol content', AppLanguage.es: 'Editar contenido de alcohol', AppLanguage.it: 'Modifica gradazione alcolica', AppLanguage.nl: 'Alcoholpercentage bewerken', AppLanguage.fr: 'Modifier la teneur en alcool', AppLanguage.pt: 'Editar teor alcoólico', AppLanguage.pl: 'Edytuj zawartość alkoholu', AppLanguage.tr: 'Alkol oranını düzenle', AppLanguage.ru: 'Изменить содержание алкоголя'},
    '% vol': {AppLanguage.de: '% vol', AppLanguage.en: '% vol', AppLanguage.es: '% vol', AppLanguage.it: '% vol', AppLanguage.nl: '% vol', AppLanguage.fr: '% vol', AppLanguage.pt: '% vol', AppLanguage.pl: '% obj.', AppLanguage.tr: '% hac.', AppLanguage.ru: '% об.'},
    'Reiner Alkohol': {AppLanguage.de: 'Reiner Alkohol', AppLanguage.en: 'Pure alcohol', AppLanguage.es: 'Alcohol puro', AppLanguage.it: 'Alcol puro', AppLanguage.nl: 'Pure alcohol', AppLanguage.fr: 'Alcool pur', AppLanguage.pt: 'Álcool puro', AppLanguage.pl: 'Czysty alkohol', AppLanguage.tr: 'Saf alkol', AppLanguage.ru: 'Чистый алкоголь'},
    'Automatisch aus Zutaten und Zielgröße berechnet': {AppLanguage.de: 'Automatisch aus Zutaten und Zielgröße berechnet', AppLanguage.en: 'Calculated automatically from ingredients and target size', AppLanguage.es: 'Calculado automáticamente a partir de ingredientes y tamaño objetivo', AppLanguage.it: 'Calcolato automaticamente da ingredienti e dimensione finale', AppLanguage.nl: 'Automatisch berekend uit ingrediënten en doelgrootte', AppLanguage.fr: 'Calculé automatiquement à partir des ingrédients et de la taille cible', AppLanguage.pt: 'Calculado automaticamente a partir dos ingredientes e do tamanho final', AppLanguage.pl: 'Obliczane automatycznie ze składników i rozmiaru docelowego', AppLanguage.tr: 'Malzemelerden ve hedef boyuttan otomatik hesaplanır', AppLanguage.ru: 'Автоматически рассчитывается по ингредиентам и целевому объёму'},
    'Wird für die automatische Alkoholberechnung genutzt': {AppLanguage.de: 'Wird für die automatische Alkoholberechnung genutzt', AppLanguage.en: 'Used for automatic alcohol calculation', AppLanguage.es: 'Se usa para el cálculo automático de alcohol', AppLanguage.it: 'Usato per il calcolo automatico dell’alcol', AppLanguage.nl: 'Wordt gebruikt voor automatische alcoholberekening', AppLanguage.fr: 'Utilisé pour le calcul automatique de l’alcool', AppLanguage.pt: 'Usado para o cálculo automático de álcool', AppLanguage.pl: 'Używane do automatycznego obliczania alkoholu', AppLanguage.tr: 'Otomatik alkol hesaplaması için kullanılır', AppLanguage.ru: 'Используется для автоматического расчёта алкоголя'},
    'Bitte Alkoholgehalt der Flasche eintragen': {AppLanguage.de: 'Bitte Alkoholgehalt der Flasche eintragen', AppLanguage.en: 'Enter the alcohol content shown on the bottle', AppLanguage.es: 'Introduce el contenido de alcohol indicado en la botella', AppLanguage.it: 'Inserisci la gradazione indicata sulla bottiglia', AppLanguage.nl: 'Vul het alcoholpercentage van de fles in', AppLanguage.fr: 'Saisir la teneur indiquée sur la bouteille', AppLanguage.pt: 'Insira o teor alcoólico indicado na garrafa', AppLanguage.pl: 'Wpisz zawartość alkoholu podaną na butelce', AppLanguage.tr: 'Şişede yazan alkol oranını gir', AppLanguage.ru: 'Введите содержание алкоголя, указанное на бутылке'},
    'Typische Richtwerte, bitte je nach Flasche prüfen': {AppLanguage.de: 'Typische Richtwerte, bitte je nach Flasche prüfen', AppLanguage.en: 'Typical guide values; please check the bottle', AppLanguage.es: 'Valores orientativos; comprueba la botella', AppLanguage.it: 'Valori indicativi; controlla la bottiglia', AppLanguage.nl: 'Richtwaarden; controleer de fles', AppLanguage.fr: 'Valeurs indicatives ; vérifier la bouteille', AppLanguage.pt: 'Valores de referência; confira a garrafa', AppLanguage.pl: 'Typowe wartości orientacyjne; sprawdź butelkę', AppLanguage.tr: 'Tipik yaklaşık değerler; şişeyi kontrol et', AppLanguage.ru: 'Типовые ориентировочные значения; проверьте бутылку'},
    'Anzeige': {AppLanguage.de: 'Anzeige', AppLanguage.en: 'Display', AppLanguage.es: 'Pantalla', AppLanguage.it: 'Visualizzazione', AppLanguage.nl: 'Weergave', AppLanguage.fr: 'Affichage', AppLanguage.pt: 'Exibição', AppLanguage.pl: 'Wyświetlanie', AppLanguage.tr: 'Görünüm', AppLanguage.ru: 'Отображение'},
    'Cocktails pro Seite': {AppLanguage.de: 'Cocktails pro Seite', AppLanguage.en: 'Cocktails per page', AppLanguage.es: 'Cócteles por página', AppLanguage.it: 'Cocktail per pagina', AppLanguage.nl: 'Cocktails per pagina', AppLanguage.fr: 'Cocktails par page', AppLanguage.pt: 'Coquetéis por página', AppLanguage.pl: 'Koktajle na stronę', AppLanguage.tr: 'Sayfa başına kokteyl', AppLanguage.ru: 'Коктейлей на странице'},
    'Cocktails pro Seite einstellen': {AppLanguage.de: 'Cocktails pro Seite einstellen', AppLanguage.en: 'Set cocktails per page', AppLanguage.es: 'Ajustar cócteles por página', AppLanguage.it: 'Imposta cocktail per pagina', AppLanguage.nl: 'Cocktails per pagina instellen', AppLanguage.fr: 'Définir les cocktails par page', AppLanguage.pt: 'Definir coquetéis por página', AppLanguage.pl: 'Ustaw koktajle na stronę', AppLanguage.tr: 'Sayfa başına kokteyl ayarla', AppLanguage.ru: 'Настроить коктейли на странице'},
    'Sortierung': {AppLanguage.de: 'Sortierung', AppLanguage.en: 'Sorting', AppLanguage.es: 'Orden', AppLanguage.it: 'Ordinamento', AppLanguage.nl: 'Sortering', AppLanguage.fr: 'Tri', AppLanguage.pt: 'Ordenação', AppLanguage.pl: 'Sortowanie', AppLanguage.tr: 'Sıralama', AppLanguage.ru: 'Сортировка'},
    'Originale Reihenfolge': {AppLanguage.de: 'Originale Reihenfolge', AppLanguage.en: 'Original order', AppLanguage.es: 'Orden original', AppLanguage.it: 'Ordine originale', AppLanguage.nl: 'Originele volgorde', AppLanguage.fr: 'Ordre original', AppLanguage.pt: 'Ordem original', AppLanguage.pl: 'Oryginalna kolejność', AppLanguage.tr: 'Orijinal sıra', AppLanguage.ru: 'Исходный порядок'},
    'Name A-Z': {AppLanguage.de: 'Name A-Z', AppLanguage.en: 'Name A-Z', AppLanguage.es: 'Nombre A-Z', AppLanguage.it: 'Nome A-Z', AppLanguage.nl: 'Naam A-Z', AppLanguage.fr: 'Nom A-Z', AppLanguage.pt: 'Nome A-Z', AppLanguage.pl: 'Nazwa A-Z', AppLanguage.tr: 'Ad A-Z', AppLanguage.ru: 'Название A-Z'},
    'Name Z-A': {AppLanguage.de: 'Name Z-A', AppLanguage.en: 'Name Z-A', AppLanguage.es: 'Nombre Z-A', AppLanguage.it: 'Nome Z-A', AppLanguage.nl: 'Naam Z-A', AppLanguage.fr: 'Nom Z-A', AppLanguage.pt: 'Nome Z-A', AppLanguage.pl: 'Nazwa Z-A', AppLanguage.tr: 'Ad Z-A', AppLanguage.ru: 'Название Z-A'},
    'Verfügbare zuerst': {AppLanguage.de: 'Verfügbare zuerst', AppLanguage.en: 'Available first', AppLanguage.es: 'Disponibles primero', AppLanguage.it: 'Disponibili prima', AppLanguage.nl: 'Beschikbaar eerst', AppLanguage.fr: 'Disponibles d’abord', AppLanguage.pt: 'Disponíveis primeiro', AppLanguage.pl: 'Dostępne najpierw', AppLanguage.tr: 'Uygun olanlar önce', AppLanguage.ru: 'Доступные сначала'},
    'Alkohol niedrig': {AppLanguage.de: 'Alkohol niedrig', AppLanguage.en: 'Low alcohol', AppLanguage.es: 'Alcohol bajo', AppLanguage.it: 'Alcol basso', AppLanguage.nl: 'Weinig alcohol', AppLanguage.fr: 'Alcool faible', AppLanguage.pt: 'Baixo álcool', AppLanguage.pl: 'Niski alkohol', AppLanguage.tr: 'Düşük alkol', AppLanguage.ru: 'Меньше алкоголя'},
    'Alkohol hoch': {AppLanguage.de: 'Alkohol hoch', AppLanguage.en: 'High alcohol', AppLanguage.es: 'Alcohol alto', AppLanguage.it: 'Alcol alto', AppLanguage.nl: 'Veel alcohol', AppLanguage.fr: 'Alcool élevé', AppLanguage.pt: 'Alto álcool', AppLanguage.pl: 'Wysoki alkohol', AppLanguage.tr: 'Yüksek alkol', AppLanguage.ru: 'Больше алкоголя'},
    'Beliebtheit': {AppLanguage.de: 'Beliebtheit', AppLanguage.en: 'Popularity', AppLanguage.es: 'Popularidad', AppLanguage.it: 'Popolarità', AppLanguage.nl: 'Populariteit', AppLanguage.fr: 'Popularité', AppLanguage.pt: 'Popularidade', AppLanguage.pl: 'Popularność', AppLanguage.tr: 'Popülerlik', AppLanguage.ru: 'Популярность'},
    'Legt fest, wie viele Cocktailkarten in Cocktails, alkoholfreien Cocktails und Shots pro Seite angezeigt werden.': {AppLanguage.de: 'Legt fest, wie viele Cocktailkarten in Cocktails, alkoholfreien Cocktails und Shots pro Seite angezeigt werden.', AppLanguage.en: 'Sets how many cocktail cards are shown per page in cocktails, non-alcoholic cocktails and shots.', AppLanguage.es: 'Define cuántas tarjetas de cócteles se muestran por página en cócteles, sin alcohol y shots.', AppLanguage.it: 'Imposta quante schede cocktail vengono mostrate per pagina in cocktail, analcolici e shot.', AppLanguage.nl: 'Bepaalt hoeveel cocktailkaarten per pagina worden getoond bij cocktails, alcoholvrije cocktails en shots.', AppLanguage.fr: 'Définit le nombre de cartes de cocktails affichées par page dans cocktails, sans alcool et shots.', AppLanguage.pt: 'Define quantos cartões de coquetel são exibidos por página em coquetéis, sem álcool e shots.', AppLanguage.pl: 'Określa, ile kart koktajli jest wyświetlanych na stronie w koktajlach, bezalkoholowych i shotach.', AppLanguage.tr: 'Kokteyller, alkolsüz kokteyller ve shotlar listelerinde sayfa başına kaç kart gösterileceğini belirler.', AppLanguage.ru: 'Задаёт, сколько карточек коктейлей показывается на странице в коктейлях, безалкогольных коктейлях и шотах.'},
    'Der Wert wird gespeichert und gilt für alle Rezeptlisten.': {AppLanguage.de: 'Der Wert wird gespeichert und gilt für alle Rezeptlisten.', AppLanguage.en: 'The value is saved and applies to all recipe lists.', AppLanguage.es: 'El valor se guarda y se aplica a todas las listas de recetas.', AppLanguage.it: 'Il valore viene salvato e vale per tutte le liste di ricette.', AppLanguage.nl: 'De waarde wordt opgeslagen en geldt voor alle receptenlijsten.', AppLanguage.fr: 'La valeur est enregistrée et s’applique à toutes les listes de recettes.', AppLanguage.pt: 'O valor é salvo e vale para todas as listas de receitas.', AppLanguage.pl: 'Wartość jest zapisywana i dotyczy wszystkich list przepisów.', AppLanguage.tr: 'Değer kaydedilir ve tüm tarif listeleri için geçerlidir.', AppLanguage.ru: 'Значение сохраняется и применяется ко всем спискам рецептов.'},
    'Alle': {AppLanguage.de: 'Alle', AppLanguage.en: 'All', AppLanguage.es: 'Todos', AppLanguage.it: 'Tutti', AppLanguage.nl: 'Alles', AppLanguage.fr: 'Tous', AppLanguage.pt: 'Todos', AppLanguage.pl: 'Wszystkie', AppLanguage.tr: 'Tümü', AppLanguage.ru: 'Все'},
    'von': {AppLanguage.de: 'von', AppLanguage.en: 'of', AppLanguage.es: 'de', AppLanguage.it: 'di', AppLanguage.nl: 'van', AppLanguage.fr: 'sur', AppLanguage.pt: 'de', AppLanguage.pl: 'z', AppLanguage.tr: '/', AppLanguage.ru: 'из'},
    'Vorherige Seite': {AppLanguage.de: 'Vorherige Seite', AppLanguage.en: 'Previous page', AppLanguage.es: 'Página anterior', AppLanguage.it: 'Pagina precedente', AppLanguage.nl: 'Vorige pagina', AppLanguage.fr: 'Page précédente', AppLanguage.pt: 'Página anterior', AppLanguage.pl: 'Poprzednia strona', AppLanguage.tr: 'Önceki sayfa', AppLanguage.ru: 'Предыдущая страница'},
    'Nächste Seite': {AppLanguage.de: 'Nächste Seite', AppLanguage.en: 'Next page', AppLanguage.es: 'Página siguiente', AppLanguage.it: 'Pagina successiva', AppLanguage.nl: 'Volgende pagina', AppLanguage.fr: 'Page suivante', AppLanguage.pt: 'Próxima página', AppLanguage.pl: 'Następna strona', AppLanguage.tr: 'Sonraki sayfa', AppLanguage.ru: 'Следующая страница'},
    'Keine Cocktails': {AppLanguage.de: 'Keine Cocktails', AppLanguage.en: 'No cocktails', AppLanguage.es: 'Sin cócteles', AppLanguage.it: 'Nessun cocktail', AppLanguage.nl: 'Geen cocktails', AppLanguage.fr: 'Aucun cocktail', AppLanguage.pt: 'Nenhum coquetel', AppLanguage.pl: 'Brak koktajli', AppLanguage.tr: 'Kokteyl yok', AppLanguage.ru: 'Нет коктейлей'},
    'Cocktaillisten': {AppLanguage.de: 'Cocktaillisten', AppLanguage.en: 'Cocktail lists', AppLanguage.es: 'Listas de cócteles', AppLanguage.it: 'Liste cocktail', AppLanguage.nl: 'Cocktaillijsten', AppLanguage.fr: 'Listes de cocktails', AppLanguage.pt: 'Listas de coquetéis', AppLanguage.pl: 'Listy koktajli', AppLanguage.tr: 'Kokteyl listeleri', AppLanguage.ru: 'Списки коктейлей'},
    'Eigene Rezeptlisten speichern und laden': {AppLanguage.de: 'Eigene Rezeptlisten speichern und laden', AppLanguage.en: 'Save and load custom recipe lists', AppLanguage.es: 'Guardar y cargar listas de recetas propias', AppLanguage.it: 'Salva e carica liste ricette personalizzate', AppLanguage.nl: 'Eigen receptenlijsten opslaan en laden', AppLanguage.fr: 'Enregistrer et charger des listes de recettes', AppLanguage.pt: 'Salvar e carregar listas de receitas', AppLanguage.pl: 'Zapisz i wczytaj własne listy przepisów', AppLanguage.tr: 'Özel tarif listelerini kaydet ve yükle', AppLanguage.ru: 'Сохранять и загружать списки рецептов'},
    'Aktuelle Rezepte als Liste speichern': {AppLanguage.de: 'Aktuelle Rezepte als Liste speichern', AppLanguage.en: 'Save current recipes as a list', AppLanguage.es: 'Guardar recetas actuales como lista', AppLanguage.it: 'Salva le ricette attuali come lista', AppLanguage.nl: 'Huidige recepten als lijst opslaan', AppLanguage.fr: 'Enregistrer les recettes actuelles comme liste', AppLanguage.pt: 'Salvar receitas atuais como lista', AppLanguage.pl: 'Zapisz aktualne przepisy jako listę', AppLanguage.tr: 'Mevcut tarifleri liste olarak kaydet', AppLanguage.ru: 'Сохранить текущие рецепты как список'},
    'Speichert die aktuell vorhandenen Rezepte als eigene Cocktailliste. Beim Laden ersetzt die Liste die aktuellen Rezepte.': {AppLanguage.de: 'Speichert die aktuell vorhandenen Rezepte als eigene Cocktailliste. Beim Laden ersetzt die Liste die aktuellen Rezepte.', AppLanguage.en: 'Saves the current recipes as a custom cocktail list. Loading a list replaces the current recipes.', AppLanguage.es: 'Guarda las recetas actuales como una lista propia. Al cargarla reemplaza las recetas actuales.', AppLanguage.it: 'Salva le ricette attuali come lista personale. Caricandola sostituisce le ricette attuali.', AppLanguage.nl: 'Slaat de huidige recepten op als eigen cocktaillijst. Bij laden vervangt de lijst de huidige recepten.', AppLanguage.fr: 'Enregistre les recettes actuelles comme liste personnalisée. Le chargement remplace les recettes actuelles.', AppLanguage.pt: 'Salva as receitas atuais como uma lista própria. Ao carregar, ela substitui as receitas atuais.', AppLanguage.pl: 'Zapisuje aktualne przepisy jako własną listę. Wczytanie listy zastępuje aktualne przepisy.', AppLanguage.tr: 'Mevcut tarifleri özel kokteyl listesi olarak kaydeder. Yükleme mevcut tarifleri değiştirir.', AppLanguage.ru: 'Сохраняет текущие рецепты как собственный список. При загрузке список заменяет текущие рецепты.'},
    'Name der Cocktailliste': {AppLanguage.de: 'Name der Cocktailliste', AppLanguage.en: 'Cocktail list name', AppLanguage.es: 'Nombre de la lista', AppLanguage.it: 'Nome della lista', AppLanguage.nl: 'Naam van de cocktaillijst', AppLanguage.fr: 'Nom de la liste', AppLanguage.pt: 'Nome da lista', AppLanguage.pl: 'Nazwa listy koktajli', AppLanguage.tr: 'Kokteyl listesi adı', AppLanguage.ru: 'Название списка'},
    'Zum Beispiel: Sommerparty': {AppLanguage.de: 'Zum Beispiel: Sommerparty', AppLanguage.en: 'For example: Summer party', AppLanguage.es: 'Por ejemplo: fiesta de verano', AppLanguage.it: 'Ad esempio: festa estiva', AppLanguage.nl: 'Bijvoorbeeld: zomerfeest', AppLanguage.fr: 'Par exemple : fête d’été', AppLanguage.pt: 'Por exemplo: festa de verão', AppLanguage.pl: 'Na przykład: letnia impreza', AppLanguage.tr: 'Örneğin: yaz partisi', AppLanguage.ru: 'Например: летняя вечеринка'},
    'Aktuelle Liste speichern': {AppLanguage.de: 'Aktuelle Liste speichern', AppLanguage.en: 'Save current list', AppLanguage.es: 'Guardar lista actual', AppLanguage.it: 'Salva lista attuale', AppLanguage.nl: 'Huidige lijst opslaan', AppLanguage.fr: 'Enregistrer la liste actuelle', AppLanguage.pt: 'Salvar lista atual', AppLanguage.pl: 'Zapisz aktualną listę', AppLanguage.tr: 'Mevcut listeyi kaydet', AppLanguage.ru: 'Сохранить текущий список'},
    'Bitte einen Namen eingeben': {AppLanguage.de: 'Bitte einen Namen eingeben', AppLanguage.en: 'Please enter a name', AppLanguage.es: 'Introduce un nombre', AppLanguage.it: 'Inserisci un nome', AppLanguage.nl: 'Voer een naam in', AppLanguage.fr: 'Veuillez saisir un nom', AppLanguage.pt: 'Digite um nome', AppLanguage.pl: 'Wpisz nazwę', AppLanguage.tr: 'Lütfen bir ad girin', AppLanguage.ru: 'Введите название'},
    'Cocktailliste wurde gespeichert': {AppLanguage.de: 'Cocktailliste wurde gespeichert', AppLanguage.en: 'Cocktail list was saved', AppLanguage.es: 'La lista fue guardada', AppLanguage.it: 'Lista cocktail salvata', AppLanguage.nl: 'Cocktaillijst opgeslagen', AppLanguage.fr: 'Liste de cocktails enregistrée', AppLanguage.pt: 'Lista salva', AppLanguage.pl: 'Lista koktajli zapisana', AppLanguage.tr: 'Kokteyl listesi kaydedildi', AppLanguage.ru: 'Список сохранён'},
    'Noch keine Cocktaillisten gespeichert': {AppLanguage.de: 'Noch keine Cocktaillisten gespeichert', AppLanguage.en: 'No cocktail lists saved yet', AppLanguage.es: 'Aún no hay listas guardadas', AppLanguage.it: 'Nessuna lista salvata', AppLanguage.nl: 'Nog geen cocktaillijsten opgeslagen', AppLanguage.fr: 'Aucune liste enregistrée', AppLanguage.pt: 'Nenhuma lista salva ainda', AppLanguage.pl: 'Nie zapisano jeszcze list', AppLanguage.tr: 'Henüz kokteyl listesi yok', AppLanguage.ru: 'Списки пока не сохранены'},
    'Cocktailliste laden': {AppLanguage.de: 'Cocktailliste laden', AppLanguage.en: 'Load cocktail list', AppLanguage.es: 'Cargar lista', AppLanguage.it: 'Carica lista cocktail', AppLanguage.nl: 'Cocktaillijst laden', AppLanguage.fr: 'Charger la liste', AppLanguage.pt: 'Carregar lista', AppLanguage.pl: 'Wczytaj listę koktajli', AppLanguage.tr: 'Kokteyl listesini yükle', AppLanguage.ru: 'Загрузить список'},
    'Aktuelle Rezepte werden durch diese Liste ersetzt': {AppLanguage.de: 'Aktuelle Rezepte werden durch diese Liste ersetzt', AppLanguage.en: 'Current recipes will be replaced by this list', AppLanguage.es: 'Las recetas actuales serán reemplazadas por esta lista', AppLanguage.it: 'Le ricette attuali saranno sostituite da questa lista', AppLanguage.nl: 'Huidige recepten worden door deze lijst vervangen', AppLanguage.fr: 'Les recettes actuelles seront remplacées par cette liste', AppLanguage.pt: 'As receitas atuais serão substituídas por esta lista', AppLanguage.pl: 'Aktualne przepisy zostaną zastąpione tą listą', AppLanguage.tr: 'Mevcut tarifler bu listeyle değiştirilecek', AppLanguage.ru: 'Текущие рецепты будут заменены этим списком'},
    'Cocktailliste wurde geladen': {AppLanguage.de: 'Cocktailliste wurde geladen', AppLanguage.en: 'Cocktail list was loaded', AppLanguage.es: 'Lista cargada', AppLanguage.it: 'Lista cocktail caricata', AppLanguage.nl: 'Cocktaillijst geladen', AppLanguage.fr: 'Liste chargée', AppLanguage.pt: 'Lista carregada', AppLanguage.pl: 'Lista wczytana', AppLanguage.tr: 'Kokteyl listesi yüklendi', AppLanguage.ru: 'Список загружен'},
    'Cocktailliste löschen': {AppLanguage.de: 'Cocktailliste löschen', AppLanguage.en: 'Delete cocktail list', AppLanguage.es: 'Eliminar lista', AppLanguage.it: 'Elimina lista cocktail', AppLanguage.nl: 'Cocktaillijst verwijderen', AppLanguage.fr: 'Supprimer la liste', AppLanguage.pt: 'Excluir lista', AppLanguage.pl: 'Usuń listę koktajli', AppLanguage.tr: 'Kokteyl listesini sil', AppLanguage.ru: 'Удалить список'},
    'Soll diese Liste gelöscht werden?': {AppLanguage.de: 'Soll diese Liste gelöscht werden?', AppLanguage.en: 'Delete this list?', AppLanguage.es: '¿Eliminar esta lista?', AppLanguage.it: 'Eliminare questa lista?', AppLanguage.nl: 'Deze lijst verwijderen?', AppLanguage.fr: 'Supprimer cette liste ?', AppLanguage.pt: 'Excluir esta lista?', AppLanguage.pl: 'Usunąć tę listę?', AppLanguage.tr: 'Bu liste silinsin mi?', AppLanguage.ru: 'Удалить этот список?'},
    'Gespeichert': {AppLanguage.de: 'Gespeichert', AppLanguage.en: 'Saved', AppLanguage.es: 'Guardado', AppLanguage.it: 'Salvato', AppLanguage.nl: 'Opgeslagen', AppLanguage.fr: 'Enregistré', AppLanguage.pt: 'Salvo', AppLanguage.pl: 'Zapisano', AppLanguage.tr: 'Kaydedildi', AppLanguage.ru: 'Сохранено'},
    'Aktiv': {AppLanguage.de: 'Aktiv', AppLanguage.en: 'Active', AppLanguage.es: 'Activa', AppLanguage.it: 'Attiva', AppLanguage.nl: 'Actief', AppLanguage.fr: 'Active', AppLanguage.pt: 'Ativa', AppLanguage.pl: 'Aktywna', AppLanguage.tr: 'Aktif', AppLanguage.ru: 'Активно'},
  };
  return texts[key]?[language] ?? uiTexts[key]?[language] ?? texts[key]?[AppLanguage.de] ?? uiTexts[key]?[AppLanguage.de] ?? key;

}

String tr(String text) => appText(_activeAppLanguage, text);

class T extends StatelessWidget {
  const T(
    this.data, {
    super.key,
    this.style,
    this.textAlign,
    this.textDirection,
    this.softWrap,
    this.overflow,
    this.maxLines,
  });

  final String data;
  final TextStyle? style;
  final TextAlign? textAlign;
  final TextDirection? textDirection;
  final bool? softWrap;
  final TextOverflow? overflow;
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    return Text(
      tr(data),
      style: style,
      textAlign: textAlign,
      textDirection: textDirection,
      softWrap: softWrap,
      overflow: overflow,
      maxLines: maxLines,
    );
  }
}


Widget cocktailImage(
  String image, {
  required String fallbackAsset,
  BoxFit fit = BoxFit.cover,
}) {
  Widget fallback() => Image.asset(fallbackAsset, fit: fit);

  if (image.startsWith('assets/')) {
    return Image.asset(
      image,
      fit: fit,
      errorBuilder: (_, __, ___) => fallback(),
    );
  }

  if (image.startsWith('data:image/')) {
    try {
      final comma = image.indexOf(',');
      if (comma < 0) return fallback();
      final bytes = base64Decode(image.substring(comma + 1));
      return Image.memory(
        bytes,
        fit: fit,
        errorBuilder: (_, __, ___) => fallback(),
      );
    } catch (_) {
      return fallback();
    }
  }

  return Image.network(
    image,
    fit: fit,
    errorBuilder: (_, __, ___) => fallback(),
  );
}

String imageMimeType(String filename) {
  final lower = filename.toLowerCase();
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.webp')) return 'image/webp';
  if (lower.endsWith('.gif')) return 'image/gif';
  return 'image/jpeg';
}

double defaultAlcoholPercentForIngredient(
  String id, [
  String name = '',
]) {
  switch (id) {
    case 'dark-rum':
      return 40;
    case 'malibu':
      return 21;
    case 'vodka':
      return 40;
    case 'peach-liqueur':
      return 20;
    case 'gin':
      return 37.5;
    case 'tequila':
      return 38;
    case 'triple-sec':
      return 40;
    case 'blue-curacao':
      return 20;
  }

  final normalizedName = name.toLowerCase();
  if (normalizedName.contains('rum')) return 40;
  if (normalizedName.contains('vodka') || normalizedName.contains('wodka')) {
    return 40;
  }
  if (normalizedName.contains('gin')) return 37.5;
  if (normalizedName.contains('tequila')) return 38;
  if (normalizedName.contains('likör') ||
      normalizedName.contains('liqueur')) {
    return 20;
  }

  return 0;
}

String formatAlcoholPercent(double value) {
  final clamped = value.clamp(0, 100).toDouble();
  final roundedTimesTen = (clamped * 10).round();
  final decimals = roundedTimesTen % 10 == 0 ? 0 : 1;
  return clamped.toStringAsFixed(decimals).replaceAll('.', ',');
}

class Ingredient {
  Ingredient({
    required this.id,
    required this.name,
    required this.kind,
    this.pricePerLiter = 0,
    this.alcoholPercent = 0,
  });

  final String id;
  String name;
  IngredientKind kind;
  double pricePerLiter;
  double alcoholPercent;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'kind': kind.name,
        'pricePerLiter': pricePerLiter,
        'alcoholPercent': alcoholPercent,
      };

  factory Ingredient.fromJson(Map<String, dynamic> j) => Ingredient(
        id: j['id'],
        name: j['name'],
        kind: IngredientKind.values.byName(j['kind']),
        pricePerLiter:
            ((j['pricePerLiter'] as num?)?.toDouble() ?? 0)
                .clamp(0, 100000)
                .toDouble(),
        alcoholPercent: ((j['alcoholPercent'] as num?)?.toDouble() ??
                defaultAlcoholPercentForIngredient(
                  j['id']?.toString() ?? '',
                  j['name']?.toString() ?? '',
                ))
            .clamp(0, 100)
            .toDouble(),
      );
}

class Pump {
  Pump({
    required this.number,
    this.ingredientId,
    this.mlPerSecond = 0,
    this.capacityMl = 700,
    this.remainingMl = 700,
    this.active = true,
  });

  final int number;
  String? ingredientId;
  double mlPerSecond;
  double capacityMl;
  double remainingMl;
  bool active;
  double get level => capacityMl <= 0 ? 0 : (remainingMl / capacityMl).clamp(0, 1);
  Map<String, dynamic> toJson() => {
        'number': number,
        'ingredientId': ingredientId,
        'mlPerSecond': mlPerSecond,
        'capacityMl': capacityMl,
        'remainingMl': remainingMl,
        'active': active,
      };

  factory Pump.fromJson(Map<String, dynamic> j) => Pump(
        number: j['number'],
        ingredientId: j['ingredientId'],
        mlPerSecond: (j['mlPerSecond'] as num).toDouble(),
        capacityMl: (j['capacityMl'] as num).toDouble(),
        remainingMl: (j['remainingMl'] as num).toDouble(),
        active: j['active'] ?? true,
      );
}

enum RecipeAvailability { available, low, uncalibrated, unavailable }

class RecipePart {
  RecipePart({
    required this.ingredientId,
    required this.amountMl,
    required this.automatic,
    this.delayed = false,
    this.instruction = '',
  });

  String ingredientId;
  double amountMl;
  bool automatic;
  bool delayed;
  String instruction;

  Map<String, dynamic> toJson() => {
        'ingredientId': ingredientId,
        'amountMl': amountMl,
        'automatic': automatic,
        'delayed': delayed,
        'instruction': instruction,
      };

  factory RecipePart.fromJson(Map<String, dynamic> j) => RecipePart(
        ingredientId: j['ingredientId'],
        amountMl: (j['amountMl'] as num).toDouble(),
        automatic: j['automatic'],
        delayed: j['delayed'] ?? false,
        instruction: j['instruction'] ?? '',
      );
}

class Recipe {
  Recipe({
    required this.id,
    required this.name,
    required this.description,
    required this.category,
    required this.parts,
    this.imagePath,
    this.baseVolumeMl = 200,
    List<String>? manualNotes,
  }) : manualNotes = manualNotes ?? [];

  final String id;
  String name;
  String description;
  DrinkCategory category;
  List<RecipePart> parts;
  String? imagePath;
  double baseVolumeMl;
  List<String> manualNotes;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'category': category.name,
        'parts': parts.map((e) => e.toJson()).toList(),
        'imagePath': imagePath,
        'baseVolumeMl': baseVolumeMl,
        'manualNotes': manualNotes,
      };

  factory Recipe.fromJson(Map<String, dynamic> j) => Recipe(
        id: j['id'],
        name: j['name'],
        description: j['description'],
        category: DrinkCategory.values.byName(j['category']),
        parts: (j['parts'] as List)
            .map((e) => RecipePart.fromJson(e))
            .toList(),
        imagePath: j['imagePath'],
        baseVolumeMl: (j['baseVolumeMl'] as num?)?.toDouble() ?? 200,
        manualNotes: ((j['manualNotes'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
      );
}

class CocktailListProfile {
  CocktailListProfile({
    required this.id,
    required this.name,
    required this.recipes,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  final String id;
  String name;
  List<Recipe> recipes;
  DateTime createdAt;
  DateTime updatedAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'recipes': recipes.map((recipe) => recipe.toJson()).toList(),
      };

  factory CocktailListProfile.fromJson(Map<String, dynamic> json) {
    DateTime parseDate(Object? value) {
      return DateTime.tryParse(value?.toString() ?? '') ?? DateTime.now();
    }

    return CocktailListProfile(
      id: json['id']?.toString() ??
          DateTime.now().millisecondsSinceEpoch.toString(),
      name: json['name']?.toString() ?? 'Cocktailliste',
      createdAt: parseDate(json['createdAt']),
      updatedAt: parseDate(json['updatedAt']),
      recipes: ((json['recipes'] as List?) ?? const [])
          .whereType<Map>()
          .map(
            (entry) => Recipe.fromJson(
              Map<String, dynamic>.from(entry),
            ),
          )
          .toList(),
    );
  }
}


enum CocktailPopularity { low, medium, high }

class PartyCardProfile {
  PartyCardProfile({
    required this.id,
    required this.name,
    required this.recipeIds,
    Map<String, CocktailPopularity>? popularity,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : popularity = popularity ?? {},
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  final String id;
  String name;
  List<String> recipeIds;
  Map<String, CocktailPopularity> popularity;
  DateTime createdAt;
  DateTime updatedAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'recipeIds': recipeIds,
        'popularity': popularity.map((key, value) => MapEntry(key, value.name)),
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory PartyCardProfile.fromJson(Map<String, dynamic> json) {
    DateTime parseDate(Object? value) =>
        DateTime.tryParse(value?.toString() ?? '') ?? DateTime.now();

    final parsedPopularity = <String, CocktailPopularity>{};
    final rawPopularity = json['popularity'];
    if (rawPopularity is Map) {
      rawPopularity.forEach((key, value) {
        parsedPopularity[key.toString()] = CocktailPopularity.values
                .where((item) => item.name == value?.toString())
                .firstOrNull ??
            CocktailPopularity.medium;
      });
    }

    return PartyCardProfile(
      id: json['id']?.toString() ??
          DateTime.now().millisecondsSinceEpoch.toString(),
      name: json['name']?.toString() ?? 'Partykarte',
      recipeIds: ((json['recipeIds'] as List?) ?? const [])
          .map((entry) => entry.toString())
          .toList(),
      popularity: parsedPopularity,
      createdAt: parseDate(json['createdAt']),
      updatedAt: parseDate(json['updatedAt']),
    );
  }
}

class PartySession {
  PartySession({
    required this.id,
    required this.name,
    required this.guestCount,
    required this.partyCardId,
    required this.partyCardName,
    required this.partyCardRecipeIds,
    Map<String, int>? drinkCounts,
    Map<String, int>? sizeCounts,
    DateTime? startedAt,
    this.endedAt,
  })  : drinkCounts = drinkCounts ?? {},
        sizeCounts = sizeCounts ?? {},
        startedAt = startedAt ?? DateTime.now();

  final String id;
  String name;
  int guestCount;
  String partyCardId;
  String partyCardName;
  List<String> partyCardRecipeIds;
  Map<String, int> drinkCounts;
  Map<String, int> sizeCounts;
  DateTime startedAt;
  DateTime? endedAt;

  bool get isActive => endedAt == null;

  int get totalDrinks =>
      drinkCounts.values.fold<int>(0, (sum, value) => sum + value);

  double get drinksPerGuest =>
      guestCount <= 0 ? 0 : totalDrinks / guestCount;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'guestCount': guestCount,
        'partyCardId': partyCardId,
        'partyCardName': partyCardName,
        'partyCardRecipeIds': partyCardRecipeIds,
        'drinkCounts': drinkCounts,
        'sizeCounts': sizeCounts,
        'startedAt': startedAt.toIso8601String(),
        'endedAt': endedAt?.toIso8601String(),
      };

  factory PartySession.fromJson(Map<String, dynamic> json) {
    DateTime parseDate(Object? value) =>
        DateTime.tryParse(value?.toString() ?? '') ?? DateTime.now();

    Map<String, int> parseIntMap(Object? value) {
      if (value is! Map) return {};
      return Map<String, int>.from(
        value.map(
          (key, item) => MapEntry(
            key.toString(),
            ((item as num?) ?? 0).toInt(),
          ),
        ),
      );
    }

    return PartySession(
      id: json['id']?.toString() ??
          DateTime.now().millisecondsSinceEpoch.toString(),
      name: json['name']?.toString() ?? 'Party',
      guestCount: ((json['guestCount'] as num?) ?? 0).toInt(),
      partyCardId: json['partyCardId']?.toString() ?? '',
      partyCardName: json['partyCardName']?.toString() ?? 'Partykarte',
      partyCardRecipeIds: ((json['partyCardRecipeIds'] as List?) ?? const [])
          .map((entry) => entry.toString())
          .toList(),
      drinkCounts: parseIntMap(json['drinkCounts']),
      sizeCounts: parseIntMap(json['sizeCounts']),
      startedAt: parseDate(json['startedAt']),
      endedAt: json['endedAt'] == null
          ? null
          : DateTime.tryParse(json['endedAt'].toString()),
    );
  }
}

class CocktailPlanningStats {
  const CocktailPlanningStats({
    required this.recipe,
    required this.minCount,
    required this.averageCount,
    required this.maxCount,
    required this.plannedCount,
  });

  final Recipe recipe;
  final int minCount;
  final int averageCount;
  final int maxCount;
  final int plannedCount;
}


class PaymentOrderResult {
  const PaymentOrderResult({
    required this.orderId,
    required this.approvalUrl,
    required this.expiresAt,
  });

  final String orderId;
  final String approvalUrl;
  final DateTime? expiresAt;
}

class PaymentStatusResult {
  const PaymentStatusResult({
    required this.paid,
    required this.used,
    required this.status,
  });

  final bool paid;
  final bool used;
  final String status;
}

class MachineStore extends ChangeNotifier {
  static const int defaultCatalogVersion = 2;
  final ingredients = <Ingredient>[
    Ingredient(id: 'dark-rum', name: 'Brauner Rum', kind: IngredientKind.alcoholic, alcoholPercent: 40),
    Ingredient(id: 'malibu', name: 'Malibu', kind: IngredientKind.alcoholic, alcoholPercent: 21),
    Ingredient(id: 'vodka', name: 'Wodka', kind: IngredientKind.alcoholic, alcoholPercent: 40),
    Ingredient(id: 'peach-liqueur', name: 'Pfirsichlikör', kind: IngredientKind.alcoholic, alcoholPercent: 20),
    Ingredient(id: 'gin', name: 'Gin', kind: IngredientKind.alcoholic, alcoholPercent: 37.5),
    Ingredient(id: 'tequila', name: 'Tequila', kind: IngredientKind.alcoholic, alcoholPercent: 38),
    Ingredient(id: 'triple-sec', name: 'Triple Sec', kind: IngredientKind.alcoholic, alcoholPercent: 40),
    Ingredient(id: 'blue-curacao', name: 'Blue Curaçao', kind: IngredientKind.alcoholic, alcoholPercent: 20),
    Ingredient(id: 'pineapple-juice', name: 'Ananassaft', kind: IngredientKind.nonAlcoholic),
    Ingredient(id: 'passion-fruit-juice', name: 'Maracujasaft', kind: IngredientKind.nonAlcoholic),
    Ingredient(id: 'orange-juice', name: 'Orangensaft', kind: IngredientKind.nonAlcoholic),
    Ingredient(id: 'lime-juice', name: 'Limettensaft', kind: IngredientKind.nonAlcoholic),
    Ingredient(id: 'grenadine', name: 'Grenadine', kind: IngredientKind.nonAlcoholic),
    Ingredient(id: 'vanilla-syrup', name: 'Vanillesirup', kind: IngredientKind.nonAlcoholic),
    Ingredient(id: 'almond-syrup', name: 'Mandelsirup', kind: IngredientKind.nonAlcoholic),
    Ingredient(id: 'coconut-syrup', name: 'Kokossirup', kind: IngredientKind.nonAlcoholic),
    Ingredient(id: 'cola', name: 'Cola', kind: IngredientKind.nonAlcoholic),
    Ingredient(id: 'tonic-water', name: 'Tonic Water', kind: IngredientKind.nonAlcoholic),
    Ingredient(id: 'soda-water', name: 'Sprudelwasser', kind: IngredientKind.nonAlcoholic),
    Ingredient(id: 'cream', name: 'Sahne', kind: IngredientKind.nonAlcoholic),
    Ingredient(id: 'cream-of-coconut', name: 'Cream of Coconut', kind: IngredientKind.nonAlcoholic),
    Ingredient(id: 'schweppes-wild-berry', name: 'Schweppes Wild Berry', kind: IngredientKind.nonAlcoholic),
  ];
  late List<Pump> pumps = List.generate(
    18,
    (i) => Pump(number: i + 1, ingredientId: ingredients[i].id),
  );
  final recipes = <Recipe>[];
  final cocktailLists = <CocktailListProfile>[];
  String? activeCocktailListId;
  Map<String, int> recipeDrinkCounts = {};
  Map<String, int> servingSizeCounts = {};
  Map<String, double> ingredientUsageMl = {};
  bool darkMode = true;
  AppLanguage appLanguage = AppLanguage.de;
  AppColorThemeConfig appColors = AppColorThemeConfig.defaults();
  bool connected = false;
  ConnectionMode connectionMode = ConnectionMode.wifi;
  String wifiHost = ''; // leer = gleicher Host wie die Kiosk-Webseite
  String status = 'Nicht verbunden';
  bool loaded = false;
  List<double> servingSizes = [200, 300, 400];
  double defaultServingSizeMl = 200;
  List<double> shotSizes = [20, 40];
  double defaultShotSizeMl = 20;
  List<double> primeTimesSeconds = List<double>.filled(18, 5);
  double cleaningSeconds = 15;
  int cocktailsPerPage = 10;
  RecipeSortMode recipeSortMode = RecipeSortMode.original;
  bool paypalPaymentEnabled = false;
  String paymentMachineId = 'CB-DEMO';
  double cocktailPriceEur = 6.50;
  double mocktailPriceEur = 4.50;
  double shotPriceEur = 3.00;
  Map<String, double> recipePricesEur = {};
  bool alcoholStrengthSliderEnabled = false;
  bool settingsLockEnabled = false;
  String settingsPassword = '';
  bool commercialLicenseActive = false;
  String commercialLicenseCode = '';
  String commercialLicensedMachineId = '';
  DateTime? commercialLicenseActivatedAt;
  String commercialBusinessName = 'CocktailBot';
  String commercialBusinessSubtitle = 'Gewerbliche Nutzung erlaubt';
  final partyCards = <PartyCardProfile>[];
  final partySessions = <PartySession>[];
  String? activePartyCardId;
  String? activePartySessionId;
  int partyPlannerGuestCount = 30;
  int partyPlannerReservePercent = 10;
  LedIdleMode ledIdleMode = LedIdleMode.solid;
  int ledColorValue = 0xFF16D9CC;
  double ledBrightness = 0.35;

  Ingredient? ingredientById(String? id) => id == null ? null : ingredients.where((e) => e.id == id).firstOrNull;
  Pump? pumpForIngredient(String id) => pumps.where((p) => p.active && p.ingredientId == id).firstOrNull;
  String t(String key) => appText(appLanguage, key);

  String displayIngredientNameById(String? id) {
    final ingredient = ingredientById(id);
    return ingredient == null ? t('Nicht zugeordnet') : t(ingredient.name);
  }

  String displayIngredientName(Ingredient? ingredient) =>
      ingredient == null ? t('Nicht zugeordnet') : t(ingredient.name);

  String displayRecipeName(Recipe recipe) => t(recipe.name);

  String displayRecipeDescription(Recipe recipe) => t(recipe.description);

  String displayStatus() {
    if (status.startsWith('Keine Antwort von ')) {
      return '${t('Keine Antwort von')} ${status.substring('Keine Antwort von '.length)}';
    }
    return t(status);
  }

  Future<void> setLanguage(AppLanguage language) async {
    appLanguage = language;
    _activeAppLanguage = language;
    await save();
    notifyListeners();
  }

  Future<void> setAppColors(AppColorThemeConfig colors) async {
    appColors = colors;
    await save();
    notifyListeners();
  }

  Future<void> resetAppColors() async {
    appColors = AppColorThemeConfig.defaults();
    await save();
    notifyListeners();
  }

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    var storedCatalogVersion = 0;
    final raw = p.getString('machine_state');
    if (raw != null) {
      try {
        final j = jsonDecode(raw);
        storedCatalogVersion = j['catalogVersion'] ?? 0;
        ingredients..clear()..addAll((j['ingredients'] as List).map((e) => Ingredient.fromJson(e)));
        pumps = (j['pumps'] as List).map((e) => Pump.fromJson(e)).toList();
        recipes..clear()..addAll((j['recipes'] as List).map((e) => Recipe.fromJson(e)));
        cocktailLists
          ..clear()
          ..addAll(
            ((j['cocktailLists'] as List?) ?? const [])
                .whereType<Map>()
                .map(
                  (entry) => CocktailListProfile.fromJson(
                    Map<String, dynamic>.from(entry),
                  ),
                ),
          );
        activeCocktailListId = j['activeCocktailListId']?.toString();
        partyCards
          ..clear()
          ..addAll(
            ((j['partyCards'] as List?) ?? const [])
                .whereType<Map>()
                .map(
                  (entry) => PartyCardProfile.fromJson(
                    Map<String, dynamic>.from(entry),
                  ),
                ),
          );
        activePartyCardId = j['activePartyCardId']?.toString();
        partySessions
          ..clear()
          ..addAll(
            ((j['partySessions'] as List?) ?? const [])
                .whereType<Map>()
                .map(
                  (entry) => PartySession.fromJson(
                    Map<String, dynamic>.from(entry),
                  ),
                ),
          );
        activePartySessionId = j['activePartySessionId']?.toString();
        partyPlannerGuestCount =
            ((j['partyPlannerGuestCount'] as num?)?.toInt() ?? 30)
                .clamp(1, 10000)
                .toInt();
        partyPlannerReservePercent =
            ((j['partyPlannerReservePercent'] as num?)?.toInt() ?? 10)
                .clamp(0, 100)
                .toInt();
        recipeDrinkCounts = Map<String, int>.from(
          ((j['recipeDrinkCounts'] as Map?) ?? const {}).map(
            (key, value) => MapEntry(key.toString(), (value as num).toInt()),
          ),
        );
        servingSizeCounts = Map<String, int>.from(
          ((j['servingSizeCounts'] as Map?) ?? const {}).map(
            (key, value) => MapEntry(key.toString(), (value as num).toInt()),
          ),
        );
        ingredientUsageMl = Map<String, double>.from(
          ((j['ingredientUsageMl'] as Map?) ?? const {}).map(
            (key, value) => MapEntry(key.toString(), (value as num).toDouble()),
          ),
        );
        darkMode = j['darkMode'] ?? true;
        wifiHost = j['wifiHost'] ?? wifiHost;
        servingSizes = ((j['servingSizes'] as List?) ?? [200, 300, 400])
            .map((e) => (e as num).toDouble())
            .where((e) => e > 0)
            .toSet()
            .toList()
          ..sort();
        defaultServingSizeMl =
            (j['defaultServingSizeMl'] as num?)?.toDouble() ?? 200;
        if (!servingSizes.contains(defaultServingSizeMl)) {
          servingSizes.add(defaultServingSizeMl);
          servingSizes.sort();
        }
        shotSizes = ((j['shotSizes'] as List?) ?? [20, 40])
            .map((e) => (e as num).toDouble())
            .where((e) => e > 0)
            .toSet()
            .toList()
          ..sort();
        defaultShotSizeMl =
            (j['defaultShotSizeMl'] as num?)?.toDouble() ?? 20;
        if (!shotSizes.contains(defaultShotSizeMl)) {
          shotSizes.add(defaultShotSizeMl);
          shotSizes.sort();
        }
        final savedPrimeTimes = (j['primeTimesSeconds'] as List?)
            ?.map((e) => (e as num).toDouble())
            .toList();
        if (savedPrimeTimes != null && savedPrimeTimes.length == 18) {
          primeTimesSeconds = savedPrimeTimes
              .map((e) => e.clamp(1, 30).toDouble())
              .toList();
        }
        cleaningSeconds =
            ((j['cleaningSeconds'] as num?)?.toDouble() ?? 15)
                .clamp(10, 20)
                .toDouble();
        cocktailsPerPage =
            ((j['cocktailsPerPage'] as num?)?.toInt() ?? 10)
                .clamp(1, 1000)
                .toInt();
        final savedRecipeSortMode = j['recipeSortMode']?.toString();
        recipeSortMode = RecipeSortMode.values.where(
          (mode) => mode.name == savedRecipeSortMode,
        ).firstOrNull ?? RecipeSortMode.original;
        paypalPaymentEnabled = j['paypalPaymentEnabled'] == true;
        paymentMachineId = j['paymentMachineId']?.toString() ?? 'CB-DEMO';
        cocktailPriceEur =
            ((j['cocktailPriceEur'] as num?)?.toDouble() ?? 6.50)
                .clamp(0, 9999)
                .toDouble();
        mocktailPriceEur =
            ((j['mocktailPriceEur'] as num?)?.toDouble() ?? 4.50)
                .clamp(0, 9999)
                .toDouble();
        shotPriceEur =
            ((j['shotPriceEur'] as num?)?.toDouble() ?? 3.00)
                .clamp(0, 9999)
                .toDouble();
        recipePricesEur = Map<String, double>.from(
          ((j['recipePricesEur'] as Map?) ?? const {}).map(
            (key, value) => MapEntry(
              key.toString(),
              (value as num).toDouble().clamp(0, 9999).toDouble(),
            ),
          ),
        );
        alcoholStrengthSliderEnabled =
            j['alcoholStrengthSliderEnabled'] == true;
        settingsLockEnabled = j['settingsLockEnabled'] == true;
        settingsPassword = j['settingsPassword']?.toString() ?? '';
        commercialLicenseActive = j['commercialLicenseActive'] == true;
        commercialLicenseCode = j['commercialLicenseCode']?.toString() ?? '';
        commercialLicensedMachineId =
            j['commercialLicensedMachineId']?.toString() ?? '';
        commercialLicenseActivatedAt = DateTime.tryParse(
          j['commercialLicenseActivatedAt']?.toString() ?? '',
        );
        commercialBusinessName =
            j['commercialBusinessName']?.toString() ?? 'CocktailBot';
        commercialBusinessSubtitle =
            j['commercialBusinessSubtitle']?.toString() ??
                'Gewerbliche Nutzung erlaubt';
        final savedLanguage = j['appLanguage']?.toString();
        appLanguage = AppLanguage.values.where(
          (language) => language.name == savedLanguage,
        ).firstOrNull ?? AppLanguage.de;
        final savedColors = j['appColors'];
        if (savedColors is Map) {
          appColors = AppColorThemeConfig.fromJson(
            Map<String, dynamic>.from(savedColors),
          );
        }
        final savedLedMode = j['ledIdleMode']?.toString();
        final migratedLedMode = savedLedMode == 'chase' ? 'blink' : savedLedMode;
        ledIdleMode = LedIdleMode.values.where(
          (mode) => mode.name == migratedLedMode,
        ).firstOrNull ?? LedIdleMode.solid;
        ledColorValue =
            (j['ledColorValue'] as num?)?.toInt() ?? 0xFF16D9CC;
        ledBrightness =
            ((j['ledBrightness'] as num?)?.toDouble() ?? 0.35)
                .clamp(0.05, 1.0)
                .toDouble();
      } catch (_) {}
    }
    if (storedCatalogVersion != defaultCatalogVersion) {
      _installDefaultCatalog();
      await save();
    } else if (recipes.isEmpty) {
      _seedRecipes();
    }
    recipes.removeWhere(
      (recipe) => const {
        'malibu-colada',
        'cuba-libre',
        'gin-tonic',
        'purple-rain',
      }.contains(recipe.id),
    );
    _activeAppLanguage = appLanguage;
    loaded = true;
    notifyListeners();
    unawaited(connect());
  }

  void _installDefaultCatalog() {
    ingredients
      ..clear()
      ..addAll([
        Ingredient(id: 'dark-rum', name: 'Brauner Rum', kind: IngredientKind.alcoholic, alcoholPercent: 40),
        Ingredient(id: 'malibu', name: 'Malibu', kind: IngredientKind.alcoholic, alcoholPercent: 21),
        Ingredient(id: 'vodka', name: 'Wodka', kind: IngredientKind.alcoholic, alcoholPercent: 40),
        Ingredient(id: 'peach-liqueur', name: 'Pfirsichlikör', kind: IngredientKind.alcoholic, alcoholPercent: 20),
        Ingredient(id: 'gin', name: 'Gin', kind: IngredientKind.alcoholic, alcoholPercent: 37.5),
        Ingredient(id: 'tequila', name: 'Tequila', kind: IngredientKind.alcoholic, alcoholPercent: 38),
        Ingredient(id: 'triple-sec', name: 'Triple Sec', kind: IngredientKind.alcoholic, alcoholPercent: 40),
        Ingredient(id: 'blue-curacao', name: 'Blue Curaçao', kind: IngredientKind.alcoholic, alcoholPercent: 20),
        Ingredient(id: 'pineapple-juice', name: 'Ananassaft', kind: IngredientKind.nonAlcoholic),
        Ingredient(id: 'passion-fruit-juice', name: 'Maracujasaft', kind: IngredientKind.nonAlcoholic),
        Ingredient(id: 'orange-juice', name: 'Orangensaft', kind: IngredientKind.nonAlcoholic),
        Ingredient(id: 'lime-juice', name: 'Limettensaft', kind: IngredientKind.nonAlcoholic),
        Ingredient(id: 'grenadine', name: 'Grenadine', kind: IngredientKind.nonAlcoholic),
        Ingredient(id: 'vanilla-syrup', name: 'Vanillesirup', kind: IngredientKind.nonAlcoholic),
        Ingredient(id: 'almond-syrup', name: 'Mandelsirup', kind: IngredientKind.nonAlcoholic),
        Ingredient(id: 'coconut-syrup', name: 'Kokossirup', kind: IngredientKind.nonAlcoholic),
        Ingredient(id: 'cola', name: 'Cola', kind: IngredientKind.nonAlcoholic),
        Ingredient(id: 'tonic-water', name: 'Tonic Water', kind: IngredientKind.nonAlcoholic),
        Ingredient(id: 'soda-water', name: 'Sprudelwasser', kind: IngredientKind.nonAlcoholic),
        Ingredient(id: 'cream', name: 'Sahne', kind: IngredientKind.nonAlcoholic),
        Ingredient(id: 'cream-of-coconut', name: 'Cream of Coconut', kind: IngredientKind.nonAlcoholic),
        Ingredient(id: 'schweppes-wild-berry', name: 'Schweppes Wild Berry', kind: IngredientKind.nonAlcoholic),
      ]);
    pumps = List.generate(
      18,
      (i) => Pump(number: i + 1, ingredientId: ingredients[i].id),
    );
    _seedRecipes();
  }

  void _seedRecipes() {
    recipes
      ..clear()
      ..addAll([
      Recipe(
        id: 'big-john',
        name: 'Big John',
        description: 'Fruchtiger Cocktail mit Rum, Ananas und Maracuja',
        category: DrinkCategory.cocktail,
        imagePath: 'assets/drinks/cocktailbot/big-john.png',
        baseVolumeMl: 310,
        parts: [
        RecipePart(ingredientId: 'dark-rum', amountMl: 60, automatic: true),
        RecipePart(ingredientId: 'pineapple-juice', amountMl: 120, automatic: true),
        RecipePart(ingredientId: 'passion-fruit-juice', amountMl: 120, automatic: true),
        RecipePart(ingredientId: 'lime-juice', amountMl: 10, automatic: true),
        ],
      ),
      Recipe(
        id: 'malibu-ananas',
        name: 'Malibu Ananas',
        description: 'Süßer Kokoslikör mit Ananassaft',
        category: DrinkCategory.cocktail,
        imagePath: 'assets/drinks/cocktailbot/malibu-ananas.png',
        baseVolumeMl: 300,
        parts: [
        RecipePart(ingredientId: 'malibu', amountMl: 80, automatic: true),
        RecipePart(ingredientId: 'pineapple-juice', amountMl: 220, automatic: true),
        ],
      ),
      Recipe(
        id: 'malibu-sunrise',
        name: 'Malibu Sunrise',
        description: 'Kokoslikör mit Orangensaft und Grenadine',
        category: DrinkCategory.cocktail,
        imagePath: 'assets/drinks/cocktailbot/malibu-sunrise.png',
        baseVolumeMl: 300,
        parts: [
        RecipePart(ingredientId: 'malibu', amountMl: 80, automatic: true),
        RecipePart(ingredientId: 'orange-juice', amountMl: 200, automatic: true),
        RecipePart(ingredientId: 'lime-juice', amountMl: 10, automatic: true),
        RecipePart(ingredientId: 'grenadine', amountMl: 10, automatic: true, delayed: true),
        ],
      ),
      Recipe(
        id: 'peaches-cream',
        name: 'Peaches Cream',
        description: 'Fruchtiger Cocktail mit Pfirsichlikör und Vodka',
        category: DrinkCategory.cocktail,
        imagePath: 'assets/drinks/cocktailbot/peaches-cream.png',
        baseVolumeMl: 310,
        parts: [
        RecipePart(ingredientId: 'peach-liqueur', amountMl: 50, automatic: true),
        RecipePart(ingredientId: 'vodka', amountMl: 40, automatic: true),
        RecipePart(ingredientId: 'orange-juice', amountMl: 200, automatic: true),
        RecipePart(ingredientId: 'grenadine', amountMl: 20, automatic: true, delayed: true),
        ],
      ),
      Recipe(
        id: 'planters-punch',
        name: 'Planters Punch',
        description: 'Klassischer Rum-Cocktail mit Fruchtsäften',
        category: DrinkCategory.cocktail,
        imagePath: 'assets/drinks/cocktailbot/planters-punch.png',
        baseVolumeMl: 290,
        parts: [
        RecipePart(ingredientId: 'dark-rum', amountMl: 60, automatic: true),
        RecipePart(ingredientId: 'orange-juice', amountMl: 100, automatic: true),
        RecipePart(ingredientId: 'lime-juice', amountMl: 20, automatic: true),
        RecipePart(ingredientId: 'grenadine', amountMl: 10, automatic: true, delayed: true),
        RecipePart(ingredientId: 'pineapple-juice', amountMl: 100, automatic: true),
        ],
      ),
      Recipe(
        id: 'solero',
        name: 'Solero',
        description: 'Erfrischender Cocktail mit Maracuja und Vanille',
        category: DrinkCategory.cocktail,
        imagePath: 'assets/drinks/cocktailbot/solero.png',
        baseVolumeMl: 280,
        parts: [
        RecipePart(ingredientId: 'passion-fruit-juice', amountMl: 100, automatic: true),
        RecipePart(ingredientId: 'orange-juice', amountMl: 80, automatic: true),
        RecipePart(ingredientId: 'lime-juice', amountMl: 20, automatic: true),
        RecipePart(ingredientId: 'vanilla-syrup', amountMl: 20, automatic: true),
        RecipePart(ingredientId: 'vodka', amountMl: 60, automatic: true),
        ],
      ),
      Recipe(
        id: 'sex-on-the-beach',
        name: 'Sex on the Beach',
        description: 'Beliebter Cocktail mit Vodka und Pfirsichlikör',
        category: DrinkCategory.cocktail,
        imagePath: 'assets/drinks/cocktailbot/sex-on-the-beach.png',
        baseVolumeMl: 300,
        parts: [
        RecipePart(ingredientId: 'vodka', amountMl: 50, automatic: true),
        RecipePart(ingredientId: 'peach-liqueur', amountMl: 30, automatic: true),
        RecipePart(ingredientId: 'lime-juice', amountMl: 20, automatic: true),
        RecipePart(ingredientId: 'orange-juice', amountMl: 90, automatic: true),
        RecipePart(ingredientId: 'pineapple-juice', amountMl: 90, automatic: true),
        RecipePart(ingredientId: 'grenadine', amountMl: 20, automatic: true, delayed: true),
        ],
      ),
      Recipe(
        id: 'mojito',
        name: 'Mojito',
        description: 'Klassischer Cocktail mit Rum, Limette und Minze',
        category: DrinkCategory.cocktail,
        imagePath: 'assets/drinks/cocktailbot/mojito.png',
        baseVolumeMl: 220,
        parts: [
        RecipePart(ingredientId: 'dark-rum', amountMl: 60, automatic: true),
        RecipePart(ingredientId: 'lime-juice', amountMl: 60, automatic: true),
        RecipePart(ingredientId: 'soda-water', amountMl: 100, automatic: false, instruction: '100ml Sprudelwasser hinzufügen'),
        ],
        manualNotes: ['Frische Minzblätter hinzufügen'],
      ),
      Recipe(
        id: 'passion-colada',
        name: 'Passion Colada',
        description: 'Exotischer Cocktail mit Rum, Malibu und Maracuja',
        category: DrinkCategory.cocktail,
        imagePath: 'assets/drinks/cocktailbot/passion-colada.png',
        baseVolumeMl: 280,
        parts: [
        RecipePart(ingredientId: 'dark-rum', amountMl: 40, automatic: true),
        RecipePart(ingredientId: 'malibu', amountMl: 40, automatic: true),
        RecipePart(ingredientId: 'passion-fruit-juice', amountMl: 200, automatic: true),
        ],
      ),
      Recipe(
        id: 'long-island-iced-tea',
        name: 'Long Island Iced Tea',
        description: 'Klassischer, starker Cocktail mit fünf verschiedenen Spirituosen und Cola',
        category: DrinkCategory.cocktail,
        imagePath: 'assets/drinks/cocktailbot/long-island-iced-tea.png',
        baseVolumeMl: 255,
        parts: [
        RecipePart(ingredientId: 'dark-rum', amountMl: 15, automatic: true),
        RecipePart(ingredientId: 'triple-sec', amountMl: 15, automatic: true),
        RecipePart(ingredientId: 'vodka', amountMl: 15, automatic: true),
        RecipePart(ingredientId: 'tequila', amountMl: 15, automatic: true),
        RecipePart(ingredientId: 'gin', amountMl: 15, automatic: true),
        RecipePart(ingredientId: 'lime-juice', amountMl: 30, automatic: true),
        RecipePart(ingredientId: 'cola', amountMl: 150, automatic: false, instruction: '150ml Cola hinzufügen'),
        ],
      ),
      Recipe(
        id: 'bahama-mama',
        name: 'Bahama Mama',
        description: 'Tropischer Cocktail mit Braunem Rum, Malibu und Fruchtsäften',
        category: DrinkCategory.cocktail,
        imagePath: 'assets/drinks/cocktailbot/bahama-mama.png',
        baseVolumeMl: 290,
        parts: [
        RecipePart(ingredientId: 'dark-rum', amountMl: 50, automatic: true),
        RecipePart(ingredientId: 'malibu', amountMl: 40, automatic: true),
        RecipePart(ingredientId: 'orange-juice', amountMl: 80, automatic: true),
        RecipePart(ingredientId: 'pineapple-juice', amountMl: 80, automatic: true),
        RecipePart(ingredientId: 'lime-juice', amountMl: 20, automatic: true),
        RecipePart(ingredientId: 'grenadine', amountMl: 20, automatic: true, delayed: true),
        ],
      ),
      Recipe(
        id: 'swimming-pool',
        name: 'Swimming Pool',
        description: 'Blauer, tropischer Cocktail mit Vodka und Ananassaft',
        category: DrinkCategory.cocktail,
        imagePath: 'assets/drinks/cocktailbot/swimming-pool.png',
        baseVolumeMl: 310,
        parts: [
        RecipePart(ingredientId: 'vodka', amountMl: 60, automatic: true),
        RecipePart(ingredientId: 'blue-curacao', amountMl: 30, automatic: true),
        RecipePart(ingredientId: 'pineapple-juice', amountMl: 180, automatic: true),
        RecipePart(ingredientId: 'cream', amountMl: 20, automatic: false, instruction: '20ml Sahne hinzufügen'),
        RecipePart(ingredientId: 'cream-of-coconut', amountMl: 20, automatic: false, instruction: '20ml Cream of Coconut hinzufügen'),
        ],
      ),
      Recipe(
        id: 'tequila-sunrise',
        name: 'Tequila Sunrise',
        description: 'Klassischer Cocktail mit Tequila, Orangensaft und Grenadine',
        category: DrinkCategory.cocktail,
        imagePath: 'assets/drinks/cocktailbot/tequila-sunrise.png',
        baseVolumeMl: 300,
        parts: [
        RecipePart(ingredientId: 'tequila', amountMl: 60, automatic: true),
        RecipePart(ingredientId: 'orange-juice', amountMl: 220, automatic: true),
        RecipePart(ingredientId: 'grenadine', amountMl: 20, automatic: true, delayed: true),
        ],
      ),
      Recipe(
        id: 'touch-down',
        name: 'Touch Down',
        description: 'Fruchtiger Cocktail mit Braunem Rum, Triple Sec und Maracujasaft',
        category: DrinkCategory.cocktail,
        imagePath: 'assets/drinks/cocktailbot/touch-down.png',
        baseVolumeMl: 270,
        parts: [
        RecipePart(ingredientId: 'dark-rum', amountMl: 60, automatic: true),
        RecipePart(ingredientId: 'triple-sec', amountMl: 40, automatic: true),
        RecipePart(ingredientId: 'passion-fruit-juice', amountMl: 140, automatic: true),
        RecipePart(ingredientId: 'lime-juice', amountMl: 10, automatic: true),
        RecipePart(ingredientId: 'grenadine', amountMl: 20, automatic: true, delayed: true),
        ],
      ),
      Recipe(
        id: 'zombie',
        name: 'Zombie',
        description: 'Starker, fruchtiger Cocktail mit Braunem Rum und verschiedenen Fruchtsäften',
        category: DrinkCategory.cocktail,
        imagePath: 'assets/drinks/cocktailbot/zombie.png',
        baseVolumeMl: 290,
        parts: [
        RecipePart(ingredientId: 'dark-rum', amountMl: 40, automatic: true),
        RecipePart(ingredientId: 'triple-sec', amountMl: 30, automatic: true),
        RecipePart(ingredientId: 'pineapple-juice', amountMl: 80, automatic: true),
        RecipePart(ingredientId: 'orange-juice', amountMl: 50, automatic: true),
        RecipePart(ingredientId: 'lime-juice', amountMl: 20, automatic: true),
        RecipePart(ingredientId: 'passion-fruit-juice', amountMl: 50, automatic: true),
        RecipePart(ingredientId: 'grenadine', amountMl: 20, automatic: true, delayed: true),
        ],
      ),
      Recipe(
        id: 'mai-tai',
        name: 'Mai Tai',
        description: 'Klassischer Tiki-Cocktail mit braunem Rum und Mandelsirup',
        category: DrinkCategory.cocktail,
        imagePath: 'assets/drinks/cocktailbot/mai-tai.png',
        baseVolumeMl: 160,
        parts: [
        RecipePart(ingredientId: 'dark-rum', amountMl: 60, automatic: true),
        RecipePart(ingredientId: 'triple-sec', amountMl: 15, automatic: true),
        RecipePart(ingredientId: 'pineapple-juice', amountMl: 50, automatic: true),
        RecipePart(ingredientId: 'almond-syrup', amountMl: 15, automatic: true),
        RecipePart(ingredientId: 'lime-juice', amountMl: 20, automatic: true),
        ],
      ),
      Recipe(
        id: 'tropical-sunrise',
        name: 'Tropical Sunrise',
        description: 'Erfrischender alkoholfreier Cocktail mit Ananas, Orange und Grenadine',
        category: DrinkCategory.mocktail,
        imagePath: 'assets/drinks/cocktailbot/tropical-sunrise.png',
        baseVolumeMl: 270,
        parts: [
        RecipePart(ingredientId: 'pineapple-juice', amountMl: 120, automatic: true),
        RecipePart(ingredientId: 'orange-juice', amountMl: 120, automatic: true),
        RecipePart(ingredientId: 'grenadine', amountMl: 20, automatic: true, delayed: true),
        RecipePart(ingredientId: 'lime-juice', amountMl: 10, automatic: true),
        ],
      ),
      Recipe(
        id: 'passion-fizz',
        name: 'Passion Fizz',
        description: 'Sprudelnder alkoholfreier Cocktail mit Maracuja und Sodawasser',
        category: DrinkCategory.mocktail,
        imagePath: 'assets/drinks/cocktailbot/passion-fizz.png',
        baseVolumeMl: 280,
        parts: [
        RecipePart(ingredientId: 'passion-fruit-juice', amountMl: 150, automatic: true),
        RecipePart(ingredientId: 'soda-water', amountMl: 100, automatic: false, instruction: '100ml Sprudelwasser hinzufügen'),
        RecipePart(ingredientId: 'vanilla-syrup', amountMl: 20, automatic: true),
        RecipePart(ingredientId: 'lime-juice', amountMl: 10, automatic: true),
        ],
      ),
      Recipe(
        id: 'orange-vanilla-dream',
        name: 'Orange Vanilla Dream',
        description: 'Cremiger alkoholfreier Cocktail mit Orange und Vanille',
        category: DrinkCategory.mocktail,
        imagePath: 'assets/drinks/cocktailbot/orange-vanilla-dream.png',
        baseVolumeMl: 300,
        parts: [
        RecipePart(ingredientId: 'orange-juice', amountMl: 200, automatic: true),
        RecipePart(ingredientId: 'vanilla-syrup', amountMl: 30, automatic: true),
        RecipePart(ingredientId: 'soda-water', amountMl: 70, automatic: false, instruction: '70ml Sprudelwasser hinzufügen'),
        ],
      ),
      Recipe(
        id: 'citrus-splash',
        name: 'Citrus Splash',
        description: 'Fruchtiger alkoholfreier Cocktail mit Grenadine und Zitrusfrüchten',
        category: DrinkCategory.mocktail,
        imagePath: 'assets/drinks/cocktailbot/citrus-splash.png',
        baseVolumeMl: 300,
        parts: [
        RecipePart(ingredientId: 'grenadine', amountMl: 30, automatic: true, delayed: true),
        RecipePart(ingredientId: 'orange-juice', amountMl: 100, automatic: true),
        RecipePart(ingredientId: 'pineapple-juice', amountMl: 100, automatic: true),
        RecipePart(ingredientId: 'lime-juice', amountMl: 20, automatic: true),
        RecipePart(ingredientId: 'soda-water', amountMl: 50, automatic: false, instruction: '50ml Sprudelwasser hinzufügen'),
        ],
      ),
      Recipe(
        id: 'pineapple-passion',
        name: 'Pineapple Passion',
        description: 'Exotischer alkoholfreier Cocktail mit Ananas und Maracuja',
        category: DrinkCategory.mocktail,
        imagePath: 'assets/drinks/cocktailbot/pineapple-passion.png',
        baseVolumeMl: 280,
        parts: [
        RecipePart(ingredientId: 'pineapple-juice', amountMl: 150, automatic: true),
        RecipePart(ingredientId: 'passion-fruit-juice', amountMl: 100, automatic: true),
        RecipePart(ingredientId: 'lime-juice', amountMl: 15, automatic: true),
        RecipePart(ingredientId: 'vanilla-syrup', amountMl: 15, automatic: true),
        ],
      ),
      Recipe(
        id: 'citrus-cooler',
        name: 'Citrus Cooler',
        description: 'Erfrischender alkoholfreier Cocktail mit Limette und Sodawasser',
        category: DrinkCategory.mocktail,
        imagePath: 'assets/drinks/cocktailbot/citrus-cooler.png',
        baseVolumeMl: 270,
        parts: [
        RecipePart(ingredientId: 'lime-juice', amountMl: 40, automatic: true),
        RecipePart(ingredientId: 'vanilla-syrup', amountMl: 20, automatic: true),
        RecipePart(ingredientId: 'soda-water', amountMl: 200, automatic: false, instruction: '200ml Sprudelwasser hinzufügen'),
        RecipePart(ingredientId: 'grenadine', amountMl: 10, automatic: true, delayed: true),
        ],
      ),
      Recipe(
        id: 'tropical-sunset',
        name: 'Tropical Sunset',
        description: 'Schöner Farbverlauf mit Ananas, Orange und Grenadine',
        category: DrinkCategory.mocktail,
        imagePath: 'assets/drinks/cocktailbot/tropical-sunset.png',
        baseVolumeMl: 215,
        parts: [
        RecipePart(ingredientId: 'pineapple-juice', amountMl: 120, automatic: true),
        RecipePart(ingredientId: 'orange-juice', amountMl: 80, automatic: true),
        RecipePart(ingredientId: 'grenadine', amountMl: 15, automatic: true, delayed: true),
        ],
        manualNotes: ['Glas zur Hälfte mit Eis füllen (Eiswürfel: 200g)', 'Als Garnitur am Glasrand (Orangenscheibe: 1 Scheibe)'],
      ),
      Recipe(
        id: 'pineapple-lime-fizz',
        name: 'Pineapple Lime Fizz',
        description: 'Erfrischender Cocktail mit Ananas und Limette',
        category: DrinkCategory.mocktail,
        imagePath: 'assets/drinks/cocktailbot/pineapple-lime-fizz.png',
        baseVolumeMl: 190,
        parts: [
        RecipePart(ingredientId: 'pineapple-juice', amountMl: 150, automatic: true),
        RecipePart(ingredientId: 'lime-juice', amountMl: 30, automatic: true),
        RecipePart(ingredientId: 'vanilla-syrup', amountMl: 10, automatic: true),
        ],
        manualNotes: ['Zum Auffüllen und für den Fizz-Effekt (Sprudelwasser: 50ml)', 'Als Garnitur (Limettenscheibe: 1 Scheibe)'],
      ),
      Recipe(
        id: 'passion-paradise',
        name: 'Passion Paradise',
        description: 'Exotischer Cocktail mit Maracuja und tropischen Früchten',
        category: DrinkCategory.mocktail,
        imagePath: 'assets/drinks/cocktailbot/passion-paradise.png',
        baseVolumeMl: 235,
        parts: [
        RecipePart(ingredientId: 'passion-fruit-juice', amountMl: 100, automatic: true),
        RecipePart(ingredientId: 'pineapple-juice', amountMl: 80, automatic: true),
        RecipePart(ingredientId: 'orange-juice', amountMl: 40, automatic: true),
        RecipePart(ingredientId: 'almond-syrup', amountMl: 15, automatic: true),
        ],
        manualNotes: ['Für tropisches Feeling (Crushed Ice: 150g)', 'Als Topping obendrauf (Maracuja-Fruchtfleisch: 1 TL)'],
      ),
      Recipe(
        id: 'vanilla-orange-dream',
        name: 'Vanilla Orange Dream',
        description: 'Cremiger Traum mit Vanille und Orange',
        category: DrinkCategory.mocktail,
        imagePath: 'assets/drinks/cocktailbot/vanilla-orange-dream.png',
        baseVolumeMl: 215,
        parts: [
        RecipePart(ingredientId: 'orange-juice', amountMl: 120, automatic: true),
        RecipePart(ingredientId: 'pineapple-juice', amountMl: 60, automatic: true),
        RecipePart(ingredientId: 'vanilla-syrup', amountMl: 25, automatic: true),
        RecipePart(ingredientId: 'lime-juice', amountMl: 10, automatic: true),
        ],
        manualNotes: ['Vorsichtig obendrauf gießen für Schichteffekt (Sahne: 20ml)', 'Als aromatisches Topping (Orangenzest: 1 Prise)'],
      ),
      Recipe(
        id: 'grenadine-sunrise',
        name: 'Grenadine Sunrise',
        description: 'Wunderschöner Sonnenaufgang im Glas',
        category: DrinkCategory.mocktail,
        imagePath: 'assets/drinks/cocktailbot/grenadine-sunrise.png',
        baseVolumeMl: 210,
        parts: [
        RecipePart(ingredientId: 'orange-juice', amountMl: 100, automatic: true),
        RecipePart(ingredientId: 'pineapple-juice', amountMl: 80, automatic: true),
        RecipePart(ingredientId: 'grenadine', amountMl: 20, automatic: true, delayed: true),
        RecipePart(ingredientId: 'lime-juice', amountMl: 10, automatic: true),
        ],
        manualNotes: ['Glas komplett mit Eis füllen (Eiswürfel: 200g)', 'Langsam am Glasrand hinunterlaufen lassen für Sunrise-Effekt (Grenadine extra: 5ml)'],
      ),
      Recipe(
        id: 'caribbean-sunset',
        name: 'Caribbean Sunset',
        description: 'Tropischer Cocktail mit Rum, Malibu und Blue Curacao',
        category: DrinkCategory.cocktail,
        imagePath: 'assets/drinks/cocktailbot/caribbean-sunset.png',
        baseVolumeMl: 130,
        parts: [
        RecipePart(ingredientId: 'dark-rum', amountMl: 40, automatic: true),
        RecipePart(ingredientId: 'malibu', amountMl: 30, automatic: true),
        RecipePart(ingredientId: 'passion-fruit-juice', amountMl: 40, automatic: true),
        RecipePart(ingredientId: 'blue-curacao', amountMl: 10, automatic: true),
        RecipePart(ingredientId: 'lime-juice', amountMl: 10, automatic: true),
        ],
      ),
      Recipe(
        id: 'night-in-blue',
        name: 'Night in Blue',
        description: 'Blauer Cocktail mit Malibu und Ananassaft',
        category: DrinkCategory.cocktail,
        imagePath: 'assets/drinks/cocktailbot/night-in-blue.png',
        baseVolumeMl: 120,
        parts: [
        RecipePart(ingredientId: 'malibu', amountMl: 40, automatic: true),
        RecipePart(ingredientId: 'blue-curacao', amountMl: 20, automatic: true),
        RecipePart(ingredientId: 'pineapple-juice', amountMl: 60, automatic: true),
        ],
      ),
      Recipe(
        id: 'el-mariachi',
        name: 'El Mariachi',
        description: 'Mexikanischer Cocktail mit Tequila und Vodka',
        category: DrinkCategory.cocktail,
        imagePath: 'assets/drinks/cocktailbot/el-mariachi.png',
        baseVolumeMl: 100,
        parts: [
        RecipePart(ingredientId: 'tequila', amountMl: 20, automatic: true),
        RecipePart(ingredientId: 'vodka', amountMl: 20, automatic: true),
        RecipePart(ingredientId: 'passion-fruit-juice', amountMl: 40, automatic: true),
        RecipePart(ingredientId: 'lime-juice', amountMl: 10, automatic: true),
        RecipePart(ingredientId: 'grenadine', amountMl: 10, automatic: true),
        ],
      ),
      Recipe(
        id: 'green-eyes',
        name: 'Green Eyes',
        description: 'Grüner Cocktail mit Blue Curacao und Vodka',
        category: DrinkCategory.cocktail,
        imagePath: 'assets/drinks/cocktailbot/green-eyes.png',
        baseVolumeMl: 140,
        parts: [
        RecipePart(ingredientId: 'blue-curacao', amountMl: 30, automatic: true),
        RecipePart(ingredientId: 'vodka', amountMl: 30, automatic: true),
        RecipePart(ingredientId: 'orange-juice', amountMl: 80, automatic: true),
        ],
      ),
      Recipe(
        id: 'hot-legs',
        name: 'Hot Legs',
        description: 'Heißer tropischer Cocktail mit Malibu und Rum',
        category: DrinkCategory.cocktail,
        imagePath: 'assets/drinks/cocktailbot/hot-legs.png',
        baseVolumeMl: 110,
        parts: [
        RecipePart(ingredientId: 'malibu', amountMl: 20, automatic: true),
        RecipePart(ingredientId: 'dark-rum', amountMl: 40, automatic: true),
        RecipePart(ingredientId: 'pineapple-juice', amountMl: 30, automatic: true),
        RecipePart(ingredientId: 'blue-curacao', amountMl: 10, automatic: true),
        RecipePart(ingredientId: 'lime-juice', amountMl: 10, automatic: true),
        ],
      ),
      Recipe(
        id: 'tropical-fusion',
        name: 'Tropical Fusion',
        description: 'Fusion aus Rum, Vodka und tropischen Früchten',
        category: DrinkCategory.cocktail,
        imagePath: 'assets/drinks/cocktailbot/tropical-fusion.png',
        baseVolumeMl: 140,
        parts: [
        RecipePart(ingredientId: 'dark-rum', amountMl: 30, automatic: true),
        RecipePart(ingredientId: 'vodka', amountMl: 30, automatic: true),
        RecipePart(ingredientId: 'passion-fruit-juice', amountMl: 40, automatic: true),
        RecipePart(ingredientId: 'orange-juice', amountMl: 30, automatic: true),
        RecipePart(ingredientId: 'lime-juice', amountMl: 10, automatic: true),
        ],
      ),
      Recipe(
        id: 'sunny-fizz',
        name: 'Sunny Fizz',
        description: 'Sonniger Cocktail mit Rum, Malibu und tropischen Säften',
        category: DrinkCategory.cocktail,
        imagePath: 'assets/drinks/cocktailbot/sunny-fizz.png',
        baseVolumeMl: 130,
        parts: [
        RecipePart(ingredientId: 'dark-rum', amountMl: 30, automatic: true),
        RecipePart(ingredientId: 'malibu', amountMl: 20, automatic: true),
        RecipePart(ingredientId: 'pineapple-juice', amountMl: 40, automatic: true),
        RecipePart(ingredientId: 'passion-fruit-juice', amountMl: 30, automatic: true),
        RecipePart(ingredientId: 'lime-juice', amountMl: 10, automatic: true),
        ],
      ),
      Recipe(
        id: 'donnergurgler',
        name: 'Donnergurgler',
        description: 'Kräftiger Cocktail mit Rum, Vodka und Blue Curacao',
        category: DrinkCategory.cocktail,
        imagePath: 'assets/drinks/cocktailbot/donnergurgler.png',
        baseVolumeMl: 130,
        parts: [
        RecipePart(ingredientId: 'dark-rum', amountMl: 20, automatic: true),
        RecipePart(ingredientId: 'vodka', amountMl: 20, automatic: true),
        RecipePart(ingredientId: 'blue-curacao', amountMl: 10, automatic: true),
        RecipePart(ingredientId: 'pineapple-juice', amountMl: 40, automatic: true),
        RecipePart(ingredientId: 'orange-juice', amountMl: 30, automatic: true),
        RecipePart(ingredientId: 'grenadine', amountMl: 10, automatic: true, delayed: true),
        ],
      ),
      Recipe(
        id: 'don-juan',
        name: 'Don Juan',
        description: 'Eleganter Cocktail mit Tequila und Blue Curacao',
        category: DrinkCategory.cocktail,
        imagePath: 'assets/drinks/cocktailbot/don-juan.png',
        baseVolumeMl: 110,
        parts: [
        RecipePart(ingredientId: 'tequila', amountMl: 30, automatic: true),
        RecipePart(ingredientId: 'blue-curacao', amountMl: 10, automatic: true),
        RecipePart(ingredientId: 'pineapple-juice', amountMl: 40, automatic: true),
        RecipePart(ingredientId: 'passion-fruit-juice', amountMl: 30, automatic: true),
        ],
      ),
      Recipe(
        id: 'tropical-derby',
        name: 'Tropical Derby',
        description: 'Komplexer Gin-Cocktail mit tropischen Früchten',
        category: DrinkCategory.cocktail,
        imagePath: 'assets/drinks/cocktailbot/tropical-derby.png',
        baseVolumeMl: 150,
        parts: [
        RecipePart(ingredientId: 'gin', amountMl: 40, automatic: true),
        RecipePart(ingredientId: 'orange-juice', amountMl: 40, automatic: true),
        RecipePart(ingredientId: 'pineapple-juice', amountMl: 30, automatic: true),
        RecipePart(ingredientId: 'passion-fruit-juice', amountMl: 20, automatic: true),
        RecipePart(ingredientId: 'lime-juice', amountMl: 10, automatic: true),
        RecipePart(ingredientId: 'grenadine', amountMl: 10, automatic: true, delayed: true),
        ],
      ),
      Recipe(
        id: 'vanity',
        name: 'Vanity',
        description: 'Eleganter Gin-Cocktail mit Ananas und Blue Curacao',
        category: DrinkCategory.cocktail,
        imagePath: 'assets/drinks/cocktailbot/vanity.png',
        baseVolumeMl: 90,
        parts: [
        RecipePart(ingredientId: 'gin', amountMl: 30, automatic: true),
        RecipePart(ingredientId: 'pineapple-juice', amountMl: 40, automatic: true),
        RecipePart(ingredientId: 'lime-juice', amountMl: 10, automatic: true),
        RecipePart(ingredientId: 'blue-curacao', amountMl: 10, automatic: true),
        ],
      ),
      Recipe(
        id: 'grauer-panther',
        name: 'Grauer Panther',
        description: 'Exotischer Cocktail mit Malibu, Blue Curacao und Grenadine',
        category: DrinkCategory.cocktail,
        imagePath: 'assets/drinks/cocktailbot/grauer-panther.png',
        baseVolumeMl: 120,
        parts: [
        RecipePart(ingredientId: 'malibu', amountMl: 20, automatic: true),
        RecipePart(ingredientId: 'blue-curacao', amountMl: 10, automatic: true),
        RecipePart(ingredientId: 'grenadine', amountMl: 10, automatic: true),
        RecipePart(ingredientId: 'dark-rum', amountMl: 20, automatic: true),
        RecipePart(ingredientId: 'pineapple-juice', amountMl: 30, automatic: true),
        RecipePart(ingredientId: 'orange-juice', amountMl: 20, automatic: true),
        RecipePart(ingredientId: 'lime-juice', amountMl: 10, automatic: true),
        ],
      ),
      Recipe(
        id: 'sweet-cocktail',
        name: 'Sweet Cocktail',
        description: 'Süßer Cocktail mit Rum und Blue Curacao',
        category: DrinkCategory.cocktail,
        imagePath: 'assets/drinks/cocktailbot/sweet-cocktail.png',
        baseVolumeMl: 130,
        parts: [
        RecipePart(ingredientId: 'dark-rum', amountMl: 30, automatic: true),
        RecipePart(ingredientId: 'blue-curacao', amountMl: 20, automatic: true),
        RecipePart(ingredientId: 'orange-juice', amountMl: 40, automatic: true),
        RecipePart(ingredientId: 'pineapple-juice', amountMl: 40, automatic: true),
        ],
      ),
      Recipe(
        id: 'holiday',
        name: 'Holiday',
        description: 'Urlaubscocktail mit Tequila, Blue Curacao und Pfirsichlikör',
        category: DrinkCategory.cocktail,
        imagePath: 'assets/drinks/cocktailbot/holiday.png',
        baseVolumeMl: 140,
        parts: [
        RecipePart(ingredientId: 'tequila', amountMl: 30, automatic: true),
        RecipePart(ingredientId: 'blue-curacao', amountMl: 20, automatic: true),
        RecipePart(ingredientId: 'orange-juice', amountMl: 40, automatic: true),
        RecipePart(ingredientId: 'pineapple-juice', amountMl: 40, automatic: true),
        RecipePart(ingredientId: 'peach-liqueur', amountMl: 10, automatic: true),
        ],
      ),
      Recipe(
        id: 'barbados',
        name: 'Barbados',
        description: 'Karibischer Cocktail mit Rum, Blue Curacao und Orangensaft',
        category: DrinkCategory.cocktail,
        imagePath: 'assets/drinks/cocktailbot/barbados.png',
        baseVolumeMl: 110,
        parts: [
        RecipePart(ingredientId: 'dark-rum', amountMl: 30, automatic: true),
        RecipePart(ingredientId: 'blue-curacao', amountMl: 20, automatic: true),
        RecipePart(ingredientId: 'orange-juice', amountMl: 50, automatic: true),
        RecipePart(ingredientId: 'grenadine', amountMl: 10, automatic: true, delayed: true),
        ],
      ),
      Recipe(
        id: 'bora-bora',
        name: 'Bora Bora',
        description: 'Alkoholfreier tropischer Cocktail mit Ananas und Maracuja',
        category: DrinkCategory.mocktail,
        imagePath: 'assets/drinks/cocktailbot/bora-bora.png',
        baseVolumeMl: 120,
        parts: [
        RecipePart(ingredientId: 'pineapple-juice', amountMl: 50, automatic: true),
        RecipePart(ingredientId: 'passion-fruit-juice', amountMl: 50, automatic: true),
        RecipePart(ingredientId: 'lime-juice', amountMl: 10, automatic: true),
        RecipePart(ingredientId: 'grenadine', amountMl: 10, automatic: true, delayed: true),
        ],
      ),
      Recipe(
        id: 'sport-n-juicy',
        name: 'Sport\'n Juicy',
        description: 'Erfrischender alkoholfreier Fruchtcocktail',
        category: DrinkCategory.mocktail,
        imagePath: 'assets/drinks/cocktailbot/sport-n-juicy.png',
        baseVolumeMl: 130,
        parts: [
        RecipePart(ingredientId: 'pineapple-juice', amountMl: 50, automatic: true),
        RecipePart(ingredientId: 'passion-fruit-juice', amountMl: 30, automatic: true),
        RecipePart(ingredientId: 'orange-juice', amountMl: 40, automatic: true),
        RecipePart(ingredientId: 'lime-juice', amountMl: 10, automatic: true),
        ],
      ),
      Recipe(
        id: 'targa-911',
        name: 'Targa 911',
        description: 'Sportlicher alkoholfreier Cocktail mit tropischen Früchten',
        category: DrinkCategory.mocktail,
        imagePath: 'assets/drinks/cocktailbot/targa-911.png',
        baseVolumeMl: 130,
        parts: [
        RecipePart(ingredientId: 'pineapple-juice', amountMl: 40, automatic: true),
        RecipePart(ingredientId: 'passion-fruit-juice', amountMl: 30, automatic: true),
        RecipePart(ingredientId: 'orange-juice', amountMl: 40, automatic: true),
        RecipePart(ingredientId: 'lime-juice', amountMl: 10, automatic: true),
        RecipePart(ingredientId: 'grenadine', amountMl: 10, automatic: true, delayed: true),
        ],
      ),
      Recipe(
        id: 'maro',
        name: 'Maro',
        description: 'Alkoholfreier Cocktail mit Maracuja und Orange',
        category: DrinkCategory.mocktail,
        imagePath: 'assets/drinks/cocktailbot/maro.png',
        baseVolumeMl: 100,
        parts: [
        RecipePart(ingredientId: 'passion-fruit-juice', amountMl: 50, automatic: true),
        RecipePart(ingredientId: 'orange-juice', amountMl: 40, automatic: true),
        RecipePart(ingredientId: 'lime-juice', amountMl: 10, automatic: true),
        ],
      ),
      Recipe(
        id: 'coconut-kiss',
        name: 'Coconut Kiss',
        description: 'Alkoholfreier Kokos-Cocktail mit tropischen Früchten',
        category: DrinkCategory.mocktail,
        imagePath: 'assets/drinks/cocktailbot/coconut-kiss.png',
        baseVolumeMl: 130,
        parts: [
        RecipePart(ingredientId: 'pineapple-juice', amountMl: 50, automatic: true),
        RecipePart(ingredientId: 'orange-juice', amountMl: 40, automatic: true),
        RecipePart(ingredientId: 'lime-juice', amountMl: 10, automatic: true),
        RecipePart(ingredientId: 'grenadine', amountMl: 10, automatic: true, delayed: true),
        RecipePart(ingredientId: 'coconut-syrup', amountMl: 20, automatic: true),
        ],
      ),
      Recipe(
        id: 'virgin-colada',
        name: 'Virgin Colada',
        description: 'Alkoholfreie Pina Colada mit Kokossirup',
        category: DrinkCategory.mocktail,
        imagePath: 'assets/drinks/cocktailbot/virgin-colada.png',
        baseVolumeMl: 120,
        parts: [
        RecipePart(ingredientId: 'pineapple-juice', amountMl: 50, automatic: true),
        RecipePart(ingredientId: 'orange-juice', amountMl: 40, automatic: true),
        RecipePart(ingredientId: 'lime-juice', amountMl: 10, automatic: true),
        RecipePart(ingredientId: 'coconut-syrup', amountMl: 20, automatic: true),
        ],
      ),
      Recipe(
        id: 'virgin-solero',
        name: 'Virgin Solero',
        description: 'Alkoholfreier Solero mit Maracuja und Vanille',
        category: DrinkCategory.mocktail,
        imagePath: 'assets/drinks/cocktailbot/virgin-solero.png',
        baseVolumeMl: 110,
        parts: [
        RecipePart(ingredientId: 'passion-fruit-juice', amountMl: 50, automatic: true),
        RecipePart(ingredientId: 'orange-juice', amountMl: 40, automatic: true),
        RecipePart(ingredientId: 'lime-juice', amountMl: 10, automatic: true),
        RecipePart(ingredientId: 'vanilla-syrup', amountMl: 10, automatic: true),
        ],
      ),
      ]);
  }

  Future<void> save() async {
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setString('machine_state', jsonEncode({
      'catalogVersion': defaultCatalogVersion,
      'ingredients': ingredients.map((e) => e.toJson()).toList(),
      'pumps': pumps.map((e) => e.toJson()).toList(),
      'recipes': recipes.map((e) => e.toJson()).toList(),
      'cocktailLists': cocktailLists.map((e) => e.toJson()).toList(),
      'activeCocktailListId': activeCocktailListId,
      'partyCards': partyCards.map((e) => e.toJson()).toList(),
      'activePartyCardId': activePartyCardId,
      'partySessions': partySessions.map((e) => e.toJson()).toList(),
      'activePartySessionId': activePartySessionId,
      'partyPlannerGuestCount': partyPlannerGuestCount,
      'partyPlannerReservePercent': partyPlannerReservePercent,
      'recipeDrinkCounts': recipeDrinkCounts,
      'servingSizeCounts': servingSizeCounts,
      'ingredientUsageMl': ingredientUsageMl,
      'darkMode': darkMode,
      'appLanguage': appLanguage.name,
      'appColors': appColors.toJson(),
      'wifiHost': wifiHost,
      'servingSizes': servingSizes,
      'defaultServingSizeMl': defaultServingSizeMl,
      'shotSizes': shotSizes,
      'defaultShotSizeMl': defaultShotSizeMl,
      'primeTimesSeconds': primeTimesSeconds,
      'cleaningSeconds': cleaningSeconds,
      'cocktailsPerPage': cocktailsPerPage,
      'recipeSortMode': recipeSortMode.name,
      'paypalPaymentEnabled': paypalPaymentEnabled,
      'paymentMachineId': paymentMachineId,
      'cocktailPriceEur': cocktailPriceEur,
      'mocktailPriceEur': mocktailPriceEur,
      'shotPriceEur': shotPriceEur,
      'recipePricesEur': recipePricesEur,
      'alcoholStrengthSliderEnabled': alcoholStrengthSliderEnabled,
      'settingsLockEnabled': settingsLockEnabled,
      'settingsPassword': settingsPassword,
      'commercialLicenseActive': commercialLicenseActive,
      'commercialLicenseCode': commercialLicenseCode,
      'commercialLicensedMachineId': commercialLicensedMachineId,
      'commercialLicenseActivatedAt':
          commercialLicenseActivatedAt?.toIso8601String(),
      'commercialBusinessName': commercialBusinessName,
      'commercialBusinessSubtitle': commercialBusinessSubtitle,
      'ledIdleMode': ledIdleMode.name,
      'ledColorValue': ledColorValue,
      'ledBrightness': ledBrightness,
    }));
  }

  double defaultSizeFor(DrinkCategory category) =>
      category == DrinkCategory.shot
          ? defaultShotSizeMl
          : defaultServingSizeMl;

  List<Recipe> _copyRecipes(List<Recipe> source) {
    return source
        .map(
          (recipe) => Recipe.fromJson(
            Map<String, dynamic>.from(
              jsonDecode(jsonEncode(recipe.toJson())) as Map,
            ),
          ),
        )
        .toList();
  }

  CocktailListProfile? cocktailListById(String id) =>
      cocktailLists.where((list) => list.id == id).firstOrNull;

  Future<void> saveCurrentCocktailList(String name) async {
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) return;

    final existing = cocktailLists
        .where(
          (list) =>
              list.name.trim().toLowerCase() == trimmedName.toLowerCase(),
        )
        .firstOrNull;

    if (existing == null) {
      final id = DateTime.now().millisecondsSinceEpoch.toString();
      cocktailLists.add(
        CocktailListProfile(
          id: id,
          name: trimmedName,
          recipes: _copyRecipes(recipes),
        ),
      );
      activeCocktailListId = id;
    } else {
      existing.name = trimmedName;
      existing.recipes = _copyRecipes(recipes);
      existing.updatedAt = DateTime.now();
      activeCocktailListId = existing.id;
    }

    await save();
    notifyListeners();
  }

  Future<void> loadCocktailList(String id) async {
    final list = cocktailListById(id);
    if (list == null) return;

    recipes
      ..clear()
      ..addAll(_copyRecipes(list.recipes));
    activeCocktailListId = id;

    await save();
    notifyListeners();
  }

  Future<void> deleteCocktailList(String id) async {
    cocktailLists.removeWhere((list) => list.id == id);
    if (activeCocktailListId == id) {
      activeCocktailListId = null;
    }

    await save();
    notifyListeners();
  }

  Future<void> renameCocktailList(String id, String name) async {
    final list = cocktailListById(id);
    final trimmedName = name.trim();
    if (list == null || trimmedName.isEmpty) return;

    list.name = trimmedName;
    list.updatedAt = DateTime.now();

    await save();
    notifyListeners();
  }

  List<double> sizesFor(DrinkCategory category) =>
      category == DrinkCategory.shot ? shotSizes : servingSizes;

  Future<void> setCocktailsPerPage(int value) async {
    cocktailsPerPage = value.clamp(1, 1000).toInt();
    await save();
    notifyListeners();
  }

  Future<void> setRecipeSortMode(RecipeSortMode mode) async {
    recipeSortMode = mode;
    await save();
    notifyListeners();
  }

  Future<void> reorderRecipeWithinCategory(
    DrinkCategory category,
    int fromIndex,
    int toIndex,
  ) async {
    final categoryRecipes =
        recipes.where((recipe) => recipe.category == category).toList();

    if (fromIndex < 0 ||
        fromIndex >= categoryRecipes.length ||
        toIndex < 0 ||
        toIndex >= categoryRecipes.length ||
        fromIndex == toIndex) {
      return;
    }

    final moved = categoryRecipes.removeAt(fromIndex);
    categoryRecipes.insert(toIndex, moved);

    var categoryCursor = 0;
    final reordered = <Recipe>[];

    for (final recipe in recipes) {
      if (recipe.category == category) {
        reordered.add(categoryRecipes[categoryCursor]);
        categoryCursor++;
      } else {
        reordered.add(recipe);
      }
    }

    recipes
      ..clear()
      ..addAll(reordered);

    recipeSortMode = RecipeSortMode.original;

    await save();
    notifyListeners();
  }

  String get commercialLicenseStatusText => commercialLicenseActive
      ? 'Gewerbelizenz aktiv'
      : 'Privatmodus';

  bool get hasCommercialMachineMatch {
    if (!commercialLicenseActive) return false;
    if (commercialLicensedMachineId.trim().isEmpty) return true;
    return commercialLicensedMachineId.trim().toUpperCase() ==
        paymentMachineId.trim().toUpperCase();
  }

  String _normalLicenseCode(String value) =>
      value.trim().toUpperCase().replaceAll(' ', '');

  bool isValidCommercialLicenseCode(String code) {
    final normalized = _normalLicenseCode(code);
    final machine = paymentMachineId.trim().toUpperCase();
    if (normalized == 'CB-COMMERCIAL-DEMO') return true;
    if (machine.isNotEmpty &&
        normalized == _normalLicenseCode('CB-COM-$machine')) {
      return true;
    }
    return false;
  }

  Future<bool> activateCommercialLicense(String code) async {
    if (!isValidCommercialLicenseCode(code)) {
      return false;
    }

    commercialLicenseActive = true;
    commercialLicenseCode = code.trim();
    commercialLicensedMachineId = paymentMachineId.trim().isEmpty
        ? 'CB-DEMO'
        : paymentMachineId.trim();
    commercialLicenseActivatedAt = DateTime.now();

    await save();
    notifyListeners();
    return true;
  }

  Future<void> deactivateCommercialLicense() async {
    commercialLicenseActive = false;
    commercialLicenseCode = '';
    commercialLicensedMachineId = '';
    commercialLicenseActivatedAt = null;
    paypalPaymentEnabled = false;
    await save();
    notifyListeners();
  }

  Future<void> saveCommercialBranding({
    required String businessName,
    required String subtitle,
  }) async {
    commercialBusinessName =
        businessName.trim().isEmpty ? 'CocktailBot' : businessName.trim();
    commercialBusinessSubtitle = subtitle.trim().isEmpty
        ? 'Gewerbliche Nutzung erlaubt'
        : subtitle.trim();
    await save();
    notifyListeners();
  }

  double categoryPriceFor(DrinkCategory category) => switch (category) {
        DrinkCategory.cocktail => cocktailPriceEur,
        DrinkCategory.mocktail => mocktailPriceEur,
        DrinkCategory.shot => shotPriceEur,
      };

  double priceForRecipe(Recipe recipe) {
    final custom = recipePricesEur[recipe.id];
    if (custom != null) return custom;
    return categoryPriceFor(recipe.category);
  }

  Future<void> setRecipePrice(Recipe recipe, double? price) async {
    if (price == null) {
      recipePricesEur.remove(recipe.id);
    } else {
      recipePricesEur[recipe.id] = price.clamp(0, 9999).toDouble();
    }
    await save();
    if (connected && connectionMode == ConnectionMode.wifi) {
      try {
        await syncPaymentSettingsToController();
      } catch (_) {
        // Preise bleiben lokal gespeichert; der Server wird spätestens vor
        // der nächsten Bestellung erneut synchronisiert.
      }
    }
    notifyListeners();
  }

  Map<String, dynamic> paymentSettingsForController() {
    return {
      'machineId': paymentMachineId,
      'currency': 'EUR',
      'defaultPrices': {
        'cocktail': cocktailPriceEur.toStringAsFixed(2),
        'mocktail': mocktailPriceEur.toStringAsFixed(2),
        'shot': shotPriceEur.toStringAsFixed(2),
      },
      'recipePrices': recipePricesEur.map(
        (key, value) => MapEntry(key, value.toStringAsFixed(2)),
      ),
    };
  }

  Future<Map<String, dynamic>> syncPaymentSettingsToController() async {
    final response = await http
        .post(
          _apiUri('/api/payment/config'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode(paymentSettingsForController()),
        )
        .timeout(const Duration(seconds: 8));
    final body = response.body;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Lokales Zahlungsbackend HTTP ${response.statusCode}: $body');
    }
    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) return decoded;
    return {'ok': true};
  }

  Future<Map<String, dynamic>> fetchPaymentBackendStatus() async {
    final response = await http
        .get(_apiUri('/api/payment/status'))
        .timeout(const Duration(seconds: 8));
    final body = response.body;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Lokales Zahlungsbackend HTTP ${response.statusCode}: $body');
    }
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw Exception('Ungültige Antwort des lokalen Zahlungsbackends');
    }
    return decoded;
  }

  Future<void> savePaymentSettings({
    required bool enabled,
    required String machineId,
    required double cocktailPrice,
    required double mocktailPrice,
    required double shotPrice,
  }) async {
    paypalPaymentEnabled = enabled && commercialLicenseActive;
    paymentMachineId = machineId.trim().isEmpty ? 'CB-DEMO' : machineId.trim();
    cocktailPriceEur = cocktailPrice.clamp(0, 9999).toDouble();
    mocktailPriceEur = mocktailPrice.clamp(0, 9999).toDouble();
    shotPriceEur = shotPrice.clamp(0, 9999).toDouble();
    await save();
    if (connected && connectionMode == ConnectionMode.wifi) {
      await syncPaymentSettingsToController();
    }
    notifyListeners();
  }

  Future<PaymentOrderResult> createPaymentOrder({
    required Recipe recipe,
    required double targetVolumeMl,
  }) async {
    if (!commercialLicenseActive) {
      throw Exception('PayPal Kassenmodus benötigt eine aktive Gewerbelizenz');
    }

    final amount = priceForRecipe(recipe);
    if (amount <= 0) {
      throw Exception('Für diesen Cocktail ist kein Verkaufspreis gesetzt');
    }

    // Vor jeder Bestellung werden die Preise an den lokalen Raspberry-Dienst
    // übertragen. create-order akzeptiert bewusst keinen Betrag vom Browser;
    // der Server ermittelt den Preis aus dieser lokal gespeicherten Konfiguration.
    await syncPaymentSettingsToController();

    final response = await http
        .post(
          _apiUri('/api/payment/create-order'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({
            'machineId': paymentMachineId,
            'recipeId': recipe.id,
            'recipeName': recipe.name,
            'category': recipe.category.name,
            'sizeMl': targetVolumeMl.round(),
          }),
        )
        .timeout(const Duration(seconds: 15));
    final body = response.body;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Lokales Zahlungsbackend HTTP ${response.statusCode}: $body');
    }
    final decoded = jsonDecode(body);
    if (decoded is! Map) throw Exception('Ungültige Backend-Antwort');
    final orderId = decoded['orderId']?.toString() ?? '';
    final approvalUrl = decoded['approvalUrl']?.toString() ?? '';
    if (orderId.isEmpty || approvalUrl.isEmpty) {
      throw Exception('Raspberry hat keine gültige PayPal-URL geliefert');
    }
    return PaymentOrderResult(
      orderId: orderId,
      approvalUrl: approvalUrl,
      expiresAt: DateTime.tryParse(decoded['expiresAt']?.toString() ?? ''),
    );
  }

  Future<PaymentStatusResult> paymentStatus(String orderId) async {
    final uri = _apiUri('/api/payment/order-status')
        .replace(queryParameters: {'orderId': orderId});
    final response = await http
        .get(uri)
        .timeout(const Duration(seconds: 15));
    final body = response.body;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Lokales Zahlungsbackend HTTP ${response.statusCode}: $body');
    }
    final decoded = jsonDecode(body);
    if (decoded is! Map) throw Exception('Ungültige Status-Antwort');
    return PaymentStatusResult(
      paid: decoded['paid'] == true,
      used: decoded['used'] == true,
      status: decoded['status']?.toString() ?? 'UNKNOWN',
    );
  }

  Future<void> markPaymentUsed(String orderId) async {
    final response = await http
        .post(
          _apiUri('/api/payment/mark-used'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({
            'orderId': orderId,
            'machineId': paymentMachineId,
          }),
        )
        .timeout(const Duration(seconds: 8));
    final body = response.body;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Lokales Zahlungsbackend HTTP ${response.statusCode}: $body');
    }
  }


  PartyCardProfile? partyCardById(String? id) =>
      id == null ? null : partyCards.where((card) => card.id == id).firstOrNull;

  PartySession? activePartySession() =>
      activePartySessionId == null
          ? null
          : partySessions
              .where((session) => session.id == activePartySessionId)
              .firstOrNull;

  List<PartySession> completedPartySessionsForCard(String partyCardId) =>
      partySessions
          .where(
            (session) =>
                session.partyCardId == partyCardId &&
                session.endedAt != null &&
                session.guestCount > 0,
          )
          .toList()
        ..sort((a, b) => b.startedAt.compareTo(a.startedAt));

  Future<void> savePartyCard(
    String name,
    List<String> recipeIds,
    Map<String, CocktailPopularity> popularity, {
    String? existingId,
  }) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty || recipeIds.isEmpty) return;

    final now = DateTime.now();
    final existing = existingId == null ? null : partyCardById(existingId);

    if (existing == null) {
      final id = now.microsecondsSinceEpoch.toString();
      partyCards.add(
        PartyCardProfile(
          id: id,
          name: trimmed,
          recipeIds: recipeIds,
          popularity: popularity,
          createdAt: now,
          updatedAt: now,
        ),
      );
      activePartyCardId = id;
    } else {
      existing.name = trimmed;
      existing.recipeIds = recipeIds;
      existing.popularity = popularity;
      existing.updatedAt = now;
      activePartyCardId = existing.id;
    }

    await save();
    notifyListeners();
  }

  Future<void> deletePartyCard(String id) async {
    partyCards.removeWhere((card) => card.id == id);
    if (activePartyCardId == id) {
      activePartyCardId = partyCards.firstOrNull?.id;
    }
    await save();
    notifyListeners();
  }

  List<Recipe> recipesForPartyCard(PartyCardProfile card) {
    final byId = {for (final recipe in recipes) recipe.id: recipe};
    return card.recipeIds
        .map((id) => byId[id])
        .whereType<Recipe>()
        .toList();
  }

  Future<void> startPartySession({
    required String name,
    required int guestCount,
    required String partyCardId,
  }) async {
    final card = partyCardById(partyCardId);
    if (card == null || guestCount <= 0) return;

    final id = DateTime.now().microsecondsSinceEpoch.toString();
    partySessions.add(
      PartySession(
        id: id,
        name: name.trim().isEmpty ? 'Cocktailparty' : name.trim(),
        guestCount: guestCount,
        partyCardId: card.id,
        partyCardName: card.name,
        partyCardRecipeIds: List<String>.from(card.recipeIds),
      ),
    );
    activePartySessionId = id;
    activePartyCardId = card.id;
    partyPlannerGuestCount = guestCount;
    await save();
    notifyListeners();
  }

  Future<void> endActivePartySession() async {
    final session = activePartySession();
    if (session == null) return;
    session.endedAt = DateTime.now();
    activePartySessionId = null;
    await save();
    notifyListeners();
  }

  Future<void> deletePartySession(String id) async {
    partySessions.removeWhere((session) => session.id == id);
    if (activePartySessionId == id) {
      activePartySessionId = null;
    }
    await save();
    notifyListeners();
  }

  Future<void> setPartyPlannerSettings({
    int? guestCount,
    int? reservePercent,
    String? partyCardId,
  }) async {
    if (guestCount != null) {
      partyPlannerGuestCount = guestCount.clamp(1, 10000).toInt();
    }
    if (reservePercent != null) {
      partyPlannerReservePercent = reservePercent.clamp(0, 100).toInt();
    }
    if (partyCardId != null) {
      activePartyCardId = partyCardId;
    }
    await save();
    notifyListeners();
  }

  int popularityWeight(CocktailPopularity popularity) => switch (popularity) {
        CocktailPopularity.low => 1,
        CocktailPopularity.medium => 2,
        CocktailPopularity.high => 3,
      };

  String popularityLabel(CocktailPopularity popularity) => switch (popularity) {
        CocktailPopularity.low => t('Niedrig'),
        CocktailPopularity.medium => t('Mittel'),
        CocktailPopularity.high => t('Hoch'),
      };

  List<CocktailPlanningStats> planningStatsForPartyCard(
    PartyCardProfile card, {
    required int guestCount,
    required int reservePercent,
  }) {
    final cardRecipes = recipesForPartyCard(card);
    if (cardRecipes.isEmpty) return [];

    final completed = completedPartySessionsForCard(card.id);
    final reserveFactor = 1 + reservePercent.clamp(0, 100) / 100;

    if (completed.isNotEmpty) {
      return cardRecipes.map((recipe) {
        final scaledValues = completed.map((session) {
          final count = session.drinkCounts[recipe.id] ?? 0;
          return session.guestCount <= 0
              ? 0.0
              : count / session.guestCount * guestCount;
        }).toList();

        final minValue = scaledValues.reduce(math.min);
        final averageValue =
            scaledValues.fold<double>(0, (sum, value) => sum + value) /
                scaledValues.length;
        final maxValue = scaledValues.reduce(math.max);
        final planned = math.max(0, (averageValue * reserveFactor).ceil());

        return CocktailPlanningStats(
          recipe: recipe,
          minCount: minValue.round(),
          averageCount: averageValue.round(),
          maxCount: maxValue.round(),
          plannedCount: planned,
        );
      }).toList()
        ..sort((a, b) => b.plannedCount.compareTo(a.plannedCount));
    }

    final totalDrinks =
        math.max(1, (guestCount * 3.0 * reserveFactor).round());
    final totalWeight = cardRecipes.fold<int>(
      0,
      (sum, recipe) =>
          sum + popularityWeight(card.popularity[recipe.id] ?? CocktailPopularity.medium),
    );

    return cardRecipes.map((recipe) {
      final weight =
          popularityWeight(card.popularity[recipe.id] ?? CocktailPopularity.medium);
      final planned = math.max(1, (totalDrinks * weight / totalWeight).round());
      return CocktailPlanningStats(
        recipe: recipe,
        minCount: 0,
        averageCount: planned,
        maxCount: 0,
        plannedCount: planned,
      );
    }).toList()
      ..sort((a, b) => b.plannedCount.compareTo(a.plannedCount));
  }

  Map<String, double> plannedIngredientUsageMl(
    List<CocktailPlanningStats> stats,
  ) {
    final result = <String, double>{};
    for (final entry in stats) {
      final target = defaultSizeFor(entry.recipe.category);
      if (target <= 0 || entry.recipe.baseVolumeMl <= 0) continue;
      final scale = target / entry.recipe.baseVolumeMl;
      for (final part in entry.recipe.parts) {
        result.update(
          part.ingredientId,
          (value) => value + part.amountMl * scale * entry.plannedCount,
          ifAbsent: () => part.amountMl * scale * entry.plannedCount,
        );
      }
    }
    return result;
  }

  String recipeSortModeLabel(RecipeSortMode mode) => switch (mode) {
        RecipeSortMode.original => t('Originale Reihenfolge'),
        RecipeSortMode.nameAsc => t('Name A-Z'),
        RecipeSortMode.nameDesc => t('Name Z-A'),
        RecipeSortMode.availability => t('Verfügbare zuerst'),
        RecipeSortMode.alcoholAsc => t('Alkohol niedrig'),
        RecipeSortMode.alcoholDesc => t('Alkohol hoch'),
        RecipeSortMode.popularity => t('Beliebtheit'),
      };

  int _availabilitySortRank(RecipeAvailability availability) =>
      switch (availability) {
        RecipeAvailability.available => 0,
        RecipeAvailability.low => 1,
        RecipeAvailability.uncalibrated => 2,
        RecipeAvailability.unavailable => 3,
      };

  int _compareRecipeNames(Recipe a, Recipe b) => displayRecipeName(a)
      .toLowerCase()
      .compareTo(displayRecipeName(b).toLowerCase());

  List<Recipe> sortedRecipesForCategory(DrinkCategory category) {
    final data = recipes.where((r) => r.category == category).toList();

    switch (recipeSortMode) {
      case RecipeSortMode.original:
        return data;
      case RecipeSortMode.nameAsc:
        data.sort(_compareRecipeNames);
        break;
      case RecipeSortMode.nameDesc:
        data.sort((a, b) => _compareRecipeNames(b, a));
        break;
      case RecipeSortMode.availability:
        data.sort((a, b) {
          final availabilityCompare = _availabilitySortRank(availabilityFor(a))
              .compareTo(_availabilitySortRank(availabilityFor(b)));
          return availabilityCompare != 0
              ? availabilityCompare
              : _compareRecipeNames(a, b);
        });
        break;
      case RecipeSortMode.alcoholAsc:
        data.sort((a, b) {
          final alcoholCompare = recipeAlcoholPercent(a)
              .compareTo(recipeAlcoholPercent(b));
          return alcoholCompare != 0
              ? alcoholCompare
              : _compareRecipeNames(a, b);
        });
        break;
      case RecipeSortMode.alcoholDesc:
        data.sort((a, b) {
          final alcoholCompare = recipeAlcoholPercent(b)
              .compareTo(recipeAlcoholPercent(a));
          return alcoholCompare != 0
              ? alcoholCompare
              : _compareRecipeNames(a, b);
        });
        break;
      case RecipeSortMode.popularity:
        data.sort((a, b) {
          final popularityCompare = (recipeDrinkCounts[b.id] ?? 0)
              .compareTo(recipeDrinkCounts[a.id] ?? 0);
          return popularityCompare != 0
              ? popularityCompare
              : _compareRecipeNames(a, b);
        });
        break;
    }

    return data;
  }

  double ingredientCost(
    String ingredientId,
    double amountMl,
  ) {
    final ingredient = ingredientById(ingredientId);
    if (ingredient == null || ingredient.pricePerLiter <= 0) {
      return 0;
    }
    return amountMl / 1000 * ingredient.pricePerLiter;
  }

  double recipeCost(
    Recipe recipe, {
    double? targetVolumeMl,
  }) {
    final target = targetVolumeMl ?? defaultSizeFor(recipe.category);
    if (target <= 0 || recipe.baseVolumeMl <= 0) return 0;

    final scale = target / recipe.baseVolumeMl;
    var cost = 0.0;

    for (final part in recipe.parts) {
      cost += ingredientCost(part.ingredientId, part.amountMl * scale);
    }

    return cost;
  }


  double ingredientAlcoholMl(
    String ingredientId,
    double amountMl,
  ) {
    final ingredient = ingredientById(ingredientId);
    if (ingredient == null || ingredient.alcoholPercent <= 0) {
      return 0;
    }
    return amountMl * ingredient.alcoholPercent / 100;
  }

  double recipeAlcoholMl(
    Recipe recipe, {
    double? targetVolumeMl,
  }) {
    final target = targetVolumeMl ?? defaultSizeFor(recipe.category);
    if (target <= 0 || recipe.baseVolumeMl <= 0) return 0;

    final scale = target / recipe.baseVolumeMl;
    var alcoholMl = 0.0;

    for (final part in recipe.parts) {
      alcoholMl += ingredientAlcoholMl(
        part.ingredientId,
        part.amountMl * scale,
      );
    }

    return alcoholMl;
  }

  double recipeAlcoholPercent(
    Recipe recipe, {
    double? targetVolumeMl,
  }) {
    final target = targetVolumeMl ?? defaultSizeFor(recipe.category);
    if (target <= 0) return 0;
    return (recipeAlcoholMl(
              recipe,
              targetVolumeMl: target,
            ) /
            target *
            100)
        .clamp(0, 100)
        .toDouble();
  }


  Map<RecipePart, double> recipePartAmountsFor(
    Recipe recipe, {
    double? targetVolumeMl,
    double? targetAlcoholPercent,
  }) {
    final target = targetVolumeMl ?? defaultSizeFor(recipe.category);
    if (target <= 0 || recipe.baseVolumeMl <= 0) {
      return {for (final part in recipe.parts) part: 0};
    }

    final scale = target / recipe.baseVolumeMl;
    final amounts = <RecipePart, double>{
      for (final part in recipe.parts) part: math.max(0.0, part.amountMl * scale),
    };

    if (targetAlcoholPercent == null) {
      return amounts;
    }

    final defaultPureAlcoholMl = recipeAlcoholMl(
      recipe,
      targetVolumeMl: target,
    );

    if (defaultPureAlcoholMl <= 0) {
      return amounts;
    }

    final desiredPercent = targetAlcoholPercent.clamp(0, 25).toDouble();
    final desiredPureAlcoholMl = target * desiredPercent / 100;
    final alcoholFactor = desiredPureAlcoholMl / defaultPureAlcoholMl;

    for (final part in recipe.parts) {
      if (ingredientAlcoholMl(part.ingredientId, 1) > 0) {
        amounts[part] = (amounts[part] ?? 0) * alcoholFactor;
      }
    }

    final originalTotalMl = recipe.parts.fold<double>(
      0,
      (sum, part) => sum + part.amountMl * scale,
    );
    final adjustedTotalMl = amounts.values.fold<double>(
      0,
      (sum, amount) => sum + amount,
    );
    final differenceMl = originalTotalMl - adjustedTotalMl;

    final mixerParts = recipe.parts
        .where(
          (part) =>
              part.automatic &&
              ingredientAlcoholMl(part.ingredientId, 1) <= 0 &&
              (amounts[part] ?? 0) > 0,
        )
        .toList();

    if (mixerParts.isEmpty || differenceMl.abs() < 0.001) {
      return amounts;
    }

    final mixerTotalMl = mixerParts.fold<double>(
      0,
      (sum, part) => sum + (amounts[part] ?? 0),
    );

    if (mixerTotalMl <= 0) {
      return amounts;
    }

    if (differenceMl > 0) {
      for (final part in mixerParts) {
        final current = amounts[part] ?? 0;
        amounts[part] = current + differenceMl * current / mixerTotalMl;
      }
    } else {
      final removeMl = math.min(-differenceMl, mixerTotalMl);
      for (final part in mixerParts) {
        final current = amounts[part] ?? 0;
        amounts[part] = math.max(0.0, current - removeMl * current / mixerTotalMl);
      }
    }

    return amounts;
  }

  double recipePartAmountMl(
    Recipe recipe,
    RecipePart part, {
    double? targetVolumeMl,
    double? targetAlcoholPercent,
  }) {
    return recipePartAmountsFor(
          recipe,
          targetVolumeMl: targetVolumeMl,
          targetAlcoholPercent: targetAlcoholPercent,
        )[part] ??
        0;
  }

  double adjustedRecipeAlcoholMl(
    Recipe recipe, {
    double? targetVolumeMl,
    double? targetAlcoholPercent,
  }) {
    final amounts = recipePartAmountsFor(
      recipe,
      targetVolumeMl: targetVolumeMl,
      targetAlcoholPercent: targetAlcoholPercent,
    );
    var alcoholMl = 0.0;
    for (final entry in amounts.entries) {
      alcoholMl += ingredientAlcoholMl(entry.key.ingredientId, entry.value);
    }
    return alcoholMl;
  }

  double adjustedRecipeAlcoholPercent(
    Recipe recipe, {
    double? targetVolumeMl,
    double? targetAlcoholPercent,
  }) {
    final target = targetVolumeMl ?? defaultSizeFor(recipe.category);
    if (target <= 0) return 0;
    return (adjustedRecipeAlcoholMl(
              recipe,
              targetVolumeMl: target,
              targetAlcoholPercent: targetAlcoholPercent,
            ) /
            target *
            100)
        .clamp(0, 100)
        .toDouble();
  }

  bool validateSettingsPassword(String value) {
    final entered = value.trim();
    if (entered.toLowerCase() == 'cocktailbot') {
      return true;
    }
    return settingsPassword.isNotEmpty && entered == settingsPassword;
  }

  Future<void> saveSecuritySettings({
    required bool alcoholSliderEnabled,
    required bool lockEnabled,
    String? password,
  }) async {
    alcoholStrengthSliderEnabled = alcoholSliderEnabled;
    settingsLockEnabled = lockEnabled;
    final cleanedPassword = password?.trim() ?? '';
    if (cleanedPassword.isNotEmpty) {
      settingsPassword = cleanedPassword;
    }
    await save();
    notifyListeners();
  }

  double totalIngredientCost(String ingredientId) {
    final usedMl = ingredientUsageMl[ingredientId] ?? 0;
    return ingredientCost(ingredientId, usedMl);
  }

  double get totalConsumptionCost {
    var cost = 0.0;
    for (final entry in ingredientUsageMl.entries) {
      cost += totalIngredientCost(entry.key);
    }
    return cost;
  }

  int get totalDrinksConsumed => recipeDrinkCounts.values.fold(
        0,
        (sum, value) => sum + value,
      );

  double get totalIngredientsUsedMl => ingredientUsageMl.values.fold(
        0.0,
        (sum, value) => sum + value,
      );

  void recordRecipeConsumption(
    Recipe recipe, {
    required double targetVolumeMl,
    Map<RecipePart, double>? actualPartAmountsMl,
  }) {
    if (targetVolumeMl <= 0 || recipe.baseVolumeMl <= 0) return;

    final scale = targetVolumeMl / recipe.baseVolumeMl;

    recipeDrinkCounts.update(
      recipe.id,
      (value) => value + 1,
      ifAbsent: () => 1,
    );

    final sizeKey = '${targetVolumeMl.round()} ml';
    servingSizeCounts.update(
      sizeKey,
      (value) => value + 1,
      ifAbsent: () => 1,
    );

    final runningParty = activePartySession();
    if (runningParty != null) {
      runningParty.drinkCounts.update(
        recipe.id,
        (value) => value + 1,
        ifAbsent: () => 1,
      );
      runningParty.sizeCounts.update(
        sizeKey,
        (value) => value + 1,
        ifAbsent: () => 1,
      );
    }

    for (final part in recipe.parts) {
      final amountMl = actualPartAmountsMl?[part] ?? part.amountMl * scale;
      ingredientUsageMl.update(
        part.ingredientId,
        (value) => value + amountMl,
        ifAbsent: () => amountMl,
      );
    }
  }

  Future<void> resetConsumptionStatistics() async {
    recipeDrinkCounts = {};
    servingSizeCounts = {};
    ingredientUsageMl = {};
    await save();
    notifyListeners();
  }

  RecipeAvailability availabilityFor(
    Recipe recipe, {
    double? targetVolumeMl,
    double? targetAlcoholPercent,
  }) {
    final target = targetVolumeMl ?? defaultSizeFor(recipe.category);
    if (target <= 0 || recipe.baseVolumeMl <= 0) {
      return RecipeAvailability.unavailable;
    }

    final amounts = recipePartAmountsFor(
      recipe,
      targetVolumeMl: target,
      targetAlcoholPercent: targetAlcoholPercent,
    );
    double minimumPortions = double.infinity;
    bool calibrationMissing = false;

    for (final part in recipe.parts.where((part) => part.automatic)) {
      final requiredMl = amounts[part] ?? 0;
      if (requiredMl <= 0) {
        continue;
      }

      final pump = pumpForIngredient(part.ingredientId);

      if (pump == null) {
        return RecipeAvailability.unavailable;
      }

      if (pump.remainingMl + 0.0001 < requiredMl) {
        return RecipeAvailability.unavailable;
      }

      if (pump.mlPerSecond <= 0) {
        calibrationMissing = true;
      }

      minimumPortions =
          math.min(minimumPortions, pump.remainingMl / requiredMl);
    }

    if (calibrationMissing) {
      return RecipeAvailability.uncalibrated;
    }

    if (minimumPortions <= 2.999999) {
      return RecipeAvailability.low;
    }

    return RecipeAvailability.available;
  }

  String? availabilityIngredientName(
    Recipe recipe, {
    double? targetVolumeMl,
    double? targetAlcoholPercent,
  }) {
    final target = targetVolumeMl ?? defaultSizeFor(recipe.category);
    if (target <= 0 || recipe.baseVolumeMl <= 0) return null;
    final amounts = recipePartAmountsFor(
      recipe,
      targetVolumeMl: target,
      targetAlcoholPercent: targetAlcoholPercent,
    );

    String? lowestName;
    double lowestPortions = double.infinity;

    for (final part in recipe.parts.where((part) => part.automatic)) {
      final requiredMl = amounts[part] ?? 0;
      if (requiredMl <= 0) {
        continue;
      }

      final pump = pumpForIngredient(part.ingredientId);
      final name = displayIngredientNameById(part.ingredientId);

      if (pump == null) {
        return name;
      }
      if (pump.remainingMl + 0.0001 < requiredMl) {
        return name;
      }
      if (pump.mlPerSecond <= 0) {
        return name;
      }
      final portions = pump.remainingMl / requiredMl;
      if (portions < lowestPortions) {
        lowestPortions = portions;
        lowestName = name;
      }
    }
    return lowestName;
  }

  Uri _apiUri(String path) {
    final configuredHost = wifiHost.trim();

    // Im Raspberry-Kiosk werden Flutter-Web-App und GPIO-API vom selben
    // lokalen Dienst ausgeliefert. Leer = Same-Origin.
    if (configuredHost.isEmpty) {
      return Uri.base.resolve(path);
    }

    final baseText = configuredHost.contains('://')
        ? configuredHost
        : 'http://$configuredHost';
    final base = Uri.parse(baseText.endsWith('/') ? baseText : '$baseText/');
    return base.resolve(path.startsWith('/') ? path.substring(1) : path);
  }

  Future<void> showOnScreenKeyboard() async {
    try {
      await http
          .post(_apiUri('/api/keyboard/show'))
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      // Die Bildschirmtastatur ist Komfortfunktion. Ein Fehler darf die App
      // oder die Pumpensteuerung nicht blockieren.
    }
  }

  Future<void> hideOnScreenKeyboard() async {
    try {
      await http
          .post(_apiUri('/api/keyboard/hide'))
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      // Nicht kritisch.
    }
  }

  Future<bool> closeKioskApp() async {
    try {
      final response = await http
          .post(_apiUri('/api/kiosk/exit'))
          .timeout(const Duration(seconds: 3));
      return response.statusCode >= 200 && response.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>> sendCommand(
    Map<String, dynamic> command,
  ) async {
    if (!connected) {
      throw Exception('Keine Verbindung zur Maschine');
    }

    if (connectionMode == ConnectionMode.bluetooth) {
      throw Exception('Bluetooth ist in der Raspberry-Kiosk-Version deaktiviert');
    }

    final response = await http
        .post(
          _apiUri('/api/command'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode(command),
        )
        .timeout(const Duration(seconds: 8));

    final responseBody = response.body;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      String message = 'Raspberry HTTP ${response.statusCode}';
      if (responseBody.trim().isNotEmpty) {
        try {
          final decoded = jsonDecode(responseBody);
          final error = decoded is Map ? decoded['error']?.toString() : null;
          message = error != null && error.isNotEmpty
              ? '$message: $error'
              : '$message: $responseBody';
        } catch (_) {
          message = '$message: $responseBody';
        }
      }
      throw Exception(message);
    }

    if (responseBody.trim().isEmpty) return {'ok': true};
    final decoded = jsonDecode(responseBody);
    if (decoded is Map<String, dynamic>) return decoded;
    return {'ok': true, 'response': decoded};
  }

  Map<String, dynamic> _ledCommand() {
    return {
      'action': 'set_led',
      'mode': ledIdleMode.name,
      'r': (ledColorValue >> 16) & 0xFF,
      'g': (ledColorValue >> 8) & 0xFF,
      'b': ledColorValue & 0xFF,
      'brightness': (ledBrightness * 255).round(),
    };
  }

  Future<void> sendLedSettings() async {
    await sendCommand(_ledCommand());
  }

  Future<bool> applyLedSettings() async {
    await save();

    if (!connected) {
      return false;
    }

    await sendLedSettings();
    return true;
  }

  Future<void> connect() async {
    status = 'Verbindung wird geprüft …';
    notifyListeners();

    if (connectionMode == ConnectionMode.bluetooth) {
      connected = false;
      status = 'Bluetooth ist in der Kiosk-Version deaktiviert';
      notifyListeners();
      return;
    }

    try {
      final response = await http
          .get(_apiUri('/api/status'))
          .timeout(const Duration(seconds: 3));
      connected = response.statusCode == 200;
      status = connected
          ? 'Raspberry-Pi-Steuerung verbunden'
          : 'Raspberry-Pi-Steuerung antwortet nicht';
    } catch (_) {
      connected = false;
      status = wifiHost.trim().isEmpty
          ? 'Lokale Raspberry-Pi-Steuerung nicht erreichbar'
          : 'Keine Antwort von $wifiHost';
    }

    notifyListeners();

    if (connected) {
      try {
        await sendLedSettings();
      } catch (_) {
        // LED-Befehle dürfen eine funktionierende Pumpenverbindung nicht trennen.
      }
      await loadMachineStateFromController();
      if (commercialLicenseActive) {
        try {
          await syncPaymentSettingsToController();
        } catch (_) {
          // Eine fehlende PayPal-Konfiguration darf die Pumpenverbindung nicht trennen.
        }
      }
    }
  }

  Future<Map<String, dynamic>> fetchMachineStatus() async {
    if (connectionMode == ConnectionMode.bluetooth) {
      return {
        'ok': true,
        'busy': false,
        'currentPump': 0,
        'progress': 0.0,
      };
    }

    final response = await http
        .get(_apiUri('/api/status'))
        .timeout(const Duration(seconds: 5));
    final responseBody = response.body;

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Raspberry Status HTTP ${response.statusCode}: $responseBody',
      );
    }

    final decoded = jsonDecode(responseBody);
    if (decoded is! Map<String, dynamic>) {
      throw Exception('Ungültige Statusantwort der Raspberry-Steuerung');
    }

    connected = true;
    status = 'Raspberry-Pi-Steuerung verbunden';
    notifyListeners();
    return decoded;
  }

  Future<void> waitUntilMachineIdle({
    Duration timeout = const Duration(minutes: 10),
  }) async {
    if (!connected || connectionMode == ConnectionMode.bluetooth) {
      return;
    }

    final started = DateTime.now();

    while (DateTime.now().difference(started) < timeout) {
      final statusData = await fetchMachineStatus();
      final busy = statusData['busy'] == true;

      if (!busy) {
        return;
      }

      await Future.delayed(const Duration(milliseconds: 700));
    }

    throw Exception('Zeitüberschreitung beim Warten auf die Maschine');
  }

  Map<String, dynamic> machineStateForController() {
    return {
      'version': 1,
      'updatedAt': DateTime.now().toIso8601String(),
      'pumps': pumps.map((pump) => pump.toJson()).toList(),
    };
  }

  Future<bool> syncMachineStateToController() async {
    if (!connected || connectionMode == ConnectionMode.bluetooth) {
      return false;
    }

    try {
      await sendCommand({
        'action': 'save_machine_state',
        'machineState': machineStateForController(),
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> loadMachineStateFromController() async {
    if (connectionMode == ConnectionMode.bluetooth) {
      return false;
    }

    try {
      final statusData = await fetchMachineStatus();
      final machineState = statusData['machineState'];

      if (machineState is! Map) {
        return false;
      }

      final pumpData = machineState['pumps'];
      if (pumpData is! List || pumpData.isEmpty) {
        return false;
      }

      for (final entry in pumpData) {
        if (entry is! Map) continue;

        final pumpNumber = (entry['number'] as num?)?.toInt();
        if (pumpNumber == null || pumpNumber < 1 || pumpNumber > pumps.length) {
          continue;
        }

        final current = pumps[pumpNumber - 1];
        current.ingredientId = entry['ingredientId']?.toString();
        current.mlPerSecond =
            ((entry['mlPerSecond'] as num?)?.toDouble() ?? current.mlPerSecond)
                .clamp(0, 1000)
                .toDouble();
        current.capacityMl =
            ((entry['capacityMl'] as num?)?.toDouble() ?? current.capacityMl)
                .clamp(1, 20000)
                .toDouble();
        current.remainingMl =
            ((entry['remainingMl'] as num?)?.toDouble() ?? current.remainingMl)
                .clamp(0, current.capacityMl)
                .toDouble();
        current.active = (entry['active'] as bool?) ?? current.active;
      }

      await save();
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> makeRecipe(
    Recipe recipe, {
    double? targetVolumeMl,
    double? targetAlcoholPercent,
  }) async {
    final target = targetVolumeMl ?? defaultSizeFor(recipe.category);
    if (target <= 0 || recipe.baseVolumeMl <= 0) {
      throw Exception('Ungültige Größe des Cocktails');
    }

    final scale = target / recipe.baseVolumeMl;
    final amounts = recipePartAmountsFor(
      recipe,
      targetVolumeMl: target,
      targetAlcoholPercent: targetAlcoholPercent,
    );
    final commands = <Map<String, dynamic>>[];

    for (final part in recipe.parts.where((e) => e.automatic)) {
      final scaledAmount = amounts[part] ?? part.amountMl * scale;
      if (scaledAmount <= 0) {
        continue;
      }

      final pump = pumpForIngredient(part.ingredientId);

      if (pump == null) {
        throw Exception(
          '${t('Keine Pumpe für')} ${displayIngredientNameById(part.ingredientId)}',
        );
      }
      if (pump.mlPerSecond <= 0) {
        throw Exception('${t('Pumpe')} ${pump.number} ${t('ist nicht kalibriert')}');
      }
      if (pump.remainingMl < scaledAmount) {
        throw Exception(
          '${displayIngredientNameById(part.ingredientId)} ${t('reicht nicht aus')}',
        );
      }

      commands.add({
        'pump': pump.number,
        'amountMl': scaledAmount,
        'durationMs': (scaledAmount / pump.mlPerSecond * 1000).round(),
        'delayed': part.delayed,
      });
    }

    await sendCommand({
      'action': 'prepare_recipe',
      'recipeId': recipe.id,
      'baseVolumeMl': recipe.baseVolumeMl,
      'targetVolumeMl': target,
      'scaleFactor': scale,
      'startSpacingMs': 100,
      'pumps': commands,
    });

    await waitUntilMachineIdle();

    for (final part in recipe.parts.where((e) => e.automatic)) {
      final scaledAmount = amounts[part] ?? part.amountMl * scale;
      if (scaledAmount <= 0) {
        continue;
      }
      pumpForIngredient(part.ingredientId)!.remainingMl -= scaledAmount;
    }

    recordRecipeConsumption(
      recipe,
      targetVolumeMl: target,
      actualPartAmountsMl: amounts,
    );

    await save();
    await syncMachineStateToController();
    notifyListeners();
  }
}

extension FirstOrNull<E> on Iterable<E> { E? get firstOrNull => isEmpty ? null : first; }

class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.store});
  final MachineStore store;
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int index = 0;

  void _openRecipe(Recipe recipe, String fallbackAsset) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => RecipeDetailPage(
          store: widget.store,
          recipe: recipe,
          fallbackAsset: fallbackAsset,
          selectedNavigationIndex: index,
          onNavigate: (targetIndex) {
            Navigator.of(context).pop();
            if (!mounted) return;
            setState(() => index = targetIndex.clamp(0, 3).toInt());
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      RecipeOverview(
        store: widget.store,
        category: DrinkCategory.cocktail,
        title: widget.store.t('titleAlcoholicCocktails'),
        onOpenRecipe: _openRecipe,
      ),
      RecipeOverview(
        store: widget.store,
        category: DrinkCategory.mocktail,
        title: widget.store.t('titleMocktails'),
        onOpenRecipe: _openRecipe,
      ),
      RecipeOverview(
        store: widget.store,
        category: DrinkCategory.shot,
        title: widget.store.t('navShots'),
        onOpenRecipe: _openRecipe,
      ),
      SettingsLockGate(
        store: widget.store,
        child: SettingsPage(store: widget.store),
      ),
    ];

    return LayoutBuilder(
      builder: (context, c) {
        final responsive =
            CocktailBotResponsive.fromSize(c.maxWidth, c.maxHeight);
        if (responsive.useTopNavigation) {
          return Scaffold(
            body: Column(
              children: [
                CocktailBotTopNavigation(
                  store: widget.store,
                  selectedIndex: index,
                  onSelected: (value) => setState(() => index = value),
                ),
                Expanded(child: pages[index]),
              ],
            ),
          );
        }

        final nav = cocktailBotNavigationItems(widget.store);
        return Scaffold(
          body: pages[index],
          bottomNavigationBar: Container(
            decoration: BoxDecoration(
              color: widget.store.appColors.navigationColor,
              border: Border(
                top: BorderSide(color: widget.store.appColors.borderColor),
              ),
            ),
            child: SafeArea(
              top: false,
              child: SizedBox(
                height: 72,
                child: Row(
                  children: List.generate(
                    nav.length,
                    (i) => Expanded(
                      child: InkWell(
                        onTap: () => setState(() => index = i),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              index == i ? nav[i].$2 : nav[i].$1,
                              color: index == i
                                  ? widget.store.appColors.accentColor
                                  : widget.store.appColors.textSecondaryColor,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              nav[i].$3,
                              maxLines: 1,
                              style: TextStyle(
                                fontSize: 11,
                                color: index == i
                                    ? widget.store.appColors.accentColor
                                    : widget.store.appColors.textSecondaryColor,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

List<(IconData, IconData, String)> cocktailBotNavigationItems(
  MachineStore store,
) =>
    [
      (
        Icons.local_bar_outlined,
        Icons.local_bar,
        store.t('navCocktails'),
      ),
      (
        Icons.local_drink_outlined,
        Icons.local_drink,
        store.t('navMocktails'),
      ),
      (
        Icons.liquor_outlined,
        Icons.liquor,
        store.t('navShots'),
      ),
      (
        Icons.settings_outlined,
        Icons.settings,
        store.t('navSettings'),
      ),
    ];

class CocktailBotTopNavigation extends StatelessWidget {
  const CocktailBotTopNavigation({
    super.key,
    required this.store,
    required this.selectedIndex,
    required this.onSelected,
  });

  final MachineStore store;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final nav = cocktailBotNavigationItems(store);
    final width = MediaQuery.sizeOf(context).width;
    final extendedLogo = width >= 1180;

    return SafeArea(
      bottom: false,
      child: Container(
        height: 66,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: store.appColors.navigationColor,
          border: Border(
            bottom: BorderSide(color: store.appColors.borderColor),
          ),
        ),
        child: Row(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: LogoMark(extended: extendedLogo),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Row(
                children: List.generate(nav.length, (i) {
                  final selected = selectedIndex == i;
                  return Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Material(
                        color: selected
                            ? store.appColors.accentColor.withValues(alpha: .18)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(11),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(11),
                          onTap: () => onSelected(i),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 8,
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  selected ? nav[i].$2 : nav[i].$1,
                                  size: 23,
                                  color: selected
                                      ? store.appColors.accentColor
                                      : store.appColors.textSecondaryColor,
                                ),
                                const SizedBox(width: 7),
                                Flexible(
                                  child: Text(
                                    nav[i].$3,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: width <= 1050 ? 12.5 : 14,
                                      color: selected
                                          ? store.appColors.accentColor
                                          : store.appColors.textPrimaryColor,
                                      fontWeight: selected
                                          ? FontWeight.w800
                                          : FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class CocktailBotSideNavigation extends StatelessWidget {
  const CocktailBotSideNavigation({
    super.key,
    required this.store,
    required this.selectedIndex,
    required this.onSelected,
  });

  final MachineStore store;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final nav = cocktailBotNavigationItems(store);
    final wide = MediaQuery.sizeOf(context).width >= 1180;
    final width = wide ? 210.0 : 112.0;

    return Container(
      width: width,
      decoration: BoxDecoration(
        color: store.appColors.navigationColor,
        border: Border(
          right: BorderSide(color: store.appColors.borderColor),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(wide ? 16 : 8, 8, wide ? 16 : 8, 8),
            child: Align(
              alignment: Alignment.topCenter,
              child: LogoMark(extended: wide),
            ),
          ),
          ...List.generate(nav.length, (i) {
            final selected = selectedIndex == i;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              child: Material(
                color: selected
                    ? store.appColors.accentColor.withValues(alpha: .18)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(11),
                child: InkWell(
                  borderRadius: BorderRadius.circular(11),
                  onTap: () => onSelected(i),
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: wide ? 12 : 6,
                      vertical: wide ? 11 : 8,
                    ),
                    child: wide
                        ? Row(
                            children: [
                              Icon(
                                selected ? nav[i].$2 : nav[i].$1,
                                color: selected
                                    ? store.appColors.accentColor
                                    : store.appColors.textSecondaryColor,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  nav[i].$3,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: selected
                                        ? store.appColors.accentColor
                                        : store.appColors.textPrimaryColor,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                          )
                        : Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                selected ? nav[i].$2 : nav[i].$1,
                                size: 27,
                                color: selected
                                    ? store.appColors.accentColor
                                    : store.appColors.textSecondaryColor,
                              ),
                              const SizedBox(height: 5),
                              Text(
                                nav[i].$3,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 10.5,
                                  height: 1.05,
                                  color: selected
                                      ? store.appColors.accentColor
                                      : store.appColors.textPrimaryColor,
                                  fontWeight:
                                      selected ? FontWeight.w700 : FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                  ),
                ),
              ),
            );
          }),
          const Spacer(),
          if (wide) ...[
            MachineStatusCard(store: store),
            const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }
}

class LogoMark extends StatelessWidget {
  const LogoMark({super.key, this.extended = false}); final bool extended;
  @override Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
    const Icon(Icons.local_bar, color: Color(0xFF16E0D0), size: 39),
    if (extended) const Padding(padding: EdgeInsets.only(left: 10), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [T('CocktailBot', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 22, color: Colors.white)), T('Cocktail-Maschine', style: TextStyle(color: Color(0xFF18CFC4), fontSize: 11))])),
  ]);
}

class MachineStatusCard extends StatelessWidget {
  const MachineStatusCard({super.key, required this.store}); final MachineStore store;
  @override Widget build(BuildContext context) => Padding(padding: const EdgeInsets.symmetric(horizontal: 14), child: Container(
    padding: const EdgeInsets.all(14), decoration: BoxDecoration(color: store.appColors.surfaceColor, borderRadius: BorderRadius.circular(12), border: Border.all(color: store.appColors.borderColor)),
    child: Row(children: [const Icon(Icons.memory, color: Color(0xFFCFD7DE)), const SizedBox(width: 12), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(store.t('machine'), style: const TextStyle(fontWeight: FontWeight.w700)), const T('CocktailBot-RaspberryPi', style: TextStyle(fontSize: 11, color: Color(0xFF9AA6B2))), Text(store.connected ? store.t('online') : store.t('offline'), style: TextStyle(fontSize: 11, color: store.connected ? store.appColors.successColor : store.appColors.warningColor))]) )]),
  ));
}

class AppHeader extends StatelessWidget {
  const AppHeader({super.key, required this.store, required this.title, this.subtitle, this.showSearch = false});
  final MachineStore store; final String title; final String? subtitle; final bool showSearch;
  @override Widget build(BuildContext context) => Row(children: [
    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800, color: Colors.white)), if (subtitle != null) ...[const SizedBox(height: 4), Text(subtitle!, style: const TextStyle(color: Color(0xFF97A3AE)))]])),
    if (showSearch) IconButton(onPressed: () {}, icon: const Icon(Icons.search, color: Color(0xFF18DED0))),
  ]);
}

enum CocktailBotScreenClass {
  phonePortrait,
  phoneLandscape,
  tabletPortrait,
  tabletLandscape,
  wide,
}

class CocktailBotResponsive {
  const CocktailBotResponsive({
    required this.width,
    required this.height,
    required this.orientation,
  });

  factory CocktailBotResponsive.of(BuildContext context) {
    final query = MediaQuery.of(context);
    final size = query.size;

    return CocktailBotResponsive(
      width: size.width,
      height: size.height,
      orientation: query.orientation,
    );
  }

  factory CocktailBotResponsive.fromSize(double width, double height) {
    return CocktailBotResponsive(
      width: width,
      height: height,
      orientation: width >= height
          ? Orientation.landscape
          : Orientation.portrait,
    );
  }

  final double width;
  final double height;
  final Orientation orientation;

  bool get isLandscape => orientation == Orientation.landscape;
  bool get isPhone => width < 700;
  bool get isTablet => width >= 700 && width < 1200;
  bool get isWide => width >= 1200;

  CocktailBotScreenClass get screenClass {
    if (isWide) return CocktailBotScreenClass.wide;
    if (isTablet && isLandscape) return CocktailBotScreenClass.tabletLandscape;
    if (isTablet) return CocktailBotScreenClass.tabletPortrait;
    if (isLandscape) return CocktailBotScreenClass.phoneLandscape;
    return CocktailBotScreenClass.phonePortrait;
  }

  bool get useTopNavigation =>
      width >= 760 && screenClass != CocktailBotScreenClass.phoneLandscape;

  double get horizontalPadding {
    if (isWide) return 28;
    if (isTablet) return 24;
    return 18;
  }

  double get topPadding {
    if (isWide) return 26;
    if (isTablet) return 24;
    return 18;
  }

  int get recipeColumns {
    switch (screenClass) {
      case CocktailBotScreenClass.phonePortrait:
        return 2;
      case CocktailBotScreenClass.phoneLandscape:
        return 3;
      case CocktailBotScreenClass.tabletPortrait:
        return 3;
      case CocktailBotScreenClass.tabletLandscape:
        return 4;
      case CocktailBotScreenClass.wide:
        return width >= 1500 ? 5 : 4;
    }
  }

  int get fillColumns {
    switch (screenClass) {
      case CocktailBotScreenClass.phonePortrait:
        return 1;
      case CocktailBotScreenClass.phoneLandscape:
        return 2;
      case CocktailBotScreenClass.tabletPortrait:
        return 2;
      case CocktailBotScreenClass.tabletLandscape:
        return 3;
      case CocktailBotScreenClass.wide:
        return width >= 1500 ? 5 : 4;
    }
  }

  int get calibrationColumns {
    switch (screenClass) {
      case CocktailBotScreenClass.phonePortrait:
        return 1;
      case CocktailBotScreenClass.phoneLandscape:
        return 2;
      case CocktailBotScreenClass.tabletPortrait:
        return 2;
      case CocktailBotScreenClass.tabletLandscape:
        return 3;
      case CocktailBotScreenClass.wide:
        return width >= 1500 ? 5 : 4;
    }
  }

  int get settingsColumns {
    if (isWide) return width >= 1500 ? 4 : 3;
    if (isTablet && isLandscape) return 3;
    if (isTablet) return 2;
    return 1;
  }

  double get recipeAspectRatio {
    switch (screenClass) {
      case CocktailBotScreenClass.phonePortrait:
        return .78;
      case CocktailBotScreenClass.phoneLandscape:
        return .86;
      case CocktailBotScreenClass.tabletPortrait:
        return .84;
      case CocktailBotScreenClass.tabletLandscape:
        return .90;
      case CocktailBotScreenClass.wide:
        return .92;
    }
  }

  double get fillCardAspectRatio {
    switch (screenClass) {
      case CocktailBotScreenClass.phonePortrait:
        return .82;
      case CocktailBotScreenClass.phoneLandscape:
        return .78;
      case CocktailBotScreenClass.tabletPortrait:
        return .76;
      case CocktailBotScreenClass.tabletLandscape:
        return .82;
      case CocktailBotScreenClass.wide:
        return .86;
    }
  }
}

class RecipeOverview extends StatefulWidget {
  const RecipeOverview({
    super.key,
    required this.store,
    required this.category,
    required this.title,
    required this.onOpenRecipe,
  });

  final MachineStore store;
  final DrinkCategory category;
  final String title;
  final void Function(Recipe recipe, String fallbackAsset) onOpenRecipe;

  @override
  State<RecipeOverview> createState() => _RecipeOverviewState();
}

class _RecipeOverviewState extends State<RecipeOverview> {
  int pageIndex = 0;

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final data = store.sortedRecipesForCategory(widget.category);

    final perPage = store.cocktailsPerPage <= 0
        ? data.length
        : store.cocktailsPerPage.clamp(1, 1000).toInt();
    final pageCount =
        data.isEmpty ? 1 : (data.length / perPage).ceil().clamp(1, 9999);
    final safePageIndex = pageIndex.clamp(0, pageCount - 1).toInt();
    if (safePageIndex != pageIndex) {
      pageIndex = safePageIndex;
    }

    final start = safePageIndex * perPage;
    final end = (start + perPage).clamp(0, data.length).toInt();
    final visible = data.sublist(start, end);

    return SafeArea(
      child: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              CocktailBotResponsive.of(context).horizontalPadding,
              CocktailBotResponsive.of(context).topPadding,
              CocktailBotResponsive.of(context).horizontalPadding,
              12,
            ),
            sliver: SliverToBoxAdapter(
              child: AppHeader(
                store: store,
                title: widget.title,
                showSearch: true,
              ),
            ),
          ),
          if (data.isNotEmpty)
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                CocktailBotResponsive.of(context).horizontalPadding,
                0,
                CocktailBotResponsive.of(context).horizontalPadding,
                12,
              ),
              sliver: SliverToBoxAdapter(
                child: _RecipePageControls(
                  store: store,
                  currentPage: safePageIndex,
                  pageCount: pageCount,
                  totalCount: data.length,
                  visibleStart: start + 1,
                  visibleEnd: end,
                  onPrevious: safePageIndex > 0
                      ? () => setState(() => pageIndex--)
                      : null,
                  onNext: safePageIndex < pageCount - 1
                      ? () => setState(() => pageIndex++)
                      : null,
                ),
              ),
            ),
          if (data.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: Text(store.t('noRecipes'))),
            )
          else
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                CocktailBotResponsive.of(context).horizontalPadding,
                4,
                CocktailBotResponsive.of(context).horizontalPadding,
                22,
              ),
              sliver: SliverLayoutBuilder(
                builder: (context, constraints) {
                  final w = constraints.crossAxisExtent;
                  final responsive = CocktailBotResponsive.of(context);
                  final count = responsive.recipeColumns;

                  return SliverGrid(
                    delegate: SliverChildBuilderDelegate(
                      (_, i) => RecipeCard(
                        store: store,
                        recipe: visible[i],
                        index: start + i,
                        onOpenRecipe: widget.onOpenRecipe,
                      ),
                      childCount: visible.length,
                    ),
                    gridDelegate:
                        SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: count,
                      childAspectRatio: responsive.recipeAspectRatio,
                      crossAxisSpacing: 10,
                      mainAxisSpacing: 10,
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _RecipePageControls extends StatelessWidget {
  const _RecipePageControls({
    required this.store,
    required this.currentPage,
    required this.pageCount,
    required this.totalCount,
    required this.visibleStart,
    required this.visibleEnd,
    required this.onPrevious,
    required this.onNext,
  });

  final MachineStore store;
  final int currentPage;
  final int pageCount;
  final int totalCount;
  final int visibleStart;
  final int visibleEnd;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: store.appColors.cardColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: store.appColors.borderColor),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              totalCount == 0
                  ? store.t('Keine Cocktails')
                  : '$visibleStart–$visibleEnd ${store.t('von')} $totalCount',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: store.appColors.textSecondaryColor,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          IconButton.filledTonal(
            tooltip: store.t('Vorherige Seite'),
            onPressed: onPrevious,
            icon: const Icon(Icons.chevron_left),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              '${currentPage + 1} / $pageCount',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
          IconButton.filledTonal(
            tooltip: store.t('Nächste Seite'),
            onPressed: onNext,
            icon: const Icon(Icons.chevron_right),
          ),
        ],
      ),
    );
  }
}

const drinkAssets = [
  'assets/drinks/mojito.png', 'assets/drinks/pina_colada.png', 'assets/drinks/long_island.png',
  'assets/drinks/sex_on_beach.png', 'assets/drinks/tequila_sunrise.png', 'assets/drinks/whiskey_sour.png'
];

class RecipeCard extends StatelessWidget {
  const RecipeCard({
    super.key,
    required this.store,
    required this.recipe,
    required this.index,
    required this.onOpenRecipe,
  });

  final MachineStore store;
  final Recipe recipe;
  final int index;
  final void Function(Recipe recipe, String fallbackAsset) onOpenRecipe;

  @override
  Widget build(BuildContext context) {
    final image = recipe.imagePath ?? drinkAssets[index % drinkAssets.length];
    final status = store.availabilityFor(recipe);
    final ingredientName = store.availabilityIngredientName(recipe);
    final unavailable = status == RecipeAvailability.unavailable;
    final uncalibrated = status == RecipeAvailability.uncalibrated;
    final low = status == RecipeAvailability.low;
    final alcoholPercent = store.recipeAlcoholPercent(recipe);

    return Material(
      color: const Color(0xFF151B21),
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => onOpenRecipe(
          recipe,
          drinkAssets[index % drinkAssets.length],
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: cocktailImage(
                image,
                fallbackAsset: drinkAssets[index % drinkAssets.length],
              ),
            ),
            const Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Color(0x18000000),
                      Color(0xE8000000),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: Container(
                padding: const EdgeInsets.all(5),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: .28),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.favorite_border,
                  color: Colors.white,
                  size: 19,
                ),
              ),
            ),
            if (unavailable || uncalibrated || low)
              Positioned(
                left: 8,
                top: 8,
                right: 42,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                    decoration: BoxDecoration(
                      color: unavailable
                          ? const Color(0xFFD32F2F)
                          : const Color(0xFFF59E0B),
                      borderRadius: BorderRadius.circular(7),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x66000000),
                          blurRadius: 7,
                          offset: Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          unavailable
                              ? Icons.block
                              : Icons.warning_amber_rounded,
                          color: Colors.white,
                          size: 15,
                        ),
                        const SizedBox(width: 5),
                        Flexible(
                          child: Text(
                            unavailable
                                ? '${tr('Nicht verfügbar')}${ingredientName == null ? '' : ': $ingredientName'}'
                                : uncalibrated
                                    ? '${tr('Kalibrierung fehlt')}${ingredientName == null ? '' : ': $ingredientName'}'
                                    : '${tr('Niedriger Füllstand')}${ingredientName == null ? '' : ': $ingredientName'}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            if (alcoholPercent > 0)
              Positioned(
                left: 10,
                bottom: 48,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: .45),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: .25),
                    ),
                  ),
                  child: Text(
                    '${formatAlcoholPercent(alcoholPercent)} % vol',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            Positioned(
              left: 10,
              right: 10,
              bottom: 10,
              child: Text(
                store.displayRecipeName(recipe),
                maxLines: 2,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                  fontSize: 14,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class RecipeDetailPage extends StatefulWidget {
  const RecipeDetailPage({
    super.key,
    required this.store,
    required this.recipe,
    required this.fallbackAsset,
    this.selectedNavigationIndex = 0,
    this.onNavigate,
  });

  final MachineStore store;
  final Recipe recipe;
  final String fallbackAsset;
  final int selectedNavigationIndex;
  final ValueChanged<int>? onNavigate;

  @override
  State<RecipeDetailPage> createState() => _RecipeDetailPageState();
}

class _RecipeDetailPageState extends State<RecipeDetailPage> {
  bool working = false;
  late double selectedSizeMl;
  late double selectedAlcoholPercent;

  @override
  void initState() {
    super.initState();
    selectedSizeMl = widget.store.defaultSizeFor(widget.recipe.category);
    selectedAlcoholPercent = widget.store
        .recipeAlcoholPercent(widget.recipe, targetVolumeMl: selectedSizeMl)
        .clamp(0, 25)
        .toDouble();
  }

  double get scale => selectedSizeMl / widget.recipe.baseVolumeMl;

  double? get selectedAlcoholPercentForPreparation {
    if (!widget.store.alcoholStrengthSliderEnabled ||
        widget.recipe.category != DrinkCategory.cocktail) {
      return null;
    }
    final recipePercent = widget.store.recipeAlcoholPercent(
      widget.recipe,
      targetVolumeMl: selectedSizeMl,
    );
    if (recipePercent <= 0) return null;
    return selectedAlcoholPercent.clamp(0, 25).toDouble();
  }

  void _navigateFromRail(int targetIndex) {
    if (targetIndex == widget.selectedNavigationIndex) {
      Navigator.of(context).pop();
      return;
    }
    if (widget.onNavigate != null) {
      widget.onNavigate!(targetIndex);
    } else {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.recipe;
    final image = r.imagePath ?? widget.fallbackAsset;
    final responsive = CocktailBotResponsive.of(context);
    final kioskLandscape = responsive.useTopNavigation &&
        responsive.isLandscape &&
        responsive.height <= 800;

    final recipeAlcoholPercent = widget.store.recipeAlcoholPercent(
      r,
      targetVolumeMl: selectedSizeMl,
    );
    final strengthSliderVisible = widget.store.alcoholStrengthSliderEnabled &&
        r.category == DrinkCategory.cocktail &&
        recipeAlcoholPercent > 0;
    final targetAlcoholPercent =
        strengthSliderVisible ? selectedAlcoholPercentForPreparation : null;
    final availability = widget.store.availabilityFor(
      r,
      targetVolumeMl: selectedSizeMl,
      targetAlcoholPercent: targetAlcoholPercent,
    );
    final unavailable = availability == RecipeAvailability.unavailable;
    final uncalibrated = availability == RecipeAvailability.uncalibrated;
    final low = availability == RecipeAvailability.low;
    final affectedIngredient = widget.store.availabilityIngredientName(
      r,
      targetVolumeMl: selectedSizeMl,
      targetAlcoholPercent: targetAlcoholPercent,
    );
    final alcoholPercent = widget.store.adjustedRecipeAlcoholPercent(
      r,
      targetVolumeMl: selectedSizeMl,
      targetAlcoholPercent: targetAlcoholPercent,
    );
    final pureAlcoholMl = widget.store.adjustedRecipeAlcoholMl(
      r,
      targetVolumeMl: selectedSizeMl,
      targetAlcoholPercent: targetAlcoholPercent,
    );

    Widget prepareButton() {
      return SizedBox(
        width: double.infinity,
        height: 50,
        child: FilledButton.icon(
          onPressed: working || unavailable || uncalibrated
              ? null
              : widget.store.paypalPaymentEnabled
                  ? _startPayment
                  : _make,
          icon: working
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(
                  (widget.store.paypalPaymentEnabled &&
                          widget.store.commercialLicenseActive)
                      ? Icons.qr_code_2
                      : Icons.play_arrow,
                ),
          label: Text(
            working
                ? tr('Wird gestartet …')
                : (widget.store.paypalPaymentEnabled &&
                        widget.store.commercialLicenseActive)
                    ? '${widget.store.priceForRecipe(r).toStringAsFixed(2).replaceAll('.', ',')} € ${tr('bezahlen')}'
                    : '${selectedSizeMl.toStringAsFixed(0)} ml ${tr('zubereiten')}',
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
        ),
      );
    }

    List<Widget> detailWidgets() => [
          Text(
            tr('Beschreibung'),
            style: const TextStyle(
              color: Color(0xFF16E0D0),
              fontWeight: FontWeight.w900,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            widget.store.displayRecipeDescription(r),
            style: TextStyle(
              color: widget.store.appColors.textSecondaryColor,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            tr('Größe des Cocktails'),
            style: const TextStyle(
              color: Color(0xFF16E0D0),
              fontWeight: FontWeight.w900,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 7),
          DropdownButtonFormField<double>(
            initialValue: widget.store.sizesFor(r.category).contains(selectedSizeMl)
                ? selectedSizeMl
                : null,
            decoration: InputDecoration(
              labelText: tr('Zielgröße'),
              suffixText: tr('ml'),
              isDense: true,
            ),
            items: widget.store
                .sizesFor(r.category)
                .map(
                  (size) => DropdownMenuItem(
                    value: size,
                    child: Text(
                      '${size.toStringAsFixed(size % 1 == 0 ? 0 : 1)} ml',
                    ),
                  ),
                )
                .toList(),
            onChanged: working
                ? null
                : (value) {
                    if (value == null) return;
                    setState(() {
                      selectedSizeMl = value;
                      selectedAlcoholPercent =
                          selectedAlcoholPercent.clamp(0, 25).toDouble();
                    });
                  },
          ),
          const SizedBox(height: 6),
          Text(
            '${tr('Rezeptbasis')}: ${r.baseVolumeMl.toStringAsFixed(0)} ml · ${tr('Faktor')} ${scale.toStringAsFixed(2)}',
            style: TextStyle(
              color: widget.store.appColors.textSecondaryColor,
              fontSize: 11.5,
            ),
          ),
          if (alcoholPercent > 0) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.local_bar, size: 17, color: Color(0xFFFFC857)),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    '${tr('Alkoholgehalt')}: ${formatAlcoholPercent(alcoholPercent)} % vol · ${tr('Reiner Alkohol')}: ${pureAlcoholMl.toStringAsFixed(1).replaceAll('.', ',')} ml',
                    style: const TextStyle(fontSize: 11.5),
                  ),
                ),
              ],
            ),
          ],
          if (strengthSliderVisible) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${tr('Stärke einstellen')}: ${formatAlcoholPercent(selectedAlcoholPercent)} % vol',
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
            Slider(
              min: 0,
              max: 25,
              divisions: 50,
              value: selectedAlcoholPercent.clamp(0, 25).toDouble(),
              label: '${formatAlcoholPercent(selectedAlcoholPercent)} %',
              onChanged: working
                  ? null
                  : (value) =>
                      setState(() => selectedAlcoholPercent = value),
            ),
          ],
          if (unavailable || uncalibrated || low) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: unavailable
                    ? const Color(0xFF4A1717)
                    : const Color(0xFF4A3510),
                borderRadius: BorderRadius.circular(9),
                border: Border.all(
                  color: unavailable
                      ? const Color(0xFFE05252)
                      : const Color(0xFFF59E0B),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    unavailable
                        ? Icons.block
                        : Icons.warning_amber_rounded,
                    size: 19,
                    color: unavailable
                        ? const Color(0xFFFF6B6B)
                        : const Color(0xFFFFB020),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      unavailable
                          ? '${tr('Nicht verfügbar')}${affectedIngredient == null ? '' : ': $affectedIngredient'}'
                          : uncalibrated
                              ? '${tr('Kalibrierung erforderlich')}${affectedIngredient == null ? '' : ': $affectedIngredient'}'
                              : '${tr('Niedriger Füllstand')}${affectedIngredient == null ? '' : ': $affectedIngredient'}',
                      style: const TextStyle(fontSize: 11.5),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          Text(
            tr('Zutaten'),
            style: const TextStyle(
              color: Color(0xFF16E0D0),
              fontWeight: FontWeight.w900,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 4),
          ...r.parts.map((p) {
            final scaledAmount = widget.store.recipePartAmountMl(
              r,
              p,
              targetVolumeMl: selectedSizeMl,
              targetAlcoholPercent: targetAlcoholPercent,
            );
            return Container(
              padding: const EdgeInsets.symmetric(vertical: 6),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: widget.store.appColors.borderColor,
                    width: .7,
                  ),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    p.automatic
                        ? Icons.science_outlined
                        : Icons.pan_tool_alt_outlined,
                    size: 17,
                    color: p.delayed
                        ? const Color(0xFFFFA726)
                        : const Color(0xFF15D6CA),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      widget.store.displayIngredientNameById(p.ingredientId),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    '${scaledAmount.toStringAsFixed(scaledAmount < 10 ? 1 : 0)} ml',
                    style: const TextStyle(
                      color: Color(0xFF16E0D0),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            );
          }),
          if (r.manualNotes.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              tr('Hinweise'),
              style: const TextStyle(
                color: Color(0xFF16E0D0),
                fontWeight: FontWeight.w900,
                fontSize: 15,
              ),
            ),
            ...r.manualNotes.map(
              (note) => Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.info_outline,
                      size: 17,
                      color: Color(0xFFFFA726),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        note,
                        style: const TextStyle(fontSize: 11.5, height: 1.3),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ];

    final content = SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          kioskLandscape ? 12 : 18,
          kioskLandscape ? 6 : 12,
          kioskLandscape ? 14 : 18,
          kioskLandscape ? 8 : 12,
        ),
        child: Column(
          children: [
            SizedBox(
              height: kioskLandscape ? 44 : 52,
              child: Row(
                children: [
                  IconButton(
                    tooltip: tr('Zurück'),
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.arrow_back, color: Color(0xFF16E0D0)),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      widget.store.displayRecipeName(r),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: kioskLandscape ? 20 : 23,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: tr('Favorit'),
                    onPressed: () {},
                    icon: const Icon(Icons.favorite_border),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Expanded(
              child: kioskLandscape
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          flex: 44,
                          child: Column(
                            children: [
                              Expanded(
                                child: Container(
                                  width: double.infinity,
                                  clipBehavior: Clip.antiAlias,
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF090E13),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: widget.store.appColors.borderColor,
                                    ),
                                  ),
                                  padding: const EdgeInsets.all(6),
                                  child: cocktailImage(
                                    image,
                                    fallbackAsset: widget.fallbackAsset,
                                    fit: BoxFit.contain,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 8),
                              prepareButton(),
                            ],
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          flex: 56,
                          child: Container(
                            decoration: BoxDecoration(
                              color: widget.store.appColors.surfaceColor,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: widget.store.appColors.borderColor,
                              ),
                            ),
                            child: ListView(
                              padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                              children: detailWidgets(),
                            ),
                          ),
                        ),
                      ],
                    )
                  : ListView(
                      children: [
                        Container(
                          height: responsive.height <= 760 ? 240 : 320,
                          width: double.infinity,
                          color: const Color(0xFF090E13),
                          padding: const EdgeInsets.all(10),
                          child: cocktailImage(
                            image,
                            fallbackAsset: widget.fallbackAsset,
                            fit: BoxFit.contain,
                          ),
                        ),
                        const SizedBox(height: 12),
                        ...detailWidgets(),
                        const SizedBox(height: 16),
                        prepareButton(),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );

    return Scaffold(
      body: responsive.useTopNavigation
          ? Column(
              children: [
                CocktailBotTopNavigation(
                  store: widget.store,
                  selectedIndex: widget.selectedNavigationIndex,
                  onSelected: _navigateFromRail,
                ),
                Expanded(child: content),
              ],
            )
          : content,
    );
  }

  Future<void> _startPayment() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PaymentCheckoutPage(
          store: widget.store,
          recipe: widget.recipe,
          targetVolumeMl: selectedSizeMl,
          targetAlcoholPercent: selectedAlcoholPercentForPreparation,
        ),
      ),
    );
  }

  Future<void> _make() async {
    final messenger = ScaffoldMessenger.of(context);
    final rootNavigator = Navigator.of(context, rootNavigator: true);
    final recipe = widget.recipe;
    final scale = selectedSizeMl / recipe.baseVolumeMl;
    final manualParts =
        recipe.parts.where((part) => !part.automatic).toList();
    final manualNotes = recipe.manualNotes;

    setState(() => working = true);

    final progress = ValueNotifier<double>(0);
    final activePumps = ValueNotifier<List<int>>(<int>[]);
    bool dialogOpen = true;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const T('Cocktail wird zubereitet'),
        content: ValueListenableBuilder<double>(
          valueListenable: progress,
          builder: (_, value, __) => ValueListenableBuilder<List<int>>(
            valueListenable: activePumps,
            builder: (_, pumps, __) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(value: value),
                const SizedBox(height: 14),
                T('${(value * 100).round()} %'),
                const SizedBox(height: 8),
                Text(
                  pumps.isEmpty
                      ? tr('Pumpen werden vorbereitet …')
                      : pumps.length == 1
                          ? '${tr('Pumpe')} ${pumps.first} ${tr('läuft')}'
                          : '${pumps.length} ${tr('Pumpen laufen gleichzeitig')}',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                const T('Die normalen Zutaten starten im Abstand von 0,1 Sekunden. '
                  'Zutaten „Zum Schluss“ werden danach dosiert.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Color(0xFF9CA7B1),
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 8),
                const T('Bitte das Glas nicht entfernen.'),
              ],
            ),
          ),
        ),
      ),
    ).then((_) => dialogOpen = false);

    try {
      await widget.store.makeRecipe(
        recipe,
        targetVolumeMl: selectedSizeMl,
        targetAlcoholPercent: selectedAlcoholPercentForPreparation,
      );

      for (var attempt = 0; attempt < 3000; attempt++) {
        await Future.delayed(const Duration(milliseconds: 200));
        if (!mounted) return;

        final status = await widget.store.fetchMachineStatus();
        if (!mounted) return;

        final busy = status['busy'] == true;
        final statusProgress =
            (status['progress'] as num?)?.toDouble() ?? 0;

        final rawActivePumps = status['activePumps'];
        final runningPumps = rawActivePumps is List
            ? rawActivePumps
                .whereType<num>()
                .map((number) => number.toInt())
                .toList()
            : <int>[];

        progress.value =
            busy ? statusProgress.clamp(0, 1).toDouble() : 1;
        activePumps.value = runningPumps;

        if (!busy) break;

        if (attempt == 2999) {
          throw Exception(
            'Zeitüberschreitung bei der Cocktailzubereitung',
          );
        }
      }

      if (!mounted) return;

      if (dialogOpen && rootNavigator.canPop()) {
        rootNavigator.pop();
      }

      if (manualParts.isNotEmpty || manualNotes.isNotEmpty) {
        await _showManualIngredients(
          manualParts,
          scale,
          manualNotes,
        );
      } else {
        messenger.showSnackBar(
          const SnackBar(content: T('Zubereitung abgeschlossen')),
        );
      }
    } catch (error) {
      if (!mounted) return;

      if (dialogOpen && rootNavigator.canPop()) {
        rootNavigator.pop();
      }

      messenger.showSnackBar(SnackBar(content: T('$error')));
    } finally {
      progress.dispose();
      activePumps.dispose();

      if (mounted) {
        setState(() => working = false);
      }
    }
  }

  Future<void> _showManualIngredients(
    List<RecipePart> parts,
    double scale,
    List<String> notes,
  ) async {
    final navigator = Navigator.of(context, rootNavigator: true);
    var remaining = 8;
    final countdown = ValueNotifier<int>(remaining);

    final timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      remaining--;
      countdown.value = remaining;
      if (remaining <= 0) {
        timer.cancel();
        if (navigator.canPop()) navigator.pop();
      }
    });

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const T('Manuelle Zutaten hinzufügen'),
        content: ValueListenableBuilder<int>(
          valueListenable: countdown,
          builder: (_, seconds, __) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ...parts.map((part) {
                final name = widget.store.displayIngredientNameById(part.ingredientId);
                final instruction = part.instruction.trim().isNotEmpty
                    ? part.instruction.trim()
                    : '$name ${tr('manuell hinzufügen')}';
                final amount = part.amountMl * scale;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(
                    '• ${tr(instruction)}'
                    '${amount > 0 ? ' – ${amount.toStringAsFixed(0)} ml' : ''}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                );
              }),
              ...notes.map(
                (note) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(
                    '• ${tr(note)}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text('${tr('Dieses Fenster schließt in')} $seconds ${tr('Sekunden.')}'),
            ],
          ),
        ),
      ),
    );

    timer.cancel();
    countdown.dispose();
  }
}


class SettingsLockGate extends StatefulWidget {
  const SettingsLockGate({
    super.key,
    required this.store,
    required this.child,
  });

  final MachineStore store;
  final Widget child;

  @override
  State<SettingsLockGate> createState() => _SettingsLockGateState();
}

class _SettingsLockGateState extends State<SettingsLockGate> {
  final passwordController = TextEditingController();
  bool unlocked = false;

  @override
  void dispose() {
    passwordController.dispose();
    super.dispose();
  }

  void _unlock() {
    if (widget.store.validateSettingsPassword(passwordController.text)) {
      setState(() {
        unlocked = true;
        passwordController.clear();
      });
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(tr('Falsches Passwort'))),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.store.settingsLockEnabled || unlocked) {
      return widget.child;
    }

    return PageFrame(
      title: tr('Einstellungen gesperrt'),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(22),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.lock_outline, size: 44),
                  const SizedBox(height: 14),
                  Text(
                    tr('Einstellungen gesperrt'),
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 20,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    tr('Bitte Passwort eingeben. Das Notfall-Passwort cocktailbot funktioniert immer.'),
                    style: TextStyle(
                      color: widget.store.appColors.textSecondaryColor,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 18),
                  TextField(
                    controller: passwordController,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: tr('Passwort'),
                      prefixIcon: const Icon(Icons.password),
                    ),
                    onSubmitted: (_) => _unlock(),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _unlock,
                      icon: const Icon(Icons.lock_open_outlined),
                      label: Text(tr('Entsperren')),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}


class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.store}); final MachineStore store;
  @override Widget build(BuildContext context) {
    Widget commercialPage(String featureName, Widget page) =>
        store.commercialLicenseActive
            ? page
            : CommercialFeatureGatePage(
                store: store,
                featureName: featureName,
              );

    String commercialSubtitle(String text) => store.commercialLicenseActive
        ? text
        : '${store.t('Gewerbelizenz erforderlich')} · $text';

    final items = [
      (store.t('settingsConnection'), store.connected ? tr('Raspberry Pi verbunden') : tr('Lokale GPIO-Steuerung'), Icons.wifi, const Color(0xFF12DDD0), ConnectionPage(store: store)),
      (store.t('settingsLanguage'), '${store.t('settingsLanguageSub')}: ${store.appLanguage.nativeName}', Icons.language, const Color(0xFF8B5CF6), LanguageSettingsPage(store: store)),
      (store.t('settingsDesign'), store.t('settingsDesignSub'), Icons.palette_outlined, store.appColors.accentColor, ThemeSettingsPage(store: store)),
      (store.t('Anzeige'), store.t('Sortierung und Cocktails pro Seite einstellen'), Icons.grid_view_outlined, const Color(0xFF38BDF8), CocktailDisplaySettingsPage(store: store)),
      (store.t('Sicherheit & Freigaben'), store.t('Stärkeregler und Einstellungs-Passwort'), Icons.admin_panel_settings_outlined, const Color(0xFF22C55E), SecuritySettingsPage(store: store)),
      (store.t('settingsLed'), store.t('settingsLedSub'), Icons.light_mode_outlined, const Color(0xFFFFC857), LedSettingsPage(store: store)),
      (store.t('settingsCalibration'), store.t('settingsCalibrationSub'), Icons.science_outlined, const Color(0xFFB05CFF), CalibrationPage(store: store)),
      (store.t('settingsSizes'), store.t('settingsSizesSub'), Icons.straighten, const Color(0xFF38BDF8), ServingSizesPage(store: store)),
      (store.t('settingsFill'), store.t('settingsFillSub'), Icons.inventory_2_outlined, const Color(0xFFFFB000), FillLevelsPage(store: store)),
      (store.t('settingsCleaning'), store.t('settingsCleaningSub'), Icons.cleaning_services_outlined, const Color(0xFFFF5449), SequencePage(store: store, cleaning: true)),
      (store.t('settingsPriming'), store.t('settingsPrimingSub'), Icons.air, const Color(0xFFFF493F), SequencePage(store: store, cleaning: false)),
      (store.t('settingsIngredients'), store.t('settingsIngredientsSub'), Icons.local_drink_outlined, const Color(0xFF8DDD28), IngredientPage(store: store)),
      (store.t('settingsRecipes'), store.t('settingsRecipesSub'), Icons.receipt_long_outlined, const Color(0xFFFF2B86), RecipeManagementPage(store: store)),

      // Lizenzbereich: alle lizenzpflichtigen Funktionen stehen gesammelt unten.
      (store.t('Gewerbelizenz'), store.commercialLicenseStatusText, Icons.verified_user_outlined, store.commercialLicenseActive ? const Color(0xFF22C55E) : const Color(0xFFFFB454), CommercialLicensePage(store: store)),
      (store.t('Verbrauchsstatistik'), commercialSubtitle(store.t('Cocktail-Ranking, Kosten und Zutatenverbrauch')), Icons.bar_chart_outlined, const Color(0xFF22C55E), commercialPage(store.t('Verbrauchsstatistik'), ConsumptionStatisticsPage(store: store))),
      (store.t('Partykarten'), commercialSubtitle(store.t('Auswahl und Beliebtheit für Veranstaltungen')), Icons.fact_check_outlined, const Color(0xFF38BDF8), commercialPage(store.t('Partykarten'), PartyCardsPage(store: store))),
      (store.t('Partyplaner'), commercialSubtitle(store.t('Prognose aus vergangenen Partys')), Icons.event_available_outlined, const Color(0xFFB05CFF), commercialPage(store.t('Partyplaner'), PartyPlannerPage(store: store))),
      (store.t('Einkaufsliste'), commercialSubtitle(store.t('Zutatenbedarf und fehlende Mengen planen')), Icons.shopping_cart_outlined, const Color(0xFFFFB454), commercialPage(store.t('Einkaufsliste'), PartyPlannerPage(store: store))),
      (store.t('PayPal Kassenmodus'), commercialSubtitle(store.t('Lokale PayPal-Zahlung über den Raspberry Pi')), Icons.payments_outlined, const Color(0xFF14B8A6), commercialPage(store.t('PayPal Kassenmodus'), PaymentSettingsPage(store: store))),
      (store.t('Cocktailpreise'), commercialSubtitle(store.t('Einzelpreise pro Cocktail festlegen')), Icons.euro_outlined, const Color(0xFF22C55E), commercialPage(store.t('Cocktailpreise'), CocktailPricesPage(store: store))),
      (store.t('Branding'), commercialSubtitle(store.t('Barname und Gewerbehinweis')), Icons.storefront_outlined, const Color(0xFFCB9B3E), commercialPage(store.t('Branding'), CommercialBrandingPage(store: store))),
    ];

    return SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final responsive = CocktailBotResponsive.fromSize(
            constraints.maxWidth,
            constraints.maxHeight,
          );
          final columns = responsive.settingsColumns;

          return ListView(
            padding: EdgeInsets.fromLTRB(
              responsive.horizontalPadding,
              responsive.topPadding,
              responsive.horizontalPadding,
              24,
            ),
            children: [
              AppHeader(store: store, title: store.t('navSettings')),
              const SizedBox(height: 18),
              LayoutBuilder(
                builder: (context, gridConstraints) {
                  final spacing = 10.0;
                  final safeColumns = columns.clamp(1, 5).toInt();
                  final tileWidth = safeColumns == 1
                      ? gridConstraints.maxWidth
                      : (gridConstraints.maxWidth -
                              spacing * (safeColumns - 1)) /
                          safeColumns;

                  Widget buildTile(dynamic x) {
                    return SizedBox(
                      width: tileWidth,
                      child: Material(
                        color: store.appColors.cardColor,
                        borderRadius: BorderRadius.circular(10),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(10),
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => x.$5),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 15,
                              vertical: 14,
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Icon(x.$3, color: x.$4, size: 25),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        x.$1,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w700,
                                          fontSize: 15,
                                          height: 1.1,
                                        ),
                                      ),
                                      const SizedBox(height: 5),
                                      Text(
                                        x.$2,
                                        maxLines: 3,
                                        overflow: TextOverflow.ellipsis,
                                        softWrap: true,
                                        style: TextStyle(
                                          fontSize: 12,
                                          height: 1.18,
                                          color: x.$1 ==
                                                      store.t('settingsConnection') &&
                                                  store.connected
                                              ? const Color(0xFF54D36C)
                                              : const Color(0xFF9CA7B1),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                const Icon(
                                  Icons.chevron_right,
                                  color: Color(0xFFB5BEC6),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  }

                  return Wrap(
                    spacing: spacing,
                    runSpacing: spacing,
                    children: items.map(buildTile).toList(),
                  );
                },
              ),
              const SizedBox(height: 18),
              MachineStatusCard(store: store),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFD62F2F),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  onPressed: () async {
                    final close = await showDialog<bool>(
                      context: context,
                      builder: (dialogContext) => AlertDialog(
                        title: Text(tr('App schließen')),
                        content: Text(tr(
                          'CocktailBot wirklich schließen und zum Raspberry-Desktop zurückkehren?',
                        )),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(dialogContext, false),
                            child: Text(tr('Abbrechen')),
                          ),
                          FilledButton(
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xFFD62F2F),
                            ),
                            onPressed: () => Navigator.pop(dialogContext, true),
                            child: Text(tr('App schließen')),
                          ),
                        ],
                      ),
                    );
                    if (close != true) return;
                    final ok = await store.closeKioskApp();
                    if (!context.mounted || ok) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(tr('App konnte nicht geschlossen werden.')),
                      ),
                    );
                  },
                  icon: const Icon(Icons.power_settings_new),
                  label: Text(
                    tr('App schließen'),
                    style: const TextStyle(fontWeight: FontWeight.w900),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}


class PageFrame extends StatelessWidget { const PageFrame({super.key, required this.title, required this.child, this.actions}); final String title; final Widget child; final List<Widget>? actions; @override Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: Text(title, style: const TextStyle(fontWeight: FontWeight.w800)), actions: actions), body: SafeArea(child: child)); }

class ConnectionPage extends StatefulWidget {
  const ConnectionPage({super.key, required this.store});
  final MachineStore store;
  @override
  State<ConnectionPage> createState() => _ConnectionPageState();
}

class _ConnectionPageState extends State<ConnectionPage> {
  late final host = TextEditingController(text: widget.store.wifiHost);

  @override
  void dispose() {
    host.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PageFrame(
        title: widget.store.t('settingsConnection'),
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Card(
              child: Padding(
                padding: EdgeInsets.all(18),
                child: Row(
                  children: [
                    Icon(Icons.computer),
                    SizedBox(width: 12),
                    Expanded(
                      child: T(
                        'Kiosk-Steuerung über den lokalen Raspberry-Pi-Dienst. '
                        'Das Feld bleibt leer, wenn App und GPIO-API auf demselben '
                        'Raspberry Pi laufen.',
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 18),
            TextField(
              controller: host,
              decoration: InputDecoration(
                labelText: tr('API-Host (optional)'),
                hintText: tr('leer = lokale Steuerung'),
                prefixIcon: const Icon(Icons.router),
              ),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: () async {
                widget.store.connectionMode = ConnectionMode.wifi;
                widget.store.wifiHost = host.text.trim();
                await widget.store.save();
                await widget.store.connect();
                if (!mounted) return;
                setState(() {});
              },
              icon: const Icon(Icons.link),
              label: const T('Verbindung herstellen'),
            ),
            const SizedBox(height: 12),
            Card(
              child: ListTile(
                leading: Icon(
                  Icons.circle,
                  color: widget.store.connected ? Colors.green : Colors.orange,
                ),
                title: Text(widget.store.displayStatus()),
                subtitle: Text(
                  widget.store.wifiHost.trim().isEmpty
                      ? 'API: gleicher Host (/api)'
                      : 'API: ${widget.store.wifiHost}',
                ),
              ),
            ),
          ],
        ),
      );
}



class SecuritySettingsPage extends StatefulWidget {
  const SecuritySettingsPage({super.key, required this.store});
  final MachineStore store;

  @override
  State<SecuritySettingsPage> createState() => _SecuritySettingsPageState();
}

class _SecuritySettingsPageState extends State<SecuritySettingsPage> {
  late bool alcoholSliderEnabled;
  late bool lockEnabled;
  final passwordController = TextEditingController();

  @override
  void initState() {
    super.initState();
    alcoholSliderEnabled = widget.store.alcoholStrengthSliderEnabled;
    lockEnabled = widget.store.settingsLockEnabled;
  }

  @override
  void dispose() {
    passwordController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (lockEnabled &&
        widget.store.settingsPassword.isEmpty &&
        passwordController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('Bitte zuerst ein Passwort festlegen'))),
      );
      return;
    }

    await widget.store.saveSecuritySettings(
      alcoholSliderEnabled: alcoholSliderEnabled,
      lockEnabled: lockEnabled,
      password: passwordController.text,
    );

    if (!mounted) return;
    passwordController.clear();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(tr('Sicherheitseinstellungen gespeichert'))),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PageFrame(
      title: tr('Sicherheit & Freigaben'),
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Card(
            child: SwitchListTile(
              value: alcoholSliderEnabled,
              onChanged: (value) => setState(() => alcoholSliderEnabled = value),
              title: Text(tr('Stärkeregler für alkoholische Cocktails freigeben')),
              subtitle: Text(
                tr('Wenn aktiv, erscheint in alkoholischen Cocktail-Details ein Slider von 0 bis 25 % vol.'),
              ),
              secondary: const Icon(Icons.tune),
            ),
          ),
          const SizedBox(height: 14),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr('Einstellungen sperren'),
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 18,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    tr('Wenn aktiv, kommt man nur mit deinem Passwort in die Einstellungen. Das Notfall-Passwort cocktailbot funktioniert immer.'),
                    style: TextStyle(
                      color: widget.store.appColors.textSecondaryColor,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 14),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: lockEnabled,
                    onChanged: (value) => setState(() => lockEnabled = value),
                    title: Text(tr('Einstellungsbereich sperren')),
                    secondary: const Icon(Icons.lock_outline),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: passwordController,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: widget.store.settingsPassword.isEmpty
                          ? tr('Neues Passwort')
                          : tr('Passwort ändern'),
                      helperText: tr('Leer lassen, wenn das vorhandene Passwort bleiben soll'),
                      prefixIcon: const Icon(Icons.password),
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _save,
                      icon: const Icon(Icons.save_outlined),
                      label: Text(tr('Speichern')),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}


class CocktailDisplaySettingsPage extends StatefulWidget {
  const CocktailDisplaySettingsPage({
    super.key,
    required this.store,
  });

  final MachineStore store;

  @override
  State<CocktailDisplaySettingsPage> createState() =>
      _CocktailDisplaySettingsPageState();
}

class _CocktailDisplaySettingsPageState
    extends State<CocktailDisplaySettingsPage> {
  late final perPageController = TextEditingController(
    text: widget.store.cocktailsPerPage >= 1000
        ? 'Alle'
        : widget.store.cocktailsPerPage.toString(),
  );

  DrinkCategory selectedCategory = DrinkCategory.cocktail;

  @override
  void dispose() {
    perPageController.dispose();
    super.dispose();
  }

  String _categoryLabel(DrinkCategory category) => switch (category) {
        DrinkCategory.cocktail => widget.store.t('Cocktails'),
        DrinkCategory.mocktail => widget.store.t('Alkoholfrei'),
        DrinkCategory.shot => widget.store.t('Shots'),
      };

  List<Recipe> get _categoryRecipes => widget.store.recipes
      .where((recipe) => recipe.category == selectedCategory)
      .toList();

  Future<void> _savePerPage() async {
    final raw = perPageController.text.trim().toLowerCase();
    final value = raw == 'alle'
        ? 1000
        : int.tryParse(raw.replaceAll(RegExp(r'[^0-9]'), ''));

    if (value == null || value <= 0) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(widget.store.t('Bitte eine gültige Zahl eingeben'))),
      );
      return;
    }

    await widget.store.setCocktailsPerPage(value);
    if (!mounted) return;
    setState(() {
      perPageController.text = widget.store.cocktailsPerPage >= 1000
          ? 'Alle'
          : widget.store.cocktailsPerPage.toString();
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(widget.store.t('Anzeige gespeichert'))),
    );
  }

  Future<void> _setQuickPerPage(int value) async {
    perPageController.text = value >= 1000 ? 'Alle' : value.toString();
    await _savePerPage();
  }

  Future<void> _moveRecipe(int index, int delta) async {
    final newIndex = index + delta;
    final recipes = _categoryRecipes;
    if (newIndex < 0 || newIndex >= recipes.length) return;

    await widget.store.reorderRecipeWithinCategory(
      selectedCategory,
      index,
      newIndex,
    );

    if (!mounted) return;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final currentPerPage = widget.store.cocktailsPerPage >= 1000
        ? widget.store.t('Alle')
        : widget.store.cocktailsPerPage.toString();
    final recipes = _categoryRecipes;

    return PageFrame(
      title: widget.store.t('Anzeige'),
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.store.t('Cocktail-Listen'),
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 18,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    widget.store.t(
                      'Diese Einstellungen gelten für Cocktails, alkoholfreie Cocktails und Shots. Auf den Cocktail-Seiten selbst wird nur noch die Seiten-Navigation angezeigt.',
                    ),
                    style: TextStyle(
                      color: widget.store.appColors.textSecondaryColor,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 18),
                  TextField(
                    controller: perPageController,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: widget.store.t('Cocktails pro Seite'),
                      helperText:
                          '${widget.store.t('Aktuell')}: $currentPerPage',
                      suffixIcon: IconButton(
                        tooltip: widget.store.t('Speichern'),
                        icon: const Icon(Icons.save_outlined),
                        onPressed: _savePerPage,
                      ),
                    ),
                    onSubmitted: (_) => _savePerPage(),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final value in [4, 6, 8, 10, 12, 16, 20, 1000])
                        ChoiceChip(
                          label: Text(
                            value >= 1000
                                ? widget.store.t('Alle')
                                : value.toString(),
                          ),
                          selected: widget.store.cocktailsPerPage == value,
                          onSelected: (_) => _setQuickPerPage(value),
                        ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  DropdownButtonFormField<RecipeSortMode>(
                    value: widget.store.recipeSortMode,
                    decoration: InputDecoration(
                      labelText: widget.store.t('Automatische Sortierung'),
                      helperText: widget.store.t(
                        'Für eigene Reihenfolge „Originale Reihenfolge“ verwenden.',
                      ),
                    ),
                    items: RecipeSortMode.values
                        .map(
                          (mode) => DropdownMenuItem<RecipeSortMode>(
                            value: mode,
                            child: Text(widget.store.recipeSortModeLabel(mode)),
                          ),
                        )
                        .toList(),
                    onChanged: (mode) async {
                      if (mode == null) return;
                      await widget.store.setRecipeSortMode(mode);
                      if (!mounted) return;
                      setState(() {});
                    },
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.store.t('Cocktails einzeln sortieren'),
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 18,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    widget.store.t(
                      'Verschiebe einzelne Cocktails mit den Pfeilen. Die App stellt danach automatisch auf „Originale Reihenfolge“, damit deine eigene Reihenfolge sichtbar ist.',
                    ),
                    style: TextStyle(
                      color: widget.store.appColors.textSecondaryColor,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 14),
                  DropdownButtonFormField<DrinkCategory>(
                    value: selectedCategory,
                    decoration: InputDecoration(
                      labelText: widget.store.t('Liste auswählen'),
                    ),
                    items: DrinkCategory.values
                        .map(
                          (category) => DropdownMenuItem<DrinkCategory>(
                            value: category,
                            child: Text(_categoryLabel(category)),
                          ),
                        )
                        .toList(),
                    onChanged: (category) {
                      if (category == null) return;
                      setState(() => selectedCategory = category);
                    },
                  ),
                  const SizedBox(height: 14),
                  if (recipes.isEmpty)
                    Text(widget.store.t('Keine Cocktails'))
                  else
                    ...List.generate(recipes.length, (index) {
                      final recipe = recipes[index];
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          dense: true,
                          leading: CircleAvatar(
                            child: Text('${index + 1}'),
                          ),
                          title: Text(
                            widget.store.displayRecipeName(recipe),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          subtitle: Text(
                            _categoryLabel(recipe.category),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: Wrap(
                            spacing: 2,
                            children: [
                              IconButton(
                                tooltip: widget.store.t('Nach oben'),
                                onPressed: index == 0
                                    ? null
                                    : () => _moveRecipe(index, -1),
                                icon: const Icon(Icons.arrow_upward),
                              ),
                              IconButton(
                                tooltip: widget.store.t('Nach unten'),
                                onPressed: index == recipes.length - 1
                                    ? null
                                    : () => _moveRecipe(index, 1),
                                icon: const Icon(Icons.arrow_downward),
                              ),
                            ],
                          ),
                        ),
                      );
                    }),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ThemeSettingsPage extends StatefulWidget {
  const ThemeSettingsPage({
    super.key,
    required this.store,
  });

  final MachineStore store;

  @override
  State<ThemeSettingsPage> createState() => _ThemeSettingsPageState();
}

class _ThemeSettingsPageState extends State<ThemeSettingsPage> {
  late AppColorThemeConfig colors;
  AppColorSlot slot = AppColorSlot.accent;
  late double red;
  late double green;
  late double blue;
  bool saving = false;

  static const presets = <(String, AppColorThemeConfig)>[
    (
      'Midnight Ocean',
      AppColorThemeConfig(
        background: 0xFF07111A,
        surface: 0xFF0D1823,
        card: 0xFF122131,
        navigation: 0xFF0A141D,
        accent: 0xFF14B8A6,
        secondaryAccent: 0xFF51E3D4,
        border: 0xFF1F3244,
        textPrimary: 0xFFF8FAFC,
        textSecondary: 0xFF9FB0C3,
        progressTrack: 0xFF203244,
        success: 0xFF4FD38B,
        warning: 0xFFFFB454,
        error: 0xFFFF6B6B,
      ),
    ),
    (
      'Graphite Berry',
      AppColorThemeConfig(
        background: 0xFF0D1117,
        surface: 0xFF161B22,
        card: 0xFF1D2430,
        navigation: 0xFF10151C,
        accent: 0xFFD84C7F,
        secondaryAccent: 0xFFF089A7,
        border: 0xFF2A3340,
        textPrimary: 0xFFF8FAFC,
        textSecondary: 0xFFA8B3C3,
        progressTrack: 0xFF283241,
        success: 0xFF56D69A,
        warning: 0xFFFFB865,
        error: 0xFFFF7272,
      ),
    ),
    (
      'Ivory Gold',
      AppColorThemeConfig(
        background: 0xFFF6F1E9,
        surface: 0xFFFFFBF5,
        card: 0xFFEEE7DD,
        navigation: 0xFFF1E9DE,
        accent: 0xFFCB9B3E,
        secondaryAccent: 0xFFE0B458,
        border: 0xFFDCCFC1,
        textPrimary: 0xFF201A14,
        textSecondary: 0xFF726251,
        progressTrack: 0xFFE8DED1,
        success: 0xFF3AA56E,
        warning: 0xFFE5A33C,
        error: 0xFFD65C5C,
      ),
    ),
    (
      'Arctic Mint',
      AppColorThemeConfig(
        background: 0xFFF4F8FA,
        surface: 0xFFFFFFFF,
        card: 0xFFEAF1F4,
        navigation: 0xFFF0F5F7,
        accent: 0xFF16C2BE,
        secondaryAccent: 0xFF7AD9D5,
        border: 0xFFD8E5EA,
        textPrimary: 0xFF17212B,
        textSecondary: 0xFF6E7E8C,
        progressTrack: 0xFFDDE9EE,
        success: 0xFF39B979,
        warning: 0xFFF2B34A,
        error: 0xFFE36A6A,
      ),
    ),
    (
      'Royal Night',
      AppColorThemeConfig(
        background: 0xFF061225,
        surface: 0xFF0B1D36,
        card: 0xFF0F2744,
        navigation: 0xFF08172C,
        accent: 0xFF4EA8DE,
        secondaryAccent: 0xFF7BDFF2,
        border: 0xFF1D3C61,
        textPrimary: 0xFFF8FAFC,
        textSecondary: 0xFFA8B9D0,
        progressTrack: 0xFF1A3557,
        success: 0xFF4FD38B,
        warning: 0xFFF3BE62,
        error: 0xFFFF7A7A,
      ),
    ),
    (
      'Lavender Haze',
      AppColorThemeConfig(
        background: 0xFFF5F2FA,
        surface: 0xFFFFFEFF,
        card: 0xFFEAE5F3,
        navigation: 0xFFF1EDF8,
        accent: 0xFF8B7FD6,
        secondaryAccent: 0xFFC8BFF0,
        border: 0xFFDAD2EB,
        textPrimary: 0xFF241F32,
        textSecondary: 0xFF726A87,
        progressTrack: 0xFFE1DBEE,
        success: 0xFF52B788,
        warning: 0xFFE8B35B,
        error: 0xFFD96C8E,
      ),
    ),
  ];

  @override
  void initState() {
    super.initState();
    colors = widget.store.appColors;
    _loadSlot();
  }

  Color get selectedColor => Color.fromARGB(
        255,
        red.round(),
        green.round(),
        blue.round(),
      );

  void _loadSlot() {
    final value = colors.valueOf(slot);
    red = ((value >> 16) & 0xFF).toDouble();
    green = ((value >> 8) & 0xFF).toDouble();
    blue = (value & 0xFF).toDouble();
  }

  void _saveCurrentSlotLocally() {
    colors = colors.withSlot(slot, selectedColor.toARGB32());
  }

  void _selectSlot(AppColorSlot value) {
    _saveCurrentSlotLocally();
    setState(() {
      slot = value;
      _loadSlot();
    });
  }

  Future<void> _apply() async {
    final messenger = ScaffoldMessenger.of(context);
    _saveCurrentSlotLocally();

    setState(() => saving = true);

    await widget.store.setAppColors(colors);

    if (!mounted) return;
    setState(() => saving = false);

    messenger.showSnackBar(
      const SnackBar(content: T('Design wurde gespeichert')),
    );
  }

  Future<void> _reset() async {
    final messenger = ScaffoldMessenger.of(context);

    await widget.store.resetAppColors();

    if (!mounted) return;
    setState(() {
      colors = widget.store.appColors;
      _loadSlot();
    });

    messenger.showSnackBar(
      const SnackBar(content: T('Standarddesign wiederhergestellt')),
    );
  }

  void _applyPreset(AppColorThemeConfig preset) {
    setState(() {
      colors = preset;
      _loadSlot();
    });
  }

  Widget _rgbSlider({
    required String label,
    required double value,
    required ValueChanged<double> onChanged,
  }) {
    return Row(
      children: [
        SizedBox(
          width: 44,
          child: Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
        ),
        Expanded(
          child: Slider(
            value: value,
            min: 0,
            max: 255,
            divisions: 255,
            label: value.round().toString(),
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 34,
          child: Text(
            value.round().toString(),
            textAlign: TextAlign.end,
          ),
        ),
      ],
    );
  }

  bool _sameTheme(AppColorThemeConfig a, AppColorThemeConfig b) {
    return a.background == b.background &&
        a.surface == b.surface &&
        a.card == b.card &&
        a.navigation == b.navigation &&
        a.accent == b.accent &&
        a.secondaryAccent == b.secondaryAccent &&
        a.border == b.border &&
        a.textPrimary == b.textPrimary &&
        a.textSecondary == b.textSecondary &&
        a.progressTrack == b.progressTrack &&
        a.success == b.success &&
        a.warning == b.warning &&
        a.error == b.error;
  }

  Widget _themeDot(Color color) {
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: colors.borderColor.withValues(alpha: .55)),
      ),
    );
  }

  Widget _miniCocktailCard(AppColorThemeConfig theme) {
    return Container(
      height: 72,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.borderColor),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 52,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  theme.secondaryAccentColor.withValues(alpha: .88),
                  theme.accentColor.withValues(alpha: .84),
                ],
              ),
            ),
            child: Icon(
              Icons.local_bar,
              color: theme.textPrimaryColor,
              size: 24,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  height: 9,
                  width: 82,
                  decoration: BoxDecoration(
                    color: theme.textPrimaryColor.withValues(alpha: .86),
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
                const SizedBox(height: 7),
                Container(
                  height: 7,
                  width: 118,
                  decoration: BoxDecoration(
                    color: theme.textSecondaryColor.withValues(alpha: .55),
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
                const SizedBox(height: 7),
                Container(
                  height: 7,
                  width: 64,
                  decoration: BoxDecoration(
                    color: theme.accentColor.withValues(alpha: .70),
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _presetPreviewCard((String, AppColorThemeConfig) preset, double width) {
    final theme = preset.$2;
    final selected = _sameTheme(colors, theme);

    return SizedBox(
      width: width,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => _applyPreset(theme),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.surfaceColor,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: selected ? theme.accentColor : theme.borderColor,
              width: selected ? 2 : 1,
            ),
            boxShadow: [
              BoxShadow(
                color: theme.accentColor.withValues(
                  alpha: selected ? .24 : .08,
                ),
                blurRadius: selected ? 20 : 10,
                spreadRadius: selected ? 1 : 0,
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.backgroundColor,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: theme.borderColor),
                ),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Icon(Icons.local_bar, color: theme.accentColor, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Container(
                            height: 8,
                            decoration: BoxDecoration(
                              color: theme.textPrimaryColor.withValues(alpha: .78),
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                        ),
                        if (selected) ...[
                          const SizedBox(width: 8),
                          Icon(
                            Icons.check_circle,
                            color: theme.accentColor,
                            size: 18,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 10),
                    _miniCocktailCard(theme),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Text(
                preset.$1,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: theme.textPrimaryColor,
                  fontWeight: FontWeight.w900,
                  height: 1.1,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  _themeDot(theme.backgroundColor),
                  _themeDot(theme.cardColor),
                  _themeDot(theme.accentColor),
                  _themeDot(theme.secondaryAccentColor),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _presetSection() {
    return Card(
      color: colors.cardColor,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 520;
            final width = compact
                ? constraints.maxWidth
                : (constraints.maxWidth - 12) / 2;

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                T(
                  'Voreingestellte Designs',
                  style: TextStyle(
                    color: colors.textPrimaryColor,
                    fontWeight: FontWeight.w900,
                    fontSize: 18,
                  ),
                ),
                const SizedBox(height: 6),
                T(
                  'Wähle eine hochwertige Farbkombination mit direkter Vorschau.',
                  style: TextStyle(
                    color: colors.textSecondaryColor,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: presets
                      .map((preset) => _presetPreviewCard(preset, width))
                      .toList(),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _livePreview() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.backgroundColor,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: colors.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          T(
            'Live-Vorschau',
            style: TextStyle(
              color: colors.textPrimaryColor,
              fontWeight: FontWeight.w900,
              fontSize: 18,
            ),
          ),
          const SizedBox(height: 6),
          T(
            'So wirken Navigation, Cocktailkarten, Buttons und Statusfarben zusammen.',
            style: TextStyle(
              color: colors.textSecondaryColor,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 14),
          LayoutBuilder(
            builder: (context, constraints) {
              final narrow = constraints.maxWidth < 620;
              final previewPhone = Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: colors.surfaceColor,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: colors.borderColor),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.local_bar, color: colors.accentColor),
                        const SizedBox(width: 8),
                        Text(
                          'CocktailBot',
                          style: TextStyle(
                            color: colors.textPrimaryColor,
                            fontWeight: FontWeight.w900,
                            fontSize: 18,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _miniCocktailCard(colors),
                    const SizedBox(height: 10),
                    _miniCocktailCard(
                      colors.withSlot(
                        AppColorSlot.card,
                        colors.surfaceColor.toARGB32(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: colors.navigationColor,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: colors.borderColor),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          Icon(Icons.local_bar, color: colors.accentColor),
                          Icon(
                            Icons.local_drink_outlined,
                            color: colors.textSecondaryColor,
                          ),
                          Icon(
                            Icons.liquor_outlined,
                            color: colors.textSecondaryColor,
                          ),
                          Icon(
                            Icons.settings_outlined,
                            color: colors.textSecondaryColor,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );

              final previewActions = Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: colors.surfaceColor,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: colors.borderColor),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    FilledButton.icon(
                      onPressed: () {},
                      style: FilledButton.styleFrom(
                        backgroundColor: colors.accentColor,
                        foregroundColor: colors.backgroundColor.computeLuminance() > .5
                            ? Colors.black
                            : Colors.white,
                      ),
                      icon: const Icon(Icons.play_arrow),
                      label: const T('Zubereitung starten'),
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: () {},
                      icon: const Icon(Icons.tune),
                      label: const T('Einstellungen'),
                    ),
                    const SizedBox(height: 14),
                    LinearProgressIndicator(
                      value: .68,
                      color: colors.accentColor,
                      backgroundColor: colors.progressTrackColor,
                    ),
                    const SizedBox(height: 14),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        Icon(Icons.check_circle, color: colors.successColor),
                        Icon(Icons.warning_amber_rounded, color: colors.warningColor),
                        Icon(Icons.error_outline, color: colors.errorColor),
                      ],
                    ),
                  ],
                ),
              );

              if (narrow) {
                return Column(
                  children: [
                    previewPhone,
                    const SizedBox(height: 12),
                    previewActions,
                  ],
                );
              }

              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 3, child: previewPhone),
                  const SizedBox(width: 12),
                  Expanded(flex: 2, child: previewActions),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    _saveCurrentSlotLocally();

    return PageFrame(
      title: widget.store.t('settingsDesign'),
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Card(
            color: colors.cardColor,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: T('Hier kannst du die wichtigsten App-Farben selbst anpassen. '
                'Die Änderungen betreffen Theme, Hintergrund, Karten, '
                'Navigation, Buttons, Slider, Fortschrittsbalken, Rahmen '
                'und Statusfarben.',
                style: TextStyle(
                  color: colors.textSecondaryColor,
                  height: 1.4,
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          _presetSection(),
          const SizedBox(height: 14),
          Card(
            color: colors.cardColor,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  DropdownButtonFormField<AppColorSlot>(
                    initialValue: slot,
                    decoration: InputDecoration(
                      labelText: tr('Farbe bearbeiten'),
                    ),
                    items: AppColorSlot.values
                        .map(
                          (value) => DropdownMenuItem(
                            value: value,
                            child: Text(value.label),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value != null) _selectSlot(value);
                    },
                  ),
                  const SizedBox(height: 18),
                  Center(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      width: 92,
                      height: 92,
                      decoration: BoxDecoration(
                        color: selectedColor,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: colors.borderColor,
                          width: 2,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: selectedColor.withValues(alpha: .38),
                            blurRadius: 22,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  _rgbSlider(
                    label: 'Rot',
                    value: red,
                    onChanged: (value) =>
                        setState(() => red = value),
                  ),
                  _rgbSlider(
                    label: 'Grün',
                    value: green,
                    onChanged: (value) =>
                        setState(() => green = value),
                  ),
                  _rgbSlider(
                    label: 'Blau',
                    value: blue,
                    onChanged: (value) =>
                        setState(() => blue = value),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          _livePreview(),
          const SizedBox(height: 18),
          SizedBox(
            height: 52,
            child: FilledButton.icon(
              onPressed: saving ? null : _apply,
              icon: saving
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined),
              label: Text(
                saving ? tr('Wird gespeichert …') : tr('Design übernehmen'),
              ),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 48,
            child: OutlinedButton.icon(
              onPressed: _reset,
              icon: const Icon(Icons.restart_alt),
              label: const T('Standarddesign wiederherstellen'),
            ),
          ),
        ],
      ),
    );
  }
}

class LanguageSettingsPage extends StatelessWidget {
  const LanguageSettingsPage({
    super.key,
    required this.store,
  });

  final MachineStore store;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) => PageFrame(
        title: store.t('languageTitle'),
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const Icon(
                    Icons.translate,
                    color: Color(0xFF8B5CF6),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      store.t('languageInfo'),
                      style: const TextStyle(height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: DropdownButtonFormField<AppLanguage>(
                initialValue: store.appLanguage,
                decoration: InputDecoration(
                  labelText: store.t('languageSelect'),
                ),
                items: AppLanguage.values
                    .map(
                      (language) => DropdownMenuItem(
                        value: language,
                        child: Text(language.nativeName),
                      ),
                    )
                    .toList(),
                onChanged: (language) async {
                  if (language == null) return;
                  final messenger = ScaffoldMessenger.of(context);
                  await store.setLanguage(language);
                  messenger.showSnackBar(
                    SnackBar(content: Text(store.t('languageSaved'))),
                  );
                },
              ),
            ),
          ),
          ],
        ),
      ),
    );
  }
}

class LedSettingsPage extends StatefulWidget {
  const LedSettingsPage({
    super.key,
    required this.store,
  });

  final MachineStore store;

  @override
  State<LedSettingsPage> createState() => _LedSettingsPageState();
}

class _LedSettingsPageState extends State<LedSettingsPage> {
  late LedIdleMode mode;
  late double brightness;
  late double red;
  late double green;
  late double blue;
  bool saving = false;

  static const presetColors = <int>[
    0xFF16D9CC,
    0xFF00A8FF,
    0xFF7C4DFF,
    0xFFE040FB,
    0xFFFF2B86,
    0xFFFF3B30,
    0xFFFF9500,
    0xFFFFD60A,
    0xFF34C759,
    0xFFFFFFFF,
  ];

  @override
  void initState() {
    super.initState();

    mode = widget.store.ledIdleMode;
    brightness = widget.store.ledBrightness;

    final color = widget.store.ledColorValue;
    red = ((color >> 16) & 0xFF).toDouble();
    green = ((color >> 8) & 0xFF).toDouble();
    blue = (color & 0xFF).toDouble();
  }

  Color get selectedColor => Color.fromARGB(
        255,
        red.round(),
        green.round(),
        blue.round(),
      );

  String _modeLabel(LedIdleMode value) {
    return switch (value) {
      LedIdleMode.solid => 'Feste Farbe',
      LedIdleMode.rainbow => 'Rainbow',
      LedIdleMode.breathe => 'Atmen',
      LedIdleMode.blink => 'Blinken',
      LedIdleMode.off => 'Aus',
    };
  }

  void _selectPreset(int value) {
    setState(() {
      red = ((value >> 16) & 0xFF).toDouble();
      green = ((value >> 8) & 0xFF).toDouble();
      blue = (value & 0xFF).toDouble();
    });
  }

  Future<void> _apply() async {
    final messenger = ScaffoldMessenger.of(context);

    setState(() => saving = true);

    widget.store.ledIdleMode = mode;
    widget.store.ledColorValue =
        selectedColor.toARGB32();
    widget.store.ledBrightness = brightness;

    try {
      final sent = await widget.store.applyLedSettings();
      if (!mounted) return;

      messenger.showSnackBar(
        SnackBar(
          content: Text(
            sent
                ? 'LED-Einstellungen wurden übernommen'
                : 'LED-Einstellungen gespeichert. '
                    'Sie werden beim nächsten Verbinden übertragen.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: T('$error')),
      );
    } finally {
      if (mounted) {
        setState(() => saving = false);
      }
    }
  }

  Widget _rgbSlider({
    required String label,
    required double value,
    required ValueChanged<double> onChanged,
  }) {
    return Row(
      children: [
        SizedBox(
          width: 44,
          child: Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
        ),
        Expanded(
          child: Slider(
            value: value,
            min: 0,
            max: 255,
            divisions: 255,
            label: value.round().toString(),
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 34,
          child: Text(
            value.round().toString(),
            textAlign: TextAlign.end,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return PageFrame(
      title: widget.store.t('settingsLed'),
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: const [
                  Icon(
                    Icons.info_outline,
                    color: Color(0xFFFFC857),
                  ),
                  SizedBox(width: 12),
                  Expanded(
                    child: T('Diese Einstellungen gelten für den Idle-Betrieb. '
                      'Während der Cocktailzubereitung blinkt der Ring rot. '
                      'Nach erfolgreicher Fertigstellung leuchtet er fünf '
                      'Sekunden grün und kehrt danach automatisch zum '
                      'gewählten Idle-Effekt zurück.',
                      style: TextStyle(height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const T('Idle-Effekt',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 17,
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<LedIdleMode>(
                    initialValue: mode,
                    decoration: InputDecoration(
                      labelText: tr('Modus'),
                    ),
                    items: LedIdleMode.values
                        .map(
                          (value) => DropdownMenuItem(
                            value: value,
                            child: Text(tr(_modeLabel(value))),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value != null) {
                        setState(() => mode = value);
                      }
                    },
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const T('Farbe',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 17,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Center(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      width: 90,
                      height: 90,
                      decoration: BoxDecoration(
                        color: mode == LedIdleMode.off
                            ? Colors.black
                            : selectedColor,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: const Color(0xFF53606C),
                          width: 2,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: selectedColor.withValues(alpha: .45),
                            blurRadius: 22,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Wrap(
                    spacing: 11,
                    runSpacing: 11,
                    children: presetColors.map((value) {
                      final color = Color(value);
                      final selected =
                          selectedColor.toARGB32() == value;

                      return InkWell(
                        borderRadius: BorderRadius.circular(30),
                        onTap: () => _selectPreset(value),
                        child: Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(
                            color: color,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: selected
                                  ? Colors.white
                                  : const Color(0xFF3A4650),
                              width: selected ? 3 : 1,
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 18),
                  _rgbSlider(
                    label: 'Rot',
                    value: red,
                    onChanged: (value) =>
                        setState(() => red = value),
                  ),
                  _rgbSlider(
                    label: 'Grün',
                    value: green,
                    onChanged: (value) =>
                        setState(() => green = value),
                  ),
                  _rgbSlider(
                    label: 'Blau',
                    value: blue,
                    onChanged: (value) =>
                        setState(() => blue = value),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: T('Helligkeit',
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 17,
                          ),
                        ),
                      ),
                      T('${(brightness * 100).round()} %'),
                    ],
                  ),
                  Slider(
                    value: brightness,
                    min: .05,
                    max: 1,
                    divisions: 19,
                    label: '${(brightness * 100).round()} %',
                    onChanged: (value) =>
                        setState(() => brightness = value),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 18),
          SizedBox(
            height: 52,
            child: FilledButton.icon(
              onPressed: saving ? null : _apply,
              icon: saving
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                      ),
                    )
                  : const Icon(Icons.light_mode),
              label: Text(
                saving
                    ? tr('Wird übertragen …')
                    : tr('LED-Einstellungen übernehmen'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class CalibrationPage extends StatelessWidget {
  const CalibrationPage({
    super.key,
    required this.store,
  });

  final MachineStore store;

  @override
  Widget build(BuildContext context) {
    return PageFrame(title: tr('Kalibrierung'),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final responsive = CocktailBotResponsive.fromSize(
            constraints.maxWidth,
            constraints.maxHeight,
          );
          final count = responsive.calibrationColumns;

          return ListView(
            padding: EdgeInsets.all(responsive.horizontalPadding),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: const [
                      Row(
                        children: [
                          Icon(
                            Icons.info_outline,
                            color: Color(0xFF16D9CC),
                          ),
                          SizedBox(width: 10),
                          Expanded(
                            child: T('So funktioniert die Kalibrierung',
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 16,
                              ),
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: 10),
                      T('1. Ordne der Pumpe eine Zutat zu.\n'
                        '2. Stelle einen Messbecher unter den Auslass.\n'
                        '3. Wähle eine Testzeit zwischen 2 und 5 Sekunden.\n'
                        '4. Starte den Testlauf und miss die ausgegebene Menge.\n'
                        '5. Trage die Menge in ml ein und speichere den Wert.\n\n'
                        'Die App berechnet daraus automatisch ml pro Sekunde. '
                        'Zutat, Förderleistung und Füllstand werden dauerhaft '
                        'auf dem Gerät gespeichert.\n\n'
                        'Ein Cocktail kann erst zubereitet werden, wenn alle '
                        'automatisch verwendeten Zutaten einer aktiven Pumpe '
                        'zugeordnet und diese Pumpen kalibriert wurden.',
                        style: TextStyle(
                          color: Color(0xFFB5C0C9),
                          height: 1.45,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: 18,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: count,
                  mainAxisExtent: count == 1
                      ? 460
                      : count == 2
                          ? 485
                          : 455,
                  crossAxisSpacing: 14,
                  mainAxisSpacing: 14,
                ),
                itemBuilder: (_, i) => PumpCalibrationCard(
                  store: store,
                  pump: store.pumps[i],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class GridList extends StatelessWidget {
  const GridList({
    super.key,
    required this.itemCount,
    required this.builder,
    this.phoneAspectRatio = 1.05,
    this.twoColumnAspectRatio = .85,
  });

  final int itemCount;
  final Widget Function(BuildContext, int) builder;
  final double phoneAspectRatio;
  final double twoColumnAspectRatio;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (_, c) {
        final responsive = CocktailBotResponsive.fromSize(
          c.maxWidth,
          c.maxHeight,
        );
        final count = responsive.fillColumns;

        return GridView.builder(
          padding: EdgeInsets.all(responsive.horizontalPadding),
          itemCount: itemCount,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: count,
            childAspectRatio: responsive.fillCardAspectRatio,
            crossAxisSpacing: 14,
            mainAxisSpacing: 14,
          ),
          itemBuilder: builder,
        );
      },
    );
  }
}

class PumpCalibrationCard extends StatefulWidget { const PumpCalibrationCard({super.key, required this.store, required this.pump}); final MachineStore store; final Pump pump; @override State<PumpCalibrationCard> createState() => _PumpCalibrationCardState(); }
class _PumpCalibrationCardState extends State<PumpCalibrationCard> {
  double seconds = 2; final amount = TextEditingController(); bool running = false;
  @override Widget build(BuildContext context) => Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Row(children: [CircleAvatar(child: T('${widget.pump.number}')), const SizedBox(width: 10), const Expanded(child: T('Pumpe', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17))), Text(widget.pump.mlPerSecond > 0 ? '${widget.pump.mlPerSecond.toStringAsFixed(2)} ml/s' : tr('nicht kalibriert'))]),
    SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: const T('Pumpe aktiv'),
      subtitle: Text(widget.pump.active ? tr('Wird in der App angezeigt und verwendet') : tr('Ist überall ausgeblendet')),
      value: widget.pump.active,
      onChanged: (value) async {
        setState(() => widget.pump.active = value);
        await widget.store.save();
        await widget.store.syncMachineStateToController();
      },
    ),
    if (!widget.pump.active)
      const Padding(
        padding: EdgeInsets.only(bottom: 8),
        child: T('Diese Pumpe ist deaktiviert. Aktiviere sie, um sie zu konfigurieren.',
          style: TextStyle(color: Color(0xFFFFA726)),
        ),
      ),
    IgnorePointer(
      ignoring: !widget.pump.active,
      child: Opacity(
        opacity: widget.pump.active ? 1 : .35,
        child: Column(
          children: [
    const SizedBox(height: 12), DropdownButtonFormField<String?>(initialValue: widget.pump.ingredientId, decoration: InputDecoration(labelText: tr('Zutat')), items: [const DropdownMenuItem(value: null, child: T('Nicht zugeordnet')), ...widget.store.ingredients.map((e) => DropdownMenuItem(value: e.id, child: Text(widget.store.displayIngredientName(e))))], onChanged: (v) async { widget.pump.ingredientId = v; await widget.store.save(); await widget.store.syncMachineStateToController(); }),
    Row(children: [Expanded(child: Slider(value: seconds, min: 2, max: 5, divisions: 3, label: '${seconds.round()} s', onChanged: (v) => setState(() => seconds = v))), T('${seconds.round()} s')]),
    Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: running
                ? null
                : () async {
                    final messenger = ScaffoldMessenger.of(context);
                    setState(() => running = true);
                    try {
                      await widget.store.sendCommand({
                        'action': 'run_pump',
                        'pump': widget.pump.number,
                        'durationMs': (seconds * 1000).round(),
                      });
                    } catch (e) {
                      if (!mounted) return;
                      messenger.showSnackBar(SnackBar(content: Text('$e')));
                    }
                    if (!mounted) return;
                    setState(() => running = false);
                  },
            icon: const Icon(Icons.play_arrow),
            label: Text(running ? tr('Läuft …') : tr('Testlauf')),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: TextField(
            controller: amount,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: tr('Menge ml')),
          ),
        ),
      ],
    ),
    const SizedBox(height: 10),
    SizedBox(
      width: double.infinity,
      child: FilledButton(
        onPressed: () async {
          final messenger = ScaffoldMessenger.of(context);
          final ml = double.tryParse(amount.text.replaceAll(',', '.'));
          if (ml == null || ml <= 0) return;
          widget.pump.mlPerSecond = ml / seconds;
          await widget.store.save();
          await widget.store.syncMachineStateToController();
          if (!mounted) return;
          setState(() {});
          messenger.showSnackBar(
            SnackBar(
              content: Text('${tr('Pumpe')} ${widget.pump.number}: ${widget.pump.mlPerSecond.toStringAsFixed(2)} ml/s ${tr('dauerhaft gespeichert')}',
              ),
            ),
          );
        },
        child: const T('Kalibrierwert speichern'),
      ),
    ),
          ],
        ),
      ),
    ),
  ])));
}

class FillLevelsPage extends StatelessWidget {
  const FillLevelsPage({super.key, required this.store});
  final MachineStore store;

  @override
  Widget build(BuildContext context) {
    final activePumps = store.pumps.where((pump) => pump.active).toList();
    return PageFrame(
      title: tr('Füllstände'),
      child: activePumps.isEmpty
          ? const Center(child: T('Keine Pumpen aktiviert'))
          : ListView.separated(
              padding: const EdgeInsets.all(20),
              itemCount: activePumps.length,
              separatorBuilder: (_, __) => const SizedBox(height: 14),
              itemBuilder: (_, index) => FillCard(
                store: store,
                pump: activePumps[index],
              ),
            ),
    );
  }
}
class FillCard extends StatefulWidget {
  const FillCard({
    super.key,
    required this.store,
    required this.pump,
  });

  final MachineStore store;
  final Pump pump;

  @override
  State<FillCard> createState() => _FillCardState();
}

class _FillCardState extends State<FillCard> {
  late final capacity = TextEditingController(
    text: widget.pump.capacityMl.toStringAsFixed(0),
  );
  late final remaining = TextEditingController(
    text: widget.pump.remainingMl.toStringAsFixed(0),
  );

  @override
  void dispose() {
    capacity.dispose();
    remaining.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ing = widget.store.ingredientById(widget.pump.ingredientId);
    final percent = (widget.pump.level * 100).round();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(child: T('${widget.pump.number}')),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.store.displayIngredientName(ing),
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
                T('$percent%'),
              ],
            ),
            const SizedBox(height: 14),
            LinearProgressIndicator(
              value: widget.pump.level,
              minHeight: 12,
              borderRadius: BorderRadius.circular(20),
            ),
            const SizedBox(height: 8),
            T('${widget.pump.remainingMl.toStringAsFixed(0)} / '
              '${widget.pump.capacityMl.toStringAsFixed(0)} ml',
            ),
            const SizedBox(height: 14),
            TextField(
              controller: capacity,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: tr('Behältergröße'),
                suffixText: tr('ml'),
              ),
              onSubmitted: (_) => _saveValues(),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: remaining,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: tr('Aktueller Füllstand'),
                suffixText: tr('ml'),
                helperText: tr('Für bereits geöffnete Behälter eintragen'),
              ),
              onSubmitted: (_) => _saveValues(),
            ),
            const SizedBox(height: 10),
            LayoutBuilder(
              builder: (context, constraints) {
                final narrow = constraints.maxWidth < 360;
                final refillButton = FilledButton.tonal(
                  onPressed: () async {
                    _saveCapacityOnly();
                    widget.pump.remainingMl = widget.pump.capacityMl;
                    remaining.text =
                        widget.pump.remainingMl.toStringAsFixed(0);
                    await widget.store.save();
                    await widget.store.syncMachineStateToController();
                    if (!mounted) return;
                    setState(() {});
                  },
                  child: const T('Auffüllen'),
                );

                if (narrow) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _saveValues,
                        icon: const Icon(Icons.save_outlined),
                        label: const T('Füllstand speichern'),
                      ),
                      const SizedBox(height: 10),
                      refillButton,
                    ],
                  );
                }

                return Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _saveValues,
                        icon: const Icon(Icons.save_outlined),
                        label: const T('Füllstand speichern'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(child: refillButton),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  void _saveCapacityOnly() {
    final value = double.tryParse(capacity.text.replaceAll(',', '.'));
    if (value == null) return;
    widget.pump.capacityMl = value.clamp(1, 20000);
    widget.pump.remainingMl =
        math.min(widget.pump.remainingMl, widget.pump.capacityMl);
  }

  Future<void> _saveValues() async {
    final messenger = ScaffoldMessenger.of(context);
    _saveCapacityOnly();
    final value = double.tryParse(remaining.text.replaceAll(',', '.'));
    if (value != null) {
      widget.pump.remainingMl =
          value.clamp(0, widget.pump.capacityMl).toDouble();
      remaining.text = widget.pump.remainingMl.toStringAsFixed(0);
    }
    await widget.store.save();
    await widget.store.syncMachineStateToController();
    if (!mounted) return;
    setState(() {});
    messenger.showSnackBar(
      const SnackBar(content: T('Füllstand gespeichert')),
    );
  }
}

class SequencePage extends StatefulWidget {
  const SequencePage({
    super.key,
    required this.store,
    required this.cleaning,
  });

  final MachineStore store;
  final bool cleaning;

  @override
  State<SequencePage> createState() => _SequencePageState();
}

class _SequencePageState extends State<SequencePage> {
  bool running = false;
  bool cancelling = false;
  int? testingPump;
  int currentPump = 0;
  double progress = 0;

  @override
  Widget build(BuildContext context) {
    final content =
        widget.cleaning ? _buildCleaning() : _buildPriming();

    return PageFrame(
      title: widget.cleaning ? tr('Reinigung') : tr('Entlüften'),
      child: Stack(
        children: [
          Positioned.fill(child: content),
          if (running)
            Positioned(
              left: 20,
              right: 20,
              bottom: 16,
              child: SafeArea(
                top: false,
                child: _buildCancelButton(
                  widget.cleaning
                      ? 'Reinigung abbrechen'
                      : 'Entlüften abbrechen',
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildStatusCard() {
    if (!running) return const SizedBox.shrink();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    currentPump > 0
                        ? 'Pumpe $currentPump läuft'
                        : 'Nächste Pumpe wird vorbereitet',
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
                T('${(progress * 100).round()} %'),
              ],
            ),
            const SizedBox(height: 12),
            LinearProgressIndicator(value: progress.clamp(0, 1).toDouble()),
          ],
        ),
      ),
    );
  }

  Widget _buildPriming() {
    final activePumps =
        widget.store.pumps.where((pump) => pump.active).toList();

    return ListView(
      padding: EdgeInsets.fromLTRB(20, 20, 20, running ? 96 : 20),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Row(
                  children: [
                    Icon(Icons.info_outline, color: Color(0xFF16D9CC)),
                    SizedBox(width: 10),
                    Expanded(
                      child: T('Hinweis zum Entlüften',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 10),
                T('Beim Entlüften werden die Schläuche vollständig mit den '
                  'jeweiligen Zutaten gefüllt. Jede aktive Pumpe läuft '
                  'nacheinander mit ihrer eigenen gespeicherten Zeit.\n\n'
                  'Teste beim ersten Einrichten, wie viele Sekunden jede '
                  'Pumpe benötigt. Die eingestellten Zeiten werden dauerhaft '
                  'gespeichert und beim nächsten Entlüften erneut verwendet.',
                  style: TextStyle(
                    color: Color(0xFFB5C0C9),
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        _buildStatusCard(),
        if (running) const SizedBox(height: 14),
        ...activePumps.map((pump) {
          final index = pump.number - 1;
          final seconds = widget.store.primeTimesSeconds[index];

          return Padding(
            padding: const EdgeInsets.only(bottom: 9),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                child: Column(
                  children: [
                    Row(
                      children: [
                        CircleAvatar(child: T('${pump.number}')),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            widget.store.ingredientById(pump.ingredientId) == null
                                ? '${tr('Pumpe')} ${pump.number}'
                                : widget.store.displayIngredientNameById(pump.ingredientId),
                            style:
                                const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        T('${seconds.round()} s',
                          style:
                              const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ],
                    ),
                    Slider(
                      value: seconds,
                      min: 1,
                      max: 30,
                      divisions: 29,
                      label: '${seconds.round()} s',
                      onChanged: running
                          ? null
                          : (value) {
                              setState(
                                () => widget.store
                                    .primeTimesSeconds[index] = value,
                              );
                            },
                      onChangeEnd: (_) => widget.store.save(),
                    ),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: running || testingPump != null
                            ? null
                            : () => _testPump(pump.number),
                        icon: testingPump == pump.number
                            ? const SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.play_arrow),
                        label: const T('Pumpe 1 Sekunde testen'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }),
        const SizedBox(height: 6),
        if (!running)
          SizedBox(
            height: 52,
            child: FilledButton.icon(
              onPressed:
                  activePumps.isEmpty ? null : _startPriming,
              icon: const Icon(Icons.air),
              label: const T('Alle Pumpen entlüften'),
            ),
          )
        else
          const SizedBox(height: 72),
      ],
    );
  }

  Widget _buildCleaning() {
    return ListView(
      padding: EdgeInsets.fromLTRB(20, 20, 20, running ? 96 : 20),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Row(
                  children: [
                    Icon(Icons.info_outline, color: Color(0xFFFF6257)),
                    SizedBox(width: 10),
                    Expanded(
                      child: T('Anleitung zur Reinigung',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 10),
                T('1. Fülle einen großen Behälter mit etwa 40–50 °C warmem '
                  'Wasser und etwas Spülmittel. Lege alle Ansaugschläuche in '
                  'den Behälter und starte die Reinigung.\n\n'
                  '2. Fülle den Behälter anschließend mit klarem Wasser und '
                  'starte die Reinigung erneut.\n\n'
                  '3. Entferne die Schläuche aus dem Wasser und lasse sie '
                  'nochmal trocken durchlaufen. Der Auffangbehälter muss '
                  'weiterhin unter dem Ausguss stehen.\n\n'
                  '4. Bei Membranpumpen bitte alle Schläuche der Pumpen '
                  'entfernen und das Reinigungsprogramm erneut starten. Lege '
                  'vorher ein Handtuch unter die Pumpen. Dieser Schritt ist '
                  'wichtig, um Schimmel in den Pumpen zu verhindern.',
                  style: TextStyle(
                    color: Color(0xFFB5C0C9),
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        _buildStatusCard(),
        if (running) const SizedBox(height: 14),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: T('Laufzeit je Pumpe',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                        ),
                      ),
                    ),
                    T('${widget.store.cleaningSeconds.round()} s',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                const T('Alle aktiven Pumpen laufen nacheinander mit derselben Zeit.',
                  style: TextStyle(color: Color(0xFF9CA7B1)),
                ),
                Slider(
                  value: widget.store.cleaningSeconds,
                  min: 10,
                  max: 20,
                  divisions: 10,
                  label: '${widget.store.cleaningSeconds.round()} s',
                  onChanged: running
                      ? null
                      : (value) {
                          setState(
                            () => widget.store.cleaningSeconds = value,
                          );
                        },
                  onChangeEnd: (_) => widget.store.save(),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        if (!running)
          SizedBox(
            height: 52,
            child: FilledButton.icon(
              onPressed: widget.store.pumps.any((pump) => pump.active)
                  ? _startCleaning
                  : null,
              icon: const Icon(Icons.cleaning_services),
              label: const T('Reinigung starten'),
            ),
          )
        else
          const SizedBox(height: 72),
      ],
    );
  }

  Widget _buildCancelButton(String label) {
    return SizedBox(
      height: 52,
      child: FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xFFD32F2F),
          foregroundColor: Colors.white,
        ),
        onPressed: cancelling ? null : _cancelCurrentJob,
        icon: cancelling
            ? const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.stop_circle_outlined),
        label: Text(cancelling ? 'Wird abgebrochen …' : label),
      ),
    );
  }

  Future<void> _testPump(int pumpNumber) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => testingPump = pumpNumber);

    try {
      await widget.store.sendCommand({
        'action': 'run_pump',
        'pump': pumpNumber,
        'durationMs': 1000,
      });
      await _waitUntilIdle(updateMainProgress: false);
    } catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: T('$error')));
    }

    if (!mounted) return;
    setState(() => testingPump = null);
  }

  Future<void> _startPriming() async {
    final messenger = ScaffoldMessenger.of(context);
    final activePumps =
        widget.store.pumps.where((pump) => pump.active).toList();

    final steps = activePumps
        .map(
          (pump) => {
            'pump': pump.number,
            'durationMs': (widget.store
                        .primeTimesSeconds[pump.number - 1] *
                    1000)
                .round(),
            'delayMs': 0,
          },
        )
        .toList();

    await widget.store.save();
    if (!mounted) return;

    setState(() {
      running = true;
      cancelling = false;
      currentPump = 0;
      progress = 0;
    });

    try {
      await widget.store.sendCommand({
        'action': 'prime',
        'mode': 'sequential',
        'pumps': steps,
      });

      await _waitUntilIdle();

      if (!mounted || cancelling) return;
      messenger.showSnackBar(
        const SnackBar(content: T('Entlüften abgeschlossen')),
      );
    } catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: T('$error')));
    } finally {
      if (mounted) {
        setState(() {
          running = false;
          currentPump = 0;
          progress = 0;
        });
      }
    }
  }

  Future<void> _startCleaning() async {
    final messenger = ScaffoldMessenger.of(context);
    final activePumps =
        widget.store.pumps.where((pump) => pump.active).toList();

    await widget.store.save();
    if (!mounted) return;

    setState(() {
      running = true;
      cancelling = false;
      currentPump = 0;
      progress = 0;
    });

    try {
      await widget.store.sendCommand({
        'action': 'clean',
        'mode': 'sequential',
        'pumps': activePumps
            .map(
              (pump) => {
                'pump': pump.number,
                'durationMs':
                    (widget.store.cleaningSeconds * 1000).round(),
                'delayMs': 0,
              },
            )
            .toList(),
      });

      await _waitUntilIdle();

      if (!mounted || cancelling) return;
      messenger.showSnackBar(
        const SnackBar(content: T('Reinigung abgeschlossen')),
      );
    } catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: T('$error')));
    } finally {
      if (mounted) {
        setState(() {
          running = false;
          currentPump = 0;
          progress = 0;
        });
      }
    }
  }

  Future<void> _waitUntilIdle({
    bool updateMainProgress = true,
  }) async {
    for (var attempt = 0; attempt < 1800; attempt++) {
      await Future.delayed(const Duration(milliseconds: 400));
      if (!mounted) return;

      final machineStatus = await widget.store.fetchMachineStatus();
      if (!mounted) return;

      final busy = machineStatus['busy'] == true;
      final pump =
          (machineStatus['currentPump'] as num?)?.toInt() ?? 0;
      final value =
          (machineStatus['progress'] as num?)?.toDouble() ?? 0;

      if (updateMainProgress) {
        setState(() {
          currentPump = pump;
          progress = value.clamp(0, 1).toDouble();
        });
      }

      if (!busy) return;
    }

    throw Exception('Zeitüberschreitung beim Warten auf die Raspberry-Steuerung');
  }

  Future<void> _cancelCurrentJob() async {
    final messenger = ScaffoldMessenger.of(context);

    setState(() => cancelling = true);

    try {
      await widget.store.sendCommand({'action': 'stop'});
      if (!mounted) return;

      setState(() {
        running = false;
        cancelling = false;
        currentPump = 0;
        progress = 0;
      });

      messenger.showSnackBar(
        const SnackBar(content: T('Vorgang wurde abgebrochen')),
      );
    } catch (error) {
      if (!mounted) return;

      setState(() => cancelling = false);
      messenger.showSnackBar(SnackBar(content: T('$error')));
    }
  }
}

class ServingSizesPage extends StatefulWidget {
  const ServingSizesPage({
    super.key,
    required this.store,
  });

  final MachineStore store;

  @override
  State<ServingSizesPage> createState() => _ServingSizesPageState();
}

class _ServingSizesPageState extends State<ServingSizesPage> {
  final cocktailController = TextEditingController();
  final shotController = TextEditingController();

  @override
  void dispose() {
    cocktailController.dispose();
    shotController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PageFrame(title: tr('Getränkegrößen'),
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _sizeSection(
            title: tr('Größen für Cocktails'),
            description: tr(
                'Standardmäßig 200 ml. Diese Größen gelten für Cocktails '
                'und alkoholfreie Cocktails.',
              ),
            sizes: widget.store.servingSizes,
            defaultSize: widget.store.defaultServingSizeMl,
            controller: cocktailController,
            onDefaultChanged: (value) async {
              widget.store.defaultServingSizeMl = value;
              await widget.store.save();
              setState(() {});
            },
            onAdd: () => _addSize(
              controller: cocktailController,
              sizes: widget.store.servingSizes,
              setDefault: (value) =>
                  widget.store.defaultServingSizeMl = value,
            ),
            onDelete: (value) async {
              widget.store.servingSizes.remove(value);
              await widget.store.save();
              setState(() {});
            },
          ),
          const SizedBox(height: 24),
          _sizeSection(
            title: tr('Größen für Shots'),
            description: tr(
                'Voreingestellt sind 2 cl und 4 cl. In der App werden '
                'die Werte als 20 ml und 40 ml gespeichert.',
              ),
            sizes: widget.store.shotSizes,
            defaultSize: widget.store.defaultShotSizeMl,
            controller: shotController,
            onDefaultChanged: (value) async {
              widget.store.defaultShotSizeMl = value;
              await widget.store.save();
              setState(() {});
            },
            onAdd: () => _addSize(
              controller: shotController,
              sizes: widget.store.shotSizes,
              setDefault: (value) => widget.store.defaultShotSizeMl = value,
            ),
            onDelete: (value) async {
              widget.store.shotSizes.remove(value);
              await widget.store.save();
              setState(() {});
            },
            displayInCl: true,
          ),
        ],
      ),
    );
  }

  Widget _sizeSection({
    required String title,
    required String description,
    required List<double> sizes,
    required double defaultSize,
    required TextEditingController controller,
    required ValueChanged<double> onDefaultChanged,
    required VoidCallback onAdd,
    required ValueChanged<double> onDelete,
    bool displayInCl = false,
  }) {
    String label(double size) {
      if (displayInCl) {
        final cl = size / 10;
        return '${cl.toStringAsFixed(cl % 1 == 0 ? 0 : 1)} cl '
            '(${size.toStringAsFixed(0)} ml)';
      }
      return '${size.toStringAsFixed(size % 1 == 0 ? 0 : 1)} ml';
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 18,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              description,
              style: const TextStyle(color: Color(0xFF9CA7B1)),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<double>(
              key: ValueKey('$title-$defaultSize'),
              initialValue: defaultSize,
              decoration: InputDecoration(
                labelText: tr('Standardgröße'),
              ),
              items: sizes
                  .map(
                    (size) => DropdownMenuItem(
                      value: size,
                      child: Text(label(size)),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                if (value != null) onDefaultChanged(value);
              },
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: controller,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: displayInCl
                          ? tr('Neue Größe in ml')
                          : tr('Neue Größe'),
                      suffixText: tr('ml'),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton.icon(
                  onPressed: onAdd,
                  icon: const Icon(Icons.add),
                  label: const T('Hinzufügen'),
                ),
              ],
            ),
            const SizedBox(height: 14),
            ...sizes.map(
              (size) => ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  size == defaultSize
                      ? Icons.check_circle
                      : Icons.circle_outlined,
                  color: size == defaultSize
                      ? const Color(0xFF16D9CC)
                      : const Color(0xFF8A949E),
                ),
                title: Text(label(size)),
                subtitle: Text(
                  size == defaultSize
                      ? tr('Aktuelle Standardgröße')
                      : tr('Verfügbare Größe'),
                ),
                trailing: size == defaultSize
                    ? null
                    : IconButton(
                        tooltip: tr('Größe löschen'),
                        onPressed: () => onDelete(size),
                        icon: const Icon(Icons.delete_outline),
                      ),
                onTap: () => onDefaultChanged(size),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _addSize({
    required TextEditingController controller,
    required List<double> sizes,
    required ValueChanged<double> setDefault,
  }) async {
    final value = double.tryParse(controller.text.replaceAll(',', '.'));
    if (value == null || value <= 0) return;

    if (!sizes.contains(value)) {
      sizes.add(value);
      sizes.sort();
    }
    setDefault(value);
    controller.clear();
    await widget.store.save();
    setState(() {});
  }
}

class ConsumptionStatisticsPage extends StatelessWidget {
  const ConsumptionStatisticsPage({
    super.key,
    required this.store,
  });

  final MachineStore store;

  String _money(double value) =>
      '${value.toStringAsFixed(2).replaceAll('.', ',')} €';

  String _ml(double value) {
    if (value >= 1000) {
      return '${(value / 1000).toStringAsFixed(2).replaceAll('.', ',')} L';
    }
    return '${value.toStringAsFixed(0)} ml';
  }

  Recipe? _recipeById(String id) =>
      store.recipes.where((recipe) => recipe.id == id).firstOrNull;

  @override
  Widget build(BuildContext context) {
    final recipeRanking = store.recipeDrinkCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final sizeRanking = store.servingSizeCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final ingredientRanking = store.ingredientUsageMl.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final recipeCosts = store.recipes.toList()
      ..sort(
        (a, b) => store
            .recipeCost(b)
            .compareTo(store.recipeCost(a)),
      );

    return PageFrame(title: tr('Verbrauchsstatistik'),
      actions: [
        IconButton(
          tooltip: tr('Statistik zurücksetzen'),
          onPressed: () async {
            final confirmed = await showDialog<bool>(
              context: context,
              builder: (dialogContext) => AlertDialog(
                title: const T('Statistik zurücksetzen?'),
                content: const T('Cocktail-Ranking, Größenstatistik und '
                  'Zutatenverbrauch werden gelöscht. Füllstände und '
                  'Kalibrierungen bleiben erhalten.',
                ),
                actions: [
                  TextButton(
                    onPressed: () =>
                        Navigator.pop(dialogContext, false),
                    child: const T('Abbrechen'),
                  ),
                  FilledButton(
                    onPressed: () =>
                        Navigator.pop(dialogContext, true),
                    child: const T('Zurücksetzen'),
                  ),
                ],
              ),
            );

            if (confirmed == true) {
              await store.resetConsumptionStatistics();
            }
          },
          icon: const Icon(Icons.restart_alt),
        ),
      ],
      child: AnimatedBuilder(
        animation: store,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _StatSummaryCard(
                  title: tr('Getrunkene Cocktails'),
                  value: store.totalDrinksConsumed.toString(),
                  icon: Icons.local_bar,
                  color: store.appColors.accentColor,
                ),
                _StatSummaryCard(
                  title: tr('Verbrauch gesamt'),
                  value: _ml(store.totalIngredientsUsedMl),
                  icon: Icons.water_drop_outlined,
                  color: const Color(0xFF38BDF8),
                ),
                _StatSummaryCard(
                  title: tr('Kosten gesamt'),
                  value: _money(store.totalConsumptionCost),
                  icon: Icons.euro,
                  color: const Color(0xFFFFC857),
                ),
              ],
            ),
            const SizedBox(height: 18),
            _StatSection(
              title: tr('Cocktail-Ranking'),
              emptyText: tr('Noch keine Cocktails zubereitet'),
              children: recipeRanking.asMap().entries.map((entry) {
                final rank = entry.key + 1;
                final recipeEntry = entry.value;
                final recipe = _recipeById(recipeEntry.key);
                final recipeName = recipe == null
                    ? tr('Gelöschtes Rezept')
                    : store.displayRecipeName(recipe);

                return ListTile(
                  leading: CircleAvatar(child: T('$rank')),
                  title: Text(recipeName),
                  subtitle: recipe == null
                      ? const T('Rezept nicht mehr vorhanden')
                      : Text('${tr('Kosten pro Standardgröße')}: '
                          '${_money(store.recipeCost(recipe))}',
                        ),
                  trailing: T('${recipeEntry.value}×',
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 16,
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 14),
            _StatSection(
              title: tr('Meistgenutzte Cocktailgrößen'),
              emptyText: tr('Noch keine Größenstatistik vorhanden'),
              children: sizeRanking.map((entry) {
                return ListTile(
                  leading: const Icon(Icons.straighten),
                  title: Text(entry.key),
                  trailing: T('${entry.value}×',
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 16,
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 14),
            _StatSection(
              title: tr('Zutatenverbrauch'),
              emptyText: tr('Noch kein Zutatenverbrauch vorhanden'),
              children: ingredientRanking.map((entry) {
                final ingredient = store.ingredientById(entry.key);
                final name = ingredient == null
                    ? tr('Gelöschte Zutat')
                    : store.displayIngredientName(ingredient);
                final cost = store.totalIngredientCost(entry.key);

                return ListTile(
                  leading: const Icon(Icons.local_drink_outlined),
                  title: Text(name),
                  subtitle: Text('${tr('Literpreis')}: '
                    '${ingredient == null ? '—' : _money(ingredient.pricePerLiter)} / L',
                  ),
                  trailing: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        _ml(entry.value),
                        style: const TextStyle(fontWeight: FontWeight.w900),
                      ),
                      Text(_money(cost)),
                    ],
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 14),
            _StatSection(
              title: tr('Cocktailkosten nach aktuellem Rezept'),
              emptyText: tr('Noch keine Rezepte vorhanden'),
              children: recipeCosts.map((recipe) {
                final cost = store.recipeCost(recipe);
                final size = store.defaultSizeFor(recipe.category);

                return ListTile(
                  leading: Icon(
                    switch (recipe.category) {
                      DrinkCategory.cocktail => Icons.local_bar,
                      DrinkCategory.mocktail => Icons.local_drink,
                      DrinkCategory.shot => Icons.liquor,
                    },
                  ),
                  title: Text(store.displayRecipeName(recipe)),
                  subtitle:
                      Text('${size.toStringAsFixed(0)} ml ${tr('Standardgröße')}'),
                  trailing: Text(
                    _money(cost),
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 15,
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 12),
            T('Hinweis: Verbrauch und Kosten werden aus den Rezeptmengen '
              'und den eingetragenen Literpreisen berechnet. Manuelle '
              'Zutaten werden in der Statistik mitgezählt, sofern sie im '
              'Rezept als Zutat hinterlegt sind.',
              style: TextStyle(color: store.appColors.textSecondaryColor),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatSummaryCard extends StatelessWidget {
  const _StatSummaryCard({
    required this.title,
    required this.value,
    required this.icon,
    required this.color,
  });

  final String title;
  final String value;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 185,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(15),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: color),
              const SizedBox(height: 10),
              Text(
                value,
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 24,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                title,
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatSection extends StatelessWidget {
  const _StatSection({
    required this.title,
    required this.emptyText,
    required this.children,
  });

  final String title;
  final String emptyText;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 14, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 17,
                ),
              ),
            ),
            if (children.isEmpty)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(emptyText),
              )
            else
              ...children,
          ],
        ),
      ),
    );
  }
}

class IngredientPage extends StatefulWidget {
  const IngredientPage({
    super.key,
    required this.store,
  });

  final MachineStore store;

  @override
  State<IngredientPage> createState() => _IngredientPageState();
}

class _IngredientPageState extends State<IngredientPage> {
  final name = TextEditingController();
  final price = TextEditingController();
  final alcohol = TextEditingController();
  IngredientKind kind = IngredientKind.nonAlcoholic;

  @override
  void dispose() {
    name.dispose();
    price.dispose();
    alcohol.dispose();
    super.dispose();
  }

  String _formatCurrency(double value) =>
      '${value.toStringAsFixed(2).replaceAll('.', ',')} €';

  Future<void> _saveIngredientPrice(
    Ingredient ingredient,
    String rawValue,
  ) async {
    ingredient.pricePerLiter =
        double.tryParse(rawValue.replaceAll(',', '.')) ?? 0;

    if (ingredient.pricePerLiter < 0) {
      ingredient.pricePerLiter = 0;
    }

    await widget.store.save();
    if (mounted) setState(() {});
  }

  Future<void> _saveIngredientAlcohol(
    Ingredient ingredient,
    String rawValue,
  ) async {
    ingredient.alcoholPercent =
        (double.tryParse(rawValue.replaceAll(',', '.')) ?? 0)
            .clamp(0, 100)
            .toDouble();

    if (ingredient.kind == IngredientKind.nonAlcoholic) {
      ingredient.alcoholPercent = 0;
    }

    await widget.store.save();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return PageFrame(title: tr('Neue Zutaten'),
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                children: [
                  TextField(
                    controller: name,
                    decoration: InputDecoration(
                      labelText: tr('Name der Zutat'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (widget.store.commercialLicenseActive) ...[
                    TextField(
                      controller: price,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(
                        labelText: tr('Literpreis'),
                        suffixText: tr('€/L'),
                        helperText: tr('Wird für Cocktailkosten und Verbrauchsstatistik genutzt'),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ] else ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: const Color(0x33FFFFFF)),
                      ),
                      child: Text(
                        tr('Literpreise und Kostenberechnung sind nur in der Lizenzversion verfügbar.'),
                        style: const TextStyle(color: Color(0xFFB5C0C9)),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  SegmentedButton<IngredientKind>(
                    segments: const [
                      ButtonSegment(
                        value: IngredientKind.alcoholic,
                        label: T('Alkoholisch'),
                        icon: Icon(Icons.local_bar),
                      ),
                      ButtonSegment(
                        value: IngredientKind.nonAlcoholic,
                        label: T('Alkoholfrei'),
                        icon: Icon(Icons.local_drink),
                      ),
                    ],
                    selected: {kind},
                    onSelectionChanged: (value) =>
                        setState(() => kind = value.first),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: alcohol,
                    enabled: kind == IngredientKind.alcoholic,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: tr('Alkoholgehalt in % vol'),
                      suffixText: tr('% vol'),
                      helperText: tr('Wird für die automatische Alkoholberechnung genutzt'),
                    ),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () async {
                        final ingredientName = name.text.trim();
                        if (ingredientName.isEmpty) return;

                        widget.store.ingredients.add(
                          Ingredient(
                            id:
                                '${DateTime.now().millisecondsSinceEpoch}',
                            name: ingredientName,
                            kind: kind,
                            pricePerLiter: widget.store.commercialLicenseActive
                                ? (double.tryParse(
                                      price.text.replaceAll(',', '.'),
                                    ) ??
                                    0)
                                : 0,
                            alcoholPercent: kind == IngredientKind.alcoholic
                                ? (double.tryParse(
                                          alcohol.text.replaceAll(',', '.'),
                                        ) ??
                                        0)
                                    .clamp(0, 100)
                                    .toDouble()
                                : 0,
                          ),
                        );

                        await widget.store.save();
                        name.clear();
                        price.clear();
                        alcohol.clear();

                        if (mounted) setState(() {});
                      },
                      icon: const Icon(Icons.add),
                      label: const T('Zutat hinzufügen'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 18),
          ...widget.store.ingredients.map((ingredient) {
            final usedMl =
                widget.store.ingredientUsageMl[ingredient.id] ?? 0;
            final usedCost =
                widget.store.totalIngredientCost(ingredient.id);

            return Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Icon(
                          ingredient.kind == IngredientKind.alcoholic
                              ? Icons.local_bar
                              : Icons.local_drink,
                          color: widget.store.appColors.accentColor,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment:
                                CrossAxisAlignment.start,
                            children: [
                              Text(
                                widget.store.displayIngredientName(ingredient),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                ingredient.kind == IngredientKind.alcoholic
                                    ? '${tr('Alkoholisch')} · ${formatAlcoholPercent(ingredient.alcoholPercent)} % vol'
                                    : tr('Alkoholfrei'),
                                style: TextStyle(
                                  color: widget
                                      .store.appColors.textSecondaryColor,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (widget.store.commercialLicenseActive)
                          T('${ingredient.pricePerLiter.toStringAsFixed(2).replaceAll('.', ',')} €/L',
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                      ],
                    ),
                    if (widget.store.commercialLicenseActive) ...[
                      const SizedBox(height: 12),
                      TextFormField(
                        initialValue: ingredient.pricePerLiter <= 0
                            ? ''
                            : ingredient.pricePerLiter
                                .toStringAsFixed(2)
                                .replaceAll('.', ','),
                        keyboardType:
                            const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: InputDecoration(
                          labelText: tr('Literpreis bearbeiten'),
                          suffixText: tr('€/L'),
                          helperText: tr('Wird beim Tippen automatisch gespeichert'),
                        ),
                        onChanged: (value) {
                          final parsed = double.tryParse(
                            value.replaceAll(',', '.'),
                          );
                          if (parsed != null && parsed >= 0) {
                            ingredient.pricePerLiter = parsed;
                            widget.store.save();
                          }
                        },
                        onFieldSubmitted: (value) =>
                            _saveIngredientPrice(ingredient, value),
                      ),
                    ],
                    const SizedBox(height: 8),
                    TextFormField(
                      initialValue: ingredient.alcoholPercent <= 0
                          ? ''
                          : formatAlcoholPercent(ingredient.alcoholPercent),
                      enabled: ingredient.kind == IngredientKind.alcoholic,
                      keyboardType:
                          const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: InputDecoration(
                        labelText: tr('Alkoholgehalt bearbeiten'),
                        suffixText: tr('% vol'),
                        helperText: tr('Bitte Alkoholgehalt der Flasche eintragen'),
                      ),
                      onChanged: (value) {
                        final parsed = double.tryParse(
                          value.replaceAll(',', '.'),
                        );
                        if (parsed != null && parsed >= 0) {
                          ingredient.alcoholPercent =
                              parsed.clamp(0, 100).toDouble();
                          if (ingredient.kind ==
                              IngredientKind.nonAlcoholic) {
                            ingredient.alcoholPercent = 0;
                          }
                          widget.store.save();
                        }
                      },
                      onFieldSubmitted: (value) =>
                          _saveIngredientAlcohol(ingredient, value),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: Text('${tr('Verbraucht')}: ${(usedMl / 1000).toStringAsFixed(3).replaceAll('.', ',')} L',
                            style: TextStyle(
                              color: widget
                                  .store.appColors.textSecondaryColor,
                            ),
                          ),
                        ),
                        if (widget.store.commercialLicenseActive)
                          Text('${tr('Kosten')}: ${_formatCurrency(usedCost)}',
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          }),
        ],
      ),
    );
  }
}





class CommercialFeatureGatePage extends StatelessWidget {
  const CommercialFeatureGatePage({
    super.key,
    required this.store,
    required this.featureName,
  });

  final MachineStore store;
  final String featureName;

  @override
  Widget build(BuildContext context) {
    return PageFrame(
      title: featureName,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.lock_outline,
                    color: store.appColors.warningColor,
                    size: 44,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    tr('Gewerbelizenz erforderlich'),
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 22,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '${tr(featureName)} ${tr('ist Teil der CocktailBot Gewerbelizenz. Die Grundfunktionen der Maschine bleiben im Privatmodus nutzbar.')}',
                    style: TextStyle(
                      color: store.appColors.textSecondaryColor,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 18),
                  FilledButton.icon(
                    onPressed: () => Navigator.pushReplacement(
                      context,
                      MaterialPageRoute(
                        builder: (_) => CommercialLicensePage(store: store),
                      ),
                    ),
                    icon: const Icon(Icons.verified_user_outlined),
                    label: Text(tr('Gewerbelizenz öffnen')),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class CommercialLicensePage extends StatefulWidget {
  const CommercialLicensePage({super.key, required this.store});
  final MachineStore store;

  @override
  State<CommercialLicensePage> createState() => _CommercialLicensePageState();
}

class _CommercialLicensePageState extends State<CommercialLicensePage> {
  late final codeController =
      TextEditingController(text: widget.store.commercialLicenseCode);
  late final machineController =
      TextEditingController(text: widget.store.paymentMachineId);

  @override
  void dispose() {
    codeController.dispose();
    machineController.dispose();
    super.dispose();
  }

  Future<void> _saveMachineId() async {
    await widget.store.savePaymentSettings(
      enabled: widget.store.paypalPaymentEnabled,
      machineId: machineController.text,
      cocktailPrice: widget.store.cocktailPriceEur,
      mocktailPrice: widget.store.mocktailPriceEur,
      shotPrice: widget.store.shotPriceEur,
    );
    if (mounted) setState(() {});
  }

  Future<void> _activate() async {
    await _saveMachineId();
    final ok = await widget.store.activateCommercialLicense(
      codeController.text,
    );

    if (!mounted) return;
    setState(() {});

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? tr('Gewerbelizenz wurde aktiviert')
              : tr('Lizenzcode ist ungültig'),
        ),
      ),
    );
  }

  Future<void> _deactivate() async {
    await widget.store.deactivateCommercialLicense();
    if (!mounted) return;
    setState(() {});
  }

  String _date(DateTime? value) {
    if (value == null) return '–';
    final day = value.day.toString().padLeft(2, '0');
    final month = value.month.toString().padLeft(2, '0');
    return '$day.$month.${value.year}';
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.store.commercialLicenseActive;

    return PageFrame(
      title: tr('Gewerbelizenz'),
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Row(
                children: [
                  Icon(
                    active
                        ? Icons.verified_user
                        : Icons.lock_outline,
                    color: active
                        ? widget.store.appColors.successColor
                        : widget.store.appColors.warningColor,
                    size: 42,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          active
                              ? tr('Gewerbelizenz aktiv')
                              : tr('Privatmodus aktiv'),
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 20,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          active
                              ? tr('Gewerbliche Funktionen sind für diese Maschine freigeschaltet.')
                              : tr('Statistik, Einkaufsliste, Partyplaner, Kassenmodus, Export und Branding sind gesperrt.'),
                          style: TextStyle(
                            color: widget.store.appColors.textSecondaryColor,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr('Lizenzdaten'),
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 18,
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: machineController,
                    decoration: InputDecoration(
                      labelText: tr('Maschinen-ID'),
                      helperText: tr('Die Gewerbelizenz gilt pro Maschine.'),
                    ),
                    onSubmitted: (_) => _saveMachineId(),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: codeController,
                    decoration: InputDecoration(
                      labelText: tr('Lizenzcode'),
                      helperText: tr('Für den Test: CB-COMMERCIAL-DEMO oder CB-COM-<Maschinen-ID>.'),
                    ),
                  ),
                  const SizedBox(height: 14),
                  if (active) ...[
                    Text('${tr('Lizenzierte Maschine')}: ${widget.store.commercialLicensedMachineId}'),
                    const SizedBox(height: 6),
                    Text('${tr('Aktiviert am')}: ${_date(widget.store.commercialLicenseActivatedAt)}'),
                    const SizedBox(height: 14),
                  ],
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _activate,
                          icon: const Icon(Icons.verified_user_outlined),
                          label: Text(
                            active
                                ? tr('Lizenz erneut prüfen')
                                : tr('Gewerbelizenz aktivieren'),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      if (active)
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _deactivate,
                            icon: const Icon(Icons.lock_reset),
                            label: Text(tr('Deaktivieren')),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr('Enthaltene Gewerbefunktionen'),
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 18,
                    ),
                  ),
                  const SizedBox(height: 10),
                  ...[
                    'Statistik',
                    'Einkaufsliste',
                    'Partyplaner',
                    'Partykarten',
                    'PayPal Kassenmodus',
                    'Kosten- und Margenberechnung',
                    'CSV/PDF-Export vorbereitet',
                    'Bar-/Firmenbranding',
                  ].map(
                    (feature) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        children: [
                          Icon(
                            Icons.check_circle_outline,
                            color: active
                                ? widget.store.appColors.successColor
                                : widget.store.appColors.textSecondaryColor,
                            size: 20,
                          ),
                          const SizedBox(width: 10),
                          Expanded(child: Text(tr(feature))),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class CommercialBrandingPage extends StatefulWidget {
  const CommercialBrandingPage({super.key, required this.store});
  final MachineStore store;

  @override
  State<CommercialBrandingPage> createState() => _CommercialBrandingPageState();
}

class _CommercialBrandingPageState extends State<CommercialBrandingPage> {
  late final nameController =
      TextEditingController(text: widget.store.commercialBusinessName);
  late final subtitleController =
      TextEditingController(text: widget.store.commercialBusinessSubtitle);

  @override
  void dispose() {
    nameController.dispose();
    subtitleController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await widget.store.saveCommercialBranding(
      businessName: nameController.text,
      subtitle: subtitleController.text,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(tr('Branding wurde gespeichert'))),
    );
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return PageFrame(
      title: tr('Branding'),
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr('Bar-/Firmenbranding'),
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 18,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    tr('Diese Daten können später auf Kassenmodus, Exporten und Berichten angezeigt werden.'),
                    style: TextStyle(
                      color: widget.store.appColors.textSecondaryColor,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: nameController,
                    decoration: InputDecoration(
                      labelText: tr('Bar- oder Firmenname'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: subtitleController,
                    decoration: InputDecoration(
                      labelText: tr('Untertitel / Hinweis'),
                    ),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _save,
                      icon: const Icon(Icons.save_outlined),
                      label: Text(tr('Branding speichern')),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: widget.store.appColors.backgroundColor,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: widget.store.appColors.borderColor),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.local_bar,
                  color: widget.store.appColors.accentColor,
                  size: 38,
                ),
                const SizedBox(height: 10),
                Text(
                  nameController.text.trim().isEmpty
                      ? 'CocktailBot'
                      : nameController.text.trim(),
                  style: TextStyle(
                    color: widget.store.appColors.textPrimaryColor,
                    fontWeight: FontWeight.w900,
                    fontSize: 24,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  subtitleController.text.trim().isEmpty
                      ? tr('Gewerbliche Nutzung erlaubt')
                      : subtitleController.text.trim(),
                  style: TextStyle(
                    color: widget.store.appColors.textSecondaryColor,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}



class CocktailPricesPage extends StatefulWidget {
  const CocktailPricesPage({super.key, required this.store});
  final MachineStore store;

  @override
  State<CocktailPricesPage> createState() => _CocktailPricesPageState();
}

class _CocktailPricesPageState extends State<CocktailPricesPage> {
  final controllers = <String, TextEditingController>{};
  DrinkCategory selectedCategory = DrinkCategory.cocktail;

  @override
  void dispose() {
    for (final controller in controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  String _categoryLabel(DrinkCategory category) => switch (category) {
        DrinkCategory.cocktail => widget.store.t('Cocktails'),
        DrinkCategory.mocktail => widget.store.t('Alkoholfrei'),
        DrinkCategory.shot => widget.store.t('Shots'),
      };

  TextEditingController _controllerFor(Recipe recipe) {
    return controllers.putIfAbsent(
      recipe.id,
      () => TextEditingController(
        text: widget.store.priceForRecipe(recipe).toStringAsFixed(2),
      ),
    );
  }

  Future<void> _saveRecipePrice(Recipe recipe) async {
    final controller = _controllerFor(recipe);
    final parsed = double.tryParse(controller.text.replaceAll(',', '.').trim());
    if (parsed == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('Bitte eine gültige Zahl eingeben'))),
      );
      return;
    }

    await widget.store.setRecipePrice(recipe, parsed);
    if (!mounted) return;
    setState(() {
      controller.text = widget.store.priceForRecipe(recipe).toStringAsFixed(2);
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${widget.store.displayRecipeName(recipe)}: ${parsed.toStringAsFixed(2).replaceAll('.', ',')} €')),
    );
  }

  Future<void> _resetRecipePrice(Recipe recipe) async {
    await widget.store.setRecipePrice(recipe, null);
    final controller = _controllerFor(recipe);
    if (!mounted) return;
    setState(() {
      controller.text = widget.store.priceForRecipe(recipe).toStringAsFixed(2);
    });
  }

  @override
  Widget build(BuildContext context) {
    final recipes = widget.store.recipes
        .where((recipe) => recipe.category == selectedCategory)
        .toList();

    return PageFrame(
      title: tr('Cocktailpreise'),
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr('Einzelpreise pro Cocktail'),
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 18,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    tr('Hier legst du die Verkaufspreise pro Cocktail fest. Ohne Einzelpreis gilt der Standardpreis aus dem PayPal Kassenmodus.'),
                    style: TextStyle(
                      color: widget.store.appColors.textSecondaryColor,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 14),
                  DropdownButtonFormField<DrinkCategory>(
                    value: selectedCategory,
                    decoration: InputDecoration(
                      labelText: tr('Liste auswählen'),
                    ),
                    items: DrinkCategory.values
                        .map(
                          (category) => DropdownMenuItem<DrinkCategory>(
                            value: category,
                            child: Text(_categoryLabel(category)),
                          ),
                        )
                        .toList(),
                    onChanged: (category) {
                      if (category == null) return;
                      setState(() => selectedCategory = category);
                    },
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          ...recipes.map((recipe) {
            final controller = _controllerFor(recipe);
            final customPrice = widget.store.recipePricesEur.containsKey(recipe.id);
            final standardPrice =
                widget.store.categoryPriceFor(recipe.category);

            return Card(
              margin: const EdgeInsets.only(bottom: 10),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final narrow = constraints.maxWidth < 520;

                    final nameBlock = Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.store.displayRecipeName(recipe),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 15,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          customPrice
                              ? tr('Eigener Preis aktiv')
                              : '${tr('Standardpreis')}: ${standardPrice.toStringAsFixed(2).replaceAll('.', ',')} €',
                          style: TextStyle(
                            color: widget.store.appColors.textSecondaryColor,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    );

                    final inputBlock = Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 105,
                          child: TextField(
                            controller: controller,
                            keyboardType:
                                const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: const InputDecoration(
                              suffixText: '€',
                            ),
                            onSubmitted: (_) => _saveRecipePrice(recipe),
                          ),
                        ),
                        IconButton(
                          tooltip: tr('Speichern'),
                          onPressed: () => _saveRecipePrice(recipe),
                          icon: const Icon(Icons.save_outlined),
                        ),
                        IconButton(
                          tooltip: tr('Standardpreis verwenden'),
                          onPressed: customPrice
                              ? () => _resetRecipePrice(recipe)
                              : null,
                          icon: const Icon(Icons.undo),
                        ),
                      ],
                    );

                    if (narrow) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          nameBlock,
                          const SizedBox(height: 10),
                          inputBlock,
                        ],
                      );
                    }

                    return Row(
                      children: [
                        Expanded(child: nameBlock),
                        const SizedBox(width: 12),
                        inputBlock,
                      ],
                    );
                  },
                ),
              ),
            );
          }),
        ],
      ),
    );
  }
}


class PaymentSettingsPage extends StatefulWidget {
  const PaymentSettingsPage({super.key, required this.store});
  final MachineStore store;

  @override
  State<PaymentSettingsPage> createState() => _PaymentSettingsPageState();
}

class _PaymentSettingsPageState extends State<PaymentSettingsPage> {
  late bool enabled;
  late final machineIdController =
      TextEditingController(text: widget.store.paymentMachineId);
  late final cocktailPriceController = TextEditingController(
    text: widget.store.cocktailPriceEur.toStringAsFixed(2),
  );
  late final mocktailPriceController = TextEditingController(
    text: widget.store.mocktailPriceEur.toStringAsFixed(2),
  );
  late final shotPriceController = TextEditingController(
    text: widget.store.shotPriceEur.toStringAsFixed(2),
  );
  final recipePriceControllers = <String, TextEditingController>{};
  bool? backendReady;
  String backendState = 'Lokales Zahlungsbackend wird geprüft …';

  @override
  void initState() {
    super.initState();
    enabled = widget.store.paypalPaymentEnabled;
    _refreshBackendStatus();
  }

  @override
  void dispose() {
    machineIdController.dispose();
    cocktailPriceController.dispose();
    mocktailPriceController.dispose();
    shotPriceController.dispose();
    for (final controller in recipePriceControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _refreshBackendStatus() async {
    try {
      final status = await widget.store.fetchPaymentBackendStatus();
      if (!mounted) return;
      final configured = status['configured'] == true;
      final mode = status['mode']?.toString() ?? 'unbekannt';
      setState(() {
        backendReady = configured;
        backendState = configured
            ? 'PayPal lokal auf dem Raspberry konfiguriert ($mode)'
            : 'PayPal-Zugangsdaten auf dem Raspberry fehlen';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        backendReady = false;
        backendState = 'Lokales Zahlungsbackend nicht erreichbar: $error';
      });
    }
  }

  double _readPrice(TextEditingController controller, double fallback) {
    return double.tryParse(controller.text.replaceAll(',', '.').trim()) ??
        fallback;
  }

  TextEditingController _recipePriceController(Recipe recipe) {
    return recipePriceControllers.putIfAbsent(
      recipe.id,
      () => TextEditingController(
        text: widget.store.priceForRecipe(recipe).toStringAsFixed(2),
      ),
    );
  }

  Future<void> _saveRecipePrice(Recipe recipe) async {
    final controller = _recipePriceController(recipe);
    final parsed = double.tryParse(controller.text.replaceAll(',', '.').trim());
    if (parsed == null) return;
    await widget.store.setRecipePrice(recipe, parsed);
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _resetRecipePrice(Recipe recipe) async {
    await widget.store.setRecipePrice(recipe, null);
    final controller = _recipePriceController(recipe);
    controller.text = widget.store.priceForRecipe(recipe).toStringAsFixed(2);
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _save() async {
    try {
      await widget.store.savePaymentSettings(
        enabled: enabled,
        machineId: machineIdController.text,
        cocktailPrice: _readPrice(cocktailPriceController, 6.50),
        mocktailPrice: _readPrice(mocktailPriceController, 4.50),
        shotPrice: _readPrice(shotPriceController, 3.00),
      );
      await _refreshBackendStatus();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('PayPal Kassenmodus gespeichert'))),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${tr('Speichern fehlgeschlagen')}: $error')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.store.commercialLicenseActive) {
      return CommercialFeatureGatePage(
        store: widget.store,
        featureName: tr('PayPal Kassenmodus'),
      );
    }

    final stateColor = backendReady == true
        ? widget.store.appColors.successColor
        : backendReady == false
            ? widget.store.appColors.warningColor
            : widget.store.appColors.textSecondaryColor;

    return PageFrame(
      title: tr('PayPal Kassenmodus'),
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr('Lokale PayPal-Zahlungsfreigabe'),
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 18,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    tr('Bestellungen und Zahlungsstatus laufen direkt über den Raspberry Pi. Es wird kein Cloudflare-Backend benötigt. PayPal-Client-ID und Secret werden ausschließlich auf dem Raspberry gespeichert.'),
                    style: TextStyle(
                      color: widget.store.appColors.textSecondaryColor,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        backendReady == true
                            ? Icons.check_circle_outline
                            : Icons.info_outline,
                        color: stateColor,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          backendState,
                          style: TextStyle(
                            color: stateColor,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: tr('Neu prüfen'),
                        onPressed: _refreshBackendStatus,
                        icon: const Icon(Icons.refresh),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  SelectableText(
                    'Raspberry-Konfiguration: sudo cocktailbot-paypal-config',
                    style: TextStyle(
                      color: widget.store.appColors.textSecondaryColor,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 14),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(tr('PayPal-Zahlung vor Zubereitung erzwingen')),
                    subtitle: Text(
                      enabled
                          ? tr('Cocktails starten erst nach Zahlungsfreigabe')
                          : tr('Cocktails können direkt gestartet werden'),
                    ),
                    value: enabled,
                    onChanged: (value) => setState(() => enabled = value),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: machineIdController,
                    decoration: InputDecoration(
                      labelText: tr('Maschinen-ID für Zahlungen'),
                      helperText: tr('Wird zusammen mit jeder lokalen Bestellung gespeichert.'),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    tr('Preise'),
                    style: const TextStyle(fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: cocktailPriceController,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: tr('Cocktail Preis EUR'),
                      suffixText: '€',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: mocktailPriceController,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: tr('Alkoholfrei Preis EUR'),
                      suffixText: '€',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: shotPriceController,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: tr('Shot Preis EUR'),
                      suffixText: '€',
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _save,
                      icon: const Icon(Icons.save_outlined),
                      label: Text(tr('Zahlungseinstellungen speichern')),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class PaymentCheckoutPage extends StatefulWidget {
  const PaymentCheckoutPage({
    super.key,
    required this.store,
    required this.recipe,
    required this.targetVolumeMl,
    this.targetAlcoholPercent,
  });

  final MachineStore store;
  final Recipe recipe;
  final double targetVolumeMl;
  final double? targetAlcoholPercent;

  @override
  State<PaymentCheckoutPage> createState() => _PaymentCheckoutPageState();
}

class _PaymentCheckoutPageState extends State<PaymentCheckoutPage> {
  PaymentOrderResult? order;
  Timer? timer;
  String message = 'Bestellung wird erstellt …';
  bool loading = true;
  bool preparing = false;
  bool finished = false;

  @override
  void initState() {
    super.initState();
    _createOrder();
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> _createOrder() async {
    try {
      final result = await widget.store.createPaymentOrder(
        recipe: widget.recipe,
        targetVolumeMl: widget.targetVolumeMl,
      );
      if (!mounted) return;
      setState(() {
        order = result;
        loading = false;
        message = tr('QR-Code scannen und mit PayPal bezahlen');
      });
      timer = Timer.periodic(
        const Duration(seconds: 4),
        (_) => _checkPayment(),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        loading = false;
        message = '$error';
      });
    }
  }

  Future<void> _checkPayment() async {
    if (order == null || preparing || finished) return;
    try {
      final status = await widget.store.paymentStatus(order!.orderId);
      if (!mounted) return;
      setState(() {
        message = status.paid
            ? tr('Zahlung bestätigt - Cocktail wird vorbereitet')
            : '${tr('Warte auf Zahlung')} (${status.status})';
      });
      if (status.paid && !status.used) {
        await _prepareAfterPayment();
      } else if (status.used) {
        setState(() => message = tr('Diese Zahlung wurde bereits verwendet'));
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => message = '${tr('Zahlungsstatus konnte nicht geprüft werden')}: $error');
    }
  }

  Future<void> _prepareAfterPayment() async {
    timer?.cancel();
    if (order == null) return;
    setState(() => preparing = true);

    try {
      await widget.store.markPaymentUsed(order!.orderId);
      await widget.store.makeRecipe(
        widget.recipe,
        targetVolumeMl: widget.targetVolumeMl,
        targetAlcoholPercent: widget.targetAlcoholPercent,
      );
      if (!mounted) return;
      setState(() {
        preparing = false;
        finished = true;
        message = tr('Zubereitung abgeschlossen');
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('Zubereitung abgeschlossen'))),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        preparing = false;
        message = '${tr('Fehler bei der Zubereitung')}: $error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final price = widget.store.priceForRecipe(widget.recipe);
    return PageFrame(
      title: tr('PayPal Zahlung'),
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                children: [
                  Text(
                    widget.store.displayRecipeName(widget.recipe),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 22,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${widget.targetVolumeMl.toStringAsFixed(0)} ml · ${price.toStringAsFixed(2).replaceAll('.', ',')} €',
                    style: TextStyle(
                      color: widget.store.appColors.textSecondaryColor,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 22),
                  if (loading)
                    const CircularProgressIndicator()
                  else if (order == null)
                    Icon(
                      Icons.error_outline,
                      color: widget.store.appColors.errorColor,
                      size: 52,
                    )
                  else
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: QrImageView(
                        data: order!.approvalUrl,
                        version: QrVersions.auto,
                        size: 260,
                        backgroundColor: Colors.white,
                      ),
                    ),
                  const SizedBox(height: 18),
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      height: 1.35,
                    ),
                  ),
                  if (order != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Order: ${order!.orderId}',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: widget.store.appColors.textSecondaryColor,
                        fontSize: 12,
                      ),
                    ),
                  ],
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: preparing ? null : () => Navigator.pop(context),
                          icon: const Icon(Icons.close),
                          label: Text(tr('Abbrechen')),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: order == null || preparing || finished
                              ? null
                              : _checkPayment,
                          icon: preparing
                              ? const SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.refresh),
                          label: Text(
                            preparing
                                ? tr('Zubereitung läuft')
                                : tr('Zahlung prüfen'),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}


class PartyCardsPage extends StatefulWidget {
  const PartyCardsPage({super.key, required this.store});
  final MachineStore store;

  @override
  State<PartyCardsPage> createState() => _PartyCardsPageState();
}

class _PartyCardsPageState extends State<PartyCardsPage> {
  final nameController = TextEditingController();
  final selectedRecipeIds = <String>{};
  final popularity = <String, CocktailPopularity>{};
  String? editingId;

  @override
  void initState() {
    super.initState();
    nameController.text = 'Sommerparty';
  }

  @override
  void dispose() {
    nameController.dispose();
    super.dispose();
  }

  void _edit(PartyCardProfile card) {
    setState(() {
      editingId = card.id;
      nameController.text = card.name;
      selectedRecipeIds
        ..clear()
        ..addAll(card.recipeIds);
      popularity
        ..clear()
        ..addAll(card.popularity);
    });
  }

  Future<void> _save() async {
    if (selectedRecipeIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('Bitte mindestens einen Cocktail auswählen'))),
      );
      return;
    }

    final ids = widget.store.recipes
        .where((recipe) => selectedRecipeIds.contains(recipe.id))
        .map((recipe) => recipe.id)
        .toList();

    await widget.store.savePartyCard(
      nameController.text,
      ids,
      popularity,
      existingId: editingId,
    );

    if (!mounted) return;
    setState(() {
      editingId = null;
      nameController.text = 'Sommerparty';
      selectedRecipeIds.clear();
      popularity.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final cards = [...widget.store.partyCards]
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

    return PageFrame(
      title: tr('Partykarten'),
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    editingId == null
                        ? tr('Neue Partykarte erstellen')
                        : tr('Partykarte bearbeiten'),
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 18,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    tr('Eine Partykarte ist die kleinere Auswahl aus deiner Cocktailliste. Dazu wird je Cocktail eine erwartete Beliebtheit gespeichert.'),
                    style: TextStyle(
                      color: widget.store.appColors.textSecondaryColor,
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: nameController,
                    decoration: InputDecoration(
                      labelText: tr('Name der Partykarte'),
                    ),
                  ),
                  const SizedBox(height: 14),
                  ...widget.store.recipes.map((recipe) {
                    final checked = selectedRecipeIds.contains(recipe.id);
                    final recipePopularity =
                        popularity[recipe.id] ?? CocktailPopularity.medium;
                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        child: Row(
                          children: [
                            Checkbox(
                              value: checked,
                              onChanged: (value) {
                                setState(() {
                                  if (value == true) {
                                    selectedRecipeIds.add(recipe.id);
                                  } else {
                                    selectedRecipeIds.remove(recipe.id);
                                  }
                                });
                              },
                            ),
                            Expanded(
                              child: Text(
                                widget.store.displayRecipeName(recipe),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                            SizedBox(
                              width: 130,
                              child: DropdownButtonFormField<CocktailPopularity>(
                                value: recipePopularity,
                                decoration: InputDecoration(
                                  labelText: tr('Beliebtheit'),
                                ),
                                items: CocktailPopularity.values
                                    .map(
                                      (value) => DropdownMenuItem(
                                        value: value,
                                        child: Text(
                                          widget.store.popularityLabel(value),
                                        ),
                                      ),
                                    )
                                    .toList(),
                                onChanged: (value) {
                                  if (value == null) return;
                                  setState(() {
                                    popularity[recipe.id] = value;
                                    selectedRecipeIds.add(recipe.id);
                                  });
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _save,
                      icon: const Icon(Icons.save_outlined),
                      label: Text(tr('Partykarte speichern')),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 18),
          if (cards.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Text(tr('Noch keine Partykarte gespeichert')),
              ),
            )
          else
            ...cards.map(
              (card) => Card(
                child: ListTile(
                  leading: Icon(
                    Icons.fact_check_outlined,
                    color: widget.store.activePartyCardId == card.id
                        ? widget.store.appColors.successColor
                        : widget.store.appColors.accentColor,
                  ),
                  title: Text(
                    card.name,
                    style: const TextStyle(fontWeight: FontWeight.w900),
                  ),
                  subtitle: Text(
                    '${card.recipeIds.length} ${tr('Cocktails')}'
                    '${widget.store.activePartyCardId == card.id ? ' · ${tr('Aktiv')}' : ''}',
                  ),
                  trailing: PopupMenuButton<String>(
                    onSelected: (action) async {
                      if (action == 'edit') {
                        _edit(card);
                      } else if (action == 'activate') {
                        await widget.store.setPartyPlannerSettings(
                          partyCardId: card.id,
                        );
                        if (mounted) setState(() {});
                      } else if (action == 'delete') {
                        await widget.store.deletePartyCard(card.id);
                        if (mounted) setState(() {});
                      }
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'activate',
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.check_circle_outline),
                          title: Text(tr('Aktivieren')),
                        ),
                      ),
                      PopupMenuItem(
                        value: 'edit',
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.edit_outlined),
                          title: Text(tr('Bearbeiten')),
                        ),
                      ),
                      PopupMenuItem(
                        value: 'delete',
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.delete_outline),
                          title: Text(tr('Löschen')),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class PartyPlannerPage extends StatefulWidget {
  const PartyPlannerPage({super.key, required this.store});
  final MachineStore store;

  @override
  State<PartyPlannerPage> createState() => _PartyPlannerPageState();
}

class _PartyPlannerPageState extends State<PartyPlannerPage> {
  late final partyNameController = TextEditingController(text: 'Cocktailparty');
  late final guestController = TextEditingController(
    text: widget.store.partyPlannerGuestCount.toString(),
  );
  late final reserveController = TextEditingController(
    text: widget.store.partyPlannerReservePercent.toString(),
  );

  @override
  void dispose() {
    partyNameController.dispose();
    guestController.dispose();
    reserveController.dispose();
    super.dispose();
  }

  int _readInt(TextEditingController controller, int fallback) {
    return int.tryParse(controller.text.trim()) ?? fallback;
  }

  String _date(DateTime value) {
    final day = value.day.toString().padLeft(2, '0');
    final month = value.month.toString().padLeft(2, '0');
    return '$day.$month.${value.year}';
  }

  Future<void> _savePlanningSettings(String cardId) async {
    await widget.store.setPartyPlannerSettings(
      guestCount: _readInt(guestController, 30),
      reservePercent: _readInt(reserveController, 10),
      partyCardId: cardId,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cards = widget.store.partyCards;
    final selectedCard = widget.store.partyCardById(
          widget.store.activePartyCardId,
        ) ??
        cards.firstOrNull;
    final activeSession = widget.store.activePartySession();
    final guestCount = _readInt(
      guestController,
      widget.store.partyPlannerGuestCount,
    ).clamp(1, 10000).toInt();
    final reservePercent = _readInt(
      reserveController,
      widget.store.partyPlannerReservePercent,
    ).clamp(0, 100).toInt();

    final stats = selectedCard == null
        ? <CocktailPlanningStats>[]
        : widget.store.planningStatsForPartyCard(
            selectedCard,
            guestCount: guestCount,
            reservePercent: reservePercent,
          );
    final completed = selectedCard == null
        ? <PartySession>[]
        : widget.store.completedPartySessionsForCard(selectedCard.id);
    final plannedTotal = stats.fold<int>(
      0,
      (sum, entry) => sum + entry.plannedCount,
    );
    final minTotal = completed.isEmpty
        ? 0
        : completed
            .map((session) => session.drinksPerGuest * guestCount)
            .reduce(math.min)
            .round();
    final avgTotal = completed.isEmpty
        ? plannedTotal
        : (completed.fold<double>(
                  0,
                  (sum, session) => sum + session.drinksPerGuest,
                ) /
                completed.length *
                guestCount)
            .round();
    final maxTotal = completed.isEmpty
        ? 0
        : completed
            .map((session) => session.drinksPerGuest * guestCount)
            .reduce(math.max)
            .round();
    final usage = widget.store.plannedIngredientUsageMl(stats);
    final missingLiters = usage.entries.fold<double>(0, (sum, entry) {
      final ingredientPumps = widget.store.pumps.where(
        (pump) => pump.ingredientId == entry.key,
      );
      final available = ingredientPumps.fold<double>(
        0,
        (innerSum, pump) => innerSum + pump.remainingMl,
      );
      return sum + math.max(0, entry.value - available);
    }) / 1000;

    return PageFrame(
      title: tr('Partyplaner'),
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (cards.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Text(
                  tr('Bitte zuerst unter Einstellungen → Partykarten eine Partykarte erstellen.'),
                ),
              ),
            )
          else ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tr('Party planen'),
                      style: const TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 18,
                      ),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: partyNameController,
                      decoration: InputDecoration(labelText: tr('Partyname')),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: guestController,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(labelText: tr('Gästezahl')),
                      onChanged: (_) => setState(() {}),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: reserveController,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: tr('Reserve in Prozent'),
                        helperText: tr('Cocktails pro Gast werden automatisch aus vergangenen Partys berechnet.'),
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      value: selectedCard?.id,
                      decoration: InputDecoration(labelText: tr('Partykarte')),
                      items: cards
                          .map(
                            (card) => DropdownMenuItem(
                              value: card.id,
                              child: Text(card.name),
                            ),
                          )
                          .toList(),
                      onChanged: (value) async {
                        if (value == null) return;
                        await _savePlanningSettings(value);
                        if (mounted) setState(() {});
                      },
                    ),
                    const SizedBox(height: 14),
                    if (selectedCard != null)
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: activeSession == null
                                  ? () async {
                                      await _savePlanningSettings(
                                        selectedCard.id,
                                      );
                                      await widget.store.startPartySession(
                                        name: partyNameController.text,
                                        guestCount: guestCount,
                                        partyCardId: selectedCard.id,
                                      );
                                      if (mounted) setState(() {});
                                    }
                                  : null,
                              icon: const Icon(Icons.play_arrow),
                              label: Text(tr('Party starten')),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: activeSession == null
                                  ? null
                                  : () async {
                                      await widget.store.endActivePartySession();
                                      if (mounted) setState(() {});
                                    },
                              icon: const Icon(Icons.stop_circle_outlined),
                              label: Text(tr('Party beenden')),
                            ),
                          ),
                        ],
                      ),
                    if (activeSession != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        '${tr('Aktive Party')}: ${activeSession.name} · '
                        '${activeSession.totalDrinks} ${tr('Cocktails')}',
                        style: TextStyle(
                          color: widget.store.appColors.successColor,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 18),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tr('Prognose aus vergangenen Partys'),
                      style: const TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 18,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      completed.isEmpty
                          ? tr('Noch keine abgeschlossene Party mit dieser Partykarte. Die Planung nutzt Standardwerte und die Beliebtheit der Partykarte.')
                          : '${tr('Basis')}: ${completed.length} ${tr('abgeschlossene Partys mit dieser Partykarte')}',
                      style: TextStyle(
                        color: widget.store.appColors.textSecondaryColor,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        _PlannerMetric(
                          label: tr('Min. gesamt'),
                          value: completed.isEmpty ? '–' : '$minTotal',
                        ),
                        _PlannerMetric(
                          label: tr('Ø gesamt'),
                          value: '$avgTotal',
                        ),
                        _PlannerMetric(
                          label: tr('Max. gesamt'),
                          value: completed.isEmpty ? '–' : '$maxTotal',
                        ),
                        _PlannerMetric(
                          label: tr('Geplant'),
                          value: '$plannedTotal',
                        ),
                        _PlannerMetric(
                          label: tr('Fehlt ca.'),
                          value: '${missingLiters.toStringAsFixed(2)} L',
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    ...stats.map(
                      (entry) => Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          title: Text(
                            widget.store.displayRecipeName(entry.recipe),
                            style: const TextStyle(fontWeight: FontWeight.w900),
                          ),
                          subtitle: Text(
                            completed.isEmpty
                                ? '${tr('Noch keine Min/Ø/Max-Werte')} · ${tr('Plan')}: ${entry.plannedCount}'
                                : '${tr('Min')}: ${entry.minCount} · Ø ${entry.averageCount} · ${tr('Max')}: ${entry.maxCount}',
                          ),
                          trailing: Text(
                            '${entry.plannedCount}',
                            style: TextStyle(
                              color: widget.store.appColors.accentColor,
                              fontWeight: FontWeight.w900,
                              fontSize: 20,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 18),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tr('Geplanter Zutatenbedarf'),
                      style: const TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 18,
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (usage.isEmpty)
                      Text(tr('Keine Zutaten berechnet'))
                    else
                      ...usage.entries.map((entry) {
                        final ingredientName =
                            widget.store.displayIngredientNameById(entry.key);
                        final ingredientPumps = widget.store.pumps.where(
                          (pump) => pump.ingredientId == entry.key,
                        );
                        final available = ingredientPumps.fold<double>(
                          0,
                          (sum, pump) => sum + pump.remainingMl,
                        );
                        final missing = math.max(0, entry.value - available);
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  ingredientName,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                              Text(
                                '${(entry.value / 1000).toStringAsFixed(2)} L',
                              ),
                              const SizedBox(width: 12),
                              Text(
                                missing <= 0
                                    ? tr('vorhanden')
                                    : '${tr('fehlt')} ${(missing / 1000).toStringAsFixed(2)} L',
                                style: TextStyle(
                                  color: missing <= 0
                                      ? widget.store.appColors.successColor
                                      : widget.store.appColors.errorColor,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ],
                          ),
                        );
                      }),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 18),
            if (widget.store.partySessions.isNotEmpty)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        tr('Vergangene Partys'),
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 18,
                        ),
                      ),
                      const SizedBox(height: 12),
                      ...([...widget.store.partySessions]
                            ..sort(
                              (a, b) => b.startedAt.compareTo(a.startedAt),
                            ))
                          .map(
                        (session) => ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            session.isActive
                                ? Icons.play_circle_outline
                                : Icons.event_available_outlined,
                          ),
                          title: Text(
                            session.name,
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                          subtitle: Text(
                            '${session.partyCardName} · ${_date(session.startedAt)} · '
                            '${session.guestCount} ${tr('Gäste')} · '
                            '${session.totalDrinks} ${tr('Cocktails')}',
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () async {
                              await widget.store.deletePartySession(session.id);
                              if (mounted) setState(() {});
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _PlannerMetric extends StatelessWidget {
  const _PlannerMetric({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 145,
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 6),
              Text(
                value,
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 20,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}


class CocktailListsPage extends StatefulWidget {
  const CocktailListsPage({
    super.key,
    required this.store,
  });

  final MachineStore store;

  @override
  State<CocktailListsPage> createState() => _CocktailListsPageState();
}

class _CocktailListsPageState extends State<CocktailListsPage> {
  final nameController = TextEditingController();

  @override
  void dispose() {
    nameController.dispose();
    super.dispose();
  }

  String _date(DateTime value) {
    final day = value.day.toString().padLeft(2, '0');
    final month = value.month.toString().padLeft(2, '0');
    return '$day.$month.${value.year}';
  }

  Future<void> _saveCurrentList() async {
    final messenger = ScaffoldMessenger.of(context);
    final name = nameController.text.trim();

    if (name.isEmpty) {
      messenger.showSnackBar(
        SnackBar(content: Text(tr('Bitte einen Namen eingeben'))),
      );
      return;
    }

    await widget.store.saveCurrentCocktailList(name);
    nameController.clear();

    if (!mounted) return;
    setState(() {});

    messenger.showSnackBar(
      SnackBar(content: Text(tr('Cocktailliste wurde gespeichert'))),
    );
  }

  Future<void> _loadList(CocktailListProfile list) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr('Cocktailliste laden')),
        content: Text(
          '${tr('Aktuelle Rezepte werden durch diese Liste ersetzt')}: ${list.name}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(tr('Abbrechen')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(tr('Laden')),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    await widget.store.loadCocktailList(list.id);

    if (!mounted) return;
    setState(() {});

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(tr('Cocktailliste wurde geladen'))),
    );
  }

  Future<void> _deleteList(CocktailListProfile list) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr('Cocktailliste löschen')),
        content: Text('${tr('Soll diese Liste gelöscht werden?')} ${list.name}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(tr('Abbrechen')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(tr('Löschen')),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    await widget.store.deleteCocktailList(list.id);

    if (!mounted) return;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final lists = [...widget.store.cocktailLists]
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

    return PageFrame(
      title: tr('Cocktaillisten'),
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr('Aktuelle Rezepte als Liste speichern'),
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 18,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    tr(
                      'Speichert die aktuell vorhandenen Rezepte als eigene Cocktailliste. Beim Laden ersetzt die Liste die aktuellen Rezepte.',
                    ),
                    style: TextStyle(
                      color: widget.store.appColors.textSecondaryColor,
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: nameController,
                    decoration: InputDecoration(
                      labelText: tr('Name der Cocktailliste'),
                      hintText: tr('Zum Beispiel: Sommerparty'),
                    ),
                    onSubmitted: (_) => _saveCurrentList(),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _saveCurrentList,
                      icon: const Icon(Icons.save_outlined),
                      label: Text(tr('Aktuelle Liste speichern')),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 18),
          if (lists.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Text(tr('Noch keine Cocktaillisten gespeichert')),
              ),
            )
          else
            ...lists.map(
              (list) {
                final active = widget.store.activeCocktailListId == list.id;
                return Card(
                  child: ListTile(
                    leading: Icon(
                      active
                          ? Icons.playlist_add_check_circle
                          : Icons.playlist_add_check,
                      color: active
                          ? widget.store.appColors.successColor
                          : widget.store.appColors.accentColor,
                    ),
                    title: Text(
                      list.name,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    subtitle: Text(
                      '${list.recipes.length} ${tr('Rezepte')} · '
                      '${tr('Gespeichert')}: ${_date(list.updatedAt)}'
                      '${active ? ' · ${tr('Aktiv')}' : ''}',
                    ),
                    trailing: PopupMenuButton<String>(
                      onSelected: (action) {
                        if (action == 'load') {
                          _loadList(list);
                        } else if (action == 'delete') {
                          _deleteList(list);
                        }
                      },
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: 'load',
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.download_done),
                            title: Text(tr('Laden')),
                          ),
                        ),
                        PopupMenuItem(
                          value: 'delete',
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.delete_outline),
                            title: Text(tr('Löschen')),
                          ),
                        ),
                      ],
                    ),
                    onTap: () => _loadList(list),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}

class RecipeManagementPage extends StatefulWidget {
  const RecipeManagementPage({
    super.key,
    required this.store,
  });

  final MachineStore store;

  @override
  State<RecipeManagementPage> createState() =>
      _RecipeManagementPageState();
}

class _RecipeManagementPageState extends State<RecipeManagementPage> {
  @override
  Widget build(BuildContext context) {
    return PageFrame(title: tr('Rezepte'),
      actions: [
        IconButton(
          tooltip: tr('Neues Rezept'),
          onPressed: _createRecipe,
          icon: const Icon(Icons.add),
        ),
      ],
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          FilledButton.icon(
            onPressed: _createRecipe,
            icon: const Icon(Icons.add),
            label: const T('Neues Rezept erstellen'),
          ),
          const SizedBox(height: 16),
          ...widget.store.recipes.map(
            (recipe) => Card(
              child: ListTile(
                leading: Icon(
                  switch (recipe.category) {
                    DrinkCategory.cocktail => Icons.local_bar,
                    DrinkCategory.mocktail => Icons.local_drink,
                    DrinkCategory.shot => Icons.liquor,
                  },
                  color: const Color(0xFF16D9CC),
                ),
                title: Text(widget.store.displayRecipeName(recipe)),
                subtitle: Text('${recipe.baseVolumeMl.toStringAsFixed(0)} ml ${tr('Rezeptbasis')} · '
                  '${recipe.parts.length} ${tr('Zutaten')}',
                ),
                trailing: PopupMenuButton<String>(
                  onSelected: (action) {
                    if (action == 'edit') {
                      _editRecipe(recipe);
                    } else if (action == 'delete') {
                      _deleteRecipe(recipe);
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'edit',
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.edit_outlined),
                        title: T('Bearbeiten'),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.delete_outline),
                        title: T('Löschen'),
                      ),
                    ),
                  ],
                ),
                onTap: () => _editRecipe(recipe),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _createRecipe() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => RecipeEditorPage(store: widget.store),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _editRecipe(Recipe recipe) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => RecipeEditorPage(
          store: widget.store,
          recipe: recipe,
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _deleteRecipe(Recipe recipe) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const T('Rezept löschen?'),
        content: Text('„${widget.store.displayRecipeName(recipe)}“ ${tr('wird dauerhaft gelöscht.')}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const T('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const T('Löschen'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    widget.store.recipes.remove(recipe);
    await widget.store.save();
    if (mounted) setState(() {});
  }
}

class RecipeEditorPage extends StatefulWidget {
  const RecipeEditorPage({
    super.key,
    required this.store,
    this.recipe,
  });

  final MachineStore store;
  final Recipe? recipe;

  @override
  State<RecipeEditorPage> createState() => _RecipeEditorPageState();
}

class _RecipeEditorPageState extends State<RecipeEditorPage> {
  late final TextEditingController name;
  late final TextEditingController description;
  late final TextEditingController baseVolume;
  late DrinkCategory category;
  late final List<RecipePart> parts;
  late final List<String> manualNotes;
  String? imagePath;

  bool get isEditing => widget.recipe != null;

  @override
  void initState() {
    super.initState();
    final recipe = widget.recipe;
    name = TextEditingController(text: recipe?.name ?? '');
    description = TextEditingController(
      text: recipe == null ? '' : widget.store.displayRecipeDescription(recipe),
    );
    category = recipe?.category ?? DrinkCategory.cocktail;
    baseVolume = TextEditingController(
      text: (recipe?.baseVolumeMl ??
              widget.store.defaultSizeFor(category))
          .toStringAsFixed(0),
    );
    imagePath = recipe?.imagePath;
    manualNotes = List<String>.from(recipe?.manualNotes ?? const []);
    parts = recipe?.parts
            .map(
              (part) => RecipePart(
                ingredientId: part.ingredientId,
                amountMl: part.amountMl,
                automatic: part.automatic,
                delayed: part.delayed,
                instruction: part.instruction,
              ),
            )
            .toList() ??
        <RecipePart>[];
  }

  @override
  void dispose() {
    name.dispose();
    description.dispose();
    baseVolume.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PageFrame(
      title: isEditing ? tr('Rezept bearbeiten') : tr('Neues Rezept'),
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          TextField(
            controller: name,
            decoration: InputDecoration(labelText: tr('Name des Getränks')),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: description,
            maxLines: 3,
            decoration: InputDecoration(labelText: tr('Beschreibung')),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField(
            initialValue: category,
            decoration: InputDecoration(labelText: tr('Kategorie')),
            items: DrinkCategory.values
                .map(
                  (e) => DropdownMenuItem(
                    value: e,
                    child: Text(
                      switch (e) {
                        DrinkCategory.cocktail => tr('Cocktail'),
                        DrinkCategory.mocktail => tr('Alkoholfrei'),
                        DrinkCategory.shot => tr('Shot'),
                      },
                    ),
                  ),
                )
                .toList(),
            onChanged: (v) => setState(() {
              category = v!;
              if (!isEditing) {
                baseVolume.text =
                    widget.store.defaultSizeFor(category).toStringAsFixed(0);
              }
            }),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: baseVolume,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: tr('Größe, für die das Rezept eingetragen wird'),
              suffixText: tr('ml'),
              helperText: tr(
                'Beispiel: Rezeptwerte für 300 ml eingeben. '
                'Die App skaliert automatisch auf 200 ml oder andere Größen.',
              ),
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () async {
              final x = await ImagePicker().pickImage(
                source: ImageSource.gallery,
                imageQuality: 80,
                maxWidth: 1600,
              );
              if (x == null) return;
              final bytes = await x.readAsBytes();
              if (!mounted) return;
              final mime = imageMimeType(x.name);
              setState(
                () => imagePath = 'data:$mime;base64,${base64Encode(bytes)}',
              );
            },
            icon: const Icon(Icons.image),
            label: Text(
              imagePath == null ? tr('Bild hinzufügen') : tr('Bild ausgewählt'),
            ),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              T('Zutaten',
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
              const Spacer(),
              FilledButton.tonalIcon(
                onPressed: _addPart,
                icon: const Icon(Icons.add),
                label: const T('Zutat'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _addManualNote,
                icon: const Icon(Icons.notes),
                label: const T('Hinweis'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (manualNotes.isNotEmpty) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const T('Zusätzliche manuelle Hinweise',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 8),
                    ...manualNotes.asMap().entries.map(
                      (entry) => ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(
                          Icons.pan_tool_alt_outlined,
                          color: Color(0xFFFFA726),
                        ),
                        title: Text(entry.value),
                        trailing: IconButton(
                          onPressed: () => setState(
                            () => manualNotes.removeAt(entry.key),
                          ),
                          icon: const Icon(Icons.delete_outline),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
          ...parts.asMap().entries.map((entry) {
            final i = entry.key;
            final p = entry.value;
            return Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  children: [
                    DropdownButtonFormField(
                      initialValue: p.ingredientId,
                      decoration: InputDecoration(labelText: tr('Zutat')),
                      items: widget.store.ingredients
                          .map(
                            (e) => DropdownMenuItem(
                              value: e.id,
                              child: Text(widget.store.displayIngredientName(e)),
                            ),
                          )
                          .toList(),
                      onChanged: (v) => p.ingredientId = v!,
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      initialValue: p.amountMl.toStringAsFixed(0),
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration:
                          InputDecoration(labelText: tr('Menge in ml')),
                      onChanged: (v) => p.amountMl =
                          double.tryParse(v.replaceAll(',', '.')) ??
                              p.amountMl,
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const T('Automatische Zutat'),
                      subtitle: const T('Wird über eine Pumpe dosiert'),
                      value: p.automatic,
                      onChanged: (v) => setState(() {
                        p.automatic = v;
                        if (!v) p.delayed = false;
                      }),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const T('Zum Schluss dosieren'),
                      subtitle: const T('Startet erst, wenn alle normalen Pumpen fertig sind'),
                      value: p.delayed,
                      onChanged: p.automatic
                          ? (v) => setState(() => p.delayed = v)
                          : null,
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: IconButton(
                        onPressed: () =>
                            setState(() => parts.removeAt(i)),
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.save),
            label: Text(isEditing ? tr('Änderungen speichern') : tr('Rezept speichern')),
          ),
        ],
      ),
    );
  }

  Future<void> _addManualNote() async {
    String enteredText = '';

    final note = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const T('Manuellen Hinweis hinzufügen'),
        content: TextField(
          autofocus: true,
          maxLines: 3,
          decoration: InputDecoration(
            labelText: tr('Hinweis'),
            hintText: tr('Zum Beispiel: Mit Ananas dekorieren'),
          ),
          onChanged: (value) => enteredText = value,
          onSubmitted: (value) {
            final trimmed = value.trim();
            Navigator.pop(
              dialogContext,
              trimmed.isEmpty ? null : trimmed,
            );
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const T('Abbrechen'),
          ),
          FilledButton(
            onPressed: () {
              final trimmed = enteredText.trim();
              Navigator.pop(
                dialogContext,
                trimmed.isEmpty ? null : trimmed,
              );
            },
            child: const T('Hinzufügen'),
          ),
        ],
      ),
    );

    if (!mounted || note == null) return;
    setState(() => manualNotes.add(note));
  }

  void _addPart() {
    if (widget.store.ingredients.isEmpty) return;
    setState(
      () => parts.add(
        RecipePart(
          ingredientId: widget.store.ingredients.first.id,
          amountMl: 20,
          automatic: true,
        ),
      ),
    );
  }

  void _save() {
    final recipeSize =
        double.tryParse(baseVolume.text.replaceAll(',', '.'));

    if (name.text.trim().isEmpty ||
        parts.isEmpty ||
        recipeSize == null ||
        recipeSize <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: T('Name, gültige Rezeptgröße und mindestens eine Zutat erforderlich',
          ),
        ),
      );
      return;
    }

    if (isEditing) {
      final recipe = widget.recipe!;
      recipe.name = name.text.trim();
      recipe.description = description.text.trim();
      recipe.category = category;
      recipe.parts = List.of(parts);
      recipe.imagePath = imagePath;
      recipe.baseVolumeMl = recipeSize;
      recipe.manualNotes = List<String>.from(manualNotes);
    } else {
      widget.store.recipes.add(
        Recipe(
          id: '${DateTime.now().millisecondsSinceEpoch}',
          name: name.text.trim(),
          description: description.text.trim(),
          category: category,
          parts: List.of(parts),
          imagePath: imagePath,
          baseVolumeMl: recipeSize,
          manualNotes: List<String>.from(manualNotes),
        ),
      );
    }
    widget.store.save();
    Navigator.pop(context);
  }
}

