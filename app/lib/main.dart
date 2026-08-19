//noinspection SpellCheckingInspection
// spellchecker:disable
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

const int _cocktailBotUsageNoticeVersion = 1;
const String _cocktailBotUsageNoticePreferenceKey =
    'cocktailbot_usage_notice_hidden_version';

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
      // Wenn das Popup dieses Feld bereits bearbeitet, darf ein erneutes
      // Browser-Fokusereignis unseren lokalen Puffer NICHT neu laden. Genau
      // dieses Nachladen hat nach einer kurzen Tipp-Pause die alte Web-
      // Selektion wiederhergestellt und den nächsten Tastendruck ersetzt.
      if (_virtualKeyboardVisible && identical(editable, _activeEditable)) {
        return;
      }

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

        // Nach dem Erfassen des Felds übernimmt die CocktailBot-Tastatur die
        // Eingabe vollständig. Das echte HTML/Flutter-Eingabefeld wird
        // absichtlich ent-fokussiert, damit Chromium auch nach längerer Pause
        // keine Select-All-Selektion mehr zurück in den Controller schreiben
        // kann. Der Text selbst wird weiterhin direkt im Controller geändert.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !identical(_activeEditable, current)) return;
          current.widget.focusNode.unfocus();
        });
      });
      return;
    }

    // Solange die Popup-Tastatur aktiv ist, ist ein fehlender primärer Fokus
    // beabsichtigt. Das Popup bleibt offen, bis "Fertig"/"Schließen" gedrückt
    // oder ein anderes Eingabefeld angetippt wird.
    if (_virtualKeyboardVisible && _activeEditable != null) {
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

    final controller = editable.widget.controller;
    final oldValue = controller.value;

    // Cursor/Selektion gehören während des Popups ausschließlich unserem
    // lokalen Puffer. InputFormatter werden trotzdem angewendet, damit Zahlen-
    // und sonstige Feldregeln genauso gelten wie bei normaler Tastatureingabe.
    final requestedOffset = value.selection.isValid
        ? value.selection.extentOffset.clamp(0, value.text.length).toInt()
        : value.text.length;
    var normalized = value.copyWith(
      selection: TextSelection.collapsed(offset: requestedOffset),
      composing: TextRange.empty,
    );

    for (final formatter
        in editable.widget.inputFormatters ?? const <TextInputFormatter>[]) {
      normalized = formatter.formatEditUpdate(oldValue, normalized);
    }

    final finalOffset = (normalized.selection.isValid
            ? normalized.selection.extentOffset
            : normalized.text.length)
        .clamp(0, normalized.text.length)
        .toInt();
    normalized = normalized.copyWith(
      selection: TextSelection.collapsed(offset: finalOffset),
      composing: TextRange.empty,
    );

    // Kein userUpdateTextEditingValue() und kein requestFocus() mehr: Beides
    // koppelt die virtuelle Tastatur wieder an Chromiums verstecktes Web-
    // Eingabefeld. Bei einer Tipp-Pause konnte Chromium dadurch die komplette
    // Auswahl erneut markieren. Direkte Controller-Updates sind hier bewusst
    // deterministisch; onChanged wird wie bei Benutzereingabe manuell ausgelöst.
    _virtualKeyboardValue = normalized;
    controller.value = normalized;
    if (oldValue.text != normalized.text) {
      editable.widget.onChanged?.call(normalized.text);
    }

    // Falls ein onChanged-Handler den Controller bewusst korrigiert, übernehmen
    // wir dessen Ergebnis wieder in die Vorschau, ohne den Browser zu fokussieren.
    if (editable.mounted) {
      final accepted = controller.value;
      final acceptedOffset = (accepted.selection.isValid
              ? accepted.selection.extentOffset
              : accepted.text.length)
          .clamp(0, accepted.text.length)
          .toInt();
      _virtualKeyboardValue = accepted.copyWith(
        selection: TextSelection.collapsed(offset: acceptedOffset),
        composing: TextRange.empty,
      );
      if (controller.value.selection != _virtualKeyboardValue.selection ||
          controller.value.composing != TextRange.empty) {
        controller.value = _virtualKeyboardValue;
      }
    }

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
        home: StartupLicenseGate(store: store),
        builder: (context, child) {
          return Stack(
            children: [
              Positioned.fill(
                child: CocktailBotThemeBackground(colors: store.appColors),
              ),
              Positioned.fill(
                child: child ?? const SizedBox.shrink(),
              ),
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
  final effectiveBrightness =
      colors.backgroundColor.computeLuminance() > 0.52
          ? Brightness.light
          : Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: accent,
    brightness: effectiveBrightness,
  ).copyWith(
    primary: accent,
    secondary: colors.secondaryAccentColor,
    surface: surface,
    onSurface: colors.textPrimaryColor,
    error: colors.errorColor,
  );

  final base = ThemeData(
    useMaterial3: true,
    brightness: effectiveBrightness,
    colorScheme: scheme,
  );

  return base.copyWith(
    scaffoldBackgroundColor: Colors.transparent,
    textTheme: base.textTheme.apply(
      bodyColor: colors.textPrimaryColor,
      displayColor: colors.textPrimaryColor,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: colors.navigationColor.withValues(alpha: .96),
      foregroundColor: colors.textPrimaryColor,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    cardTheme: CardThemeData(
      color: colors.cardColor.withValues(
        alpha: switch (colors.visualStyle) {
          AppVisualStyle.custom => .96,
          AppVisualStyle.modern => .96,
          AppVisualStyle.tropical => .94,
          AppVisualStyle.vintage => .95,
          _ => .92,
        },
      ),
      elevation: switch (colors.visualStyle) {
        AppVisualStyle.modern => 4,
        AppVisualStyle.tropical => 3,
        AppVisualStyle.neon => 1,
        _ => 0,
      },
      shadowColor: colors.accentColor.withValues(
        alpha: colors.visualStyle == AppVisualStyle.neon ? .28 : .12,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(
          switch (colors.visualStyle) {
            AppVisualStyle.tropical => 16,
            AppVisualStyle.modern => 14,
            AppVisualStyle.industrial => 5,
            AppVisualStyle.vintage => 7,
            _ => 10,
          },
        ),
        side: BorderSide(
          color: colors.borderColor,
          width: colors.visualStyle == AppVisualStyle.neon ? 1.3 : 1,
        ),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: accent,
        foregroundColor:
            accent.computeLuminance() > .48 ? Colors.black : Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(
            switch (colors.visualStyle) {
              AppVisualStyle.tropical => 22,
              AppVisualStyle.modern => 12,
              AppVisualStyle.industrial => 4,
              AppVisualStyle.vintage => 6,
              _ => 9,
            },
          ),
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
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: colors.surfaceColor.withValues(alpha: .88),
      selectedColor: accent,
      disabledColor: colors.progressTrackColor,
      side: BorderSide(color: colors.borderColor),
      labelStyle: TextStyle(color: colors.textPrimaryColor),
      secondaryLabelStyle: TextStyle(
        color: accent.computeLuminance() > .48 ? Colors.black : Colors.white,
        fontWeight: FontWeight.w800,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(
          colors.visualStyle == AppVisualStyle.tropical ? 16 : 9,
        ),
      ),
    ),
    iconTheme: IconThemeData(color: colors.textSecondaryColor),
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



class CocktailBotThemeBackground extends StatelessWidget {
  const CocktailBotThemeBackground({
    super.key,
    required this.colors,
  });

  final AppColorThemeConfig colors;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        painter: _CocktailBotThemeBackgroundPainter(colors),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _CocktailBotThemeBackgroundPainter extends CustomPainter {
  const _CocktailBotThemeBackgroundPainter(this.colors);

  final AppColorThemeConfig colors;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    switch (colors.visualStyle) {
      case AppVisualStyle.custom:
        canvas.drawRect(rect, Paint()..color = colors.backgroundColor);
        break;
      case AppVisualStyle.elegant:
        _paintElegant(canvas, rect);
        break;
      case AppVisualStyle.modern:
        _paintModern(canvas, rect);
        break;
      case AppVisualStyle.neon:
        _paintNeon(canvas, rect);
        break;
      case AppVisualStyle.tropical:
        _paintTropical(canvas, rect);
        break;
      case AppVisualStyle.industrial:
        _paintIndustrial(canvas, rect);
        break;
      case AppVisualStyle.vintage:
        _paintVintage(canvas, rect);
        break;
    }
  }

  void _paintElegant(Canvas canvas, Rect rect) {
    final paint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          const Color(0xFF030303),
          colors.backgroundColor,
          const Color(0xFF171006),
          const Color(0xFF050505),
        ],
        stops: const [0, .34, .72, 1],
      ).createShader(rect);
    canvas.drawRect(rect, paint);

    final glow = Paint()
      ..shader = RadialGradient(
        center: const Alignment(.75, -.7),
        radius: 1.2,
        colors: [
          colors.accentColor.withValues(alpha: .16),
          Colors.transparent,
        ],
      ).createShader(rect);
    canvas.drawRect(rect, glow);

    final line = Paint()
      ..color = colors.accentColor.withValues(alpha: .07)
      ..strokeWidth = 1;
    for (double x = -rect.height; x < rect.width; x += 62) {
      canvas.drawLine(
        Offset(x, rect.height),
        Offset(x + rect.height, 0),
        line,
      );
    }
  }

  void _paintModern(Canvas canvas, Rect rect) {
    final paint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          const Color(0xFFFDFEFF),
          colors.backgroundColor,
          const Color(0xFFE6EEF7),
        ],
      ).createShader(rect);
    canvas.drawRect(rect, paint);
    final bubble = Paint()..color = colors.accentColor.withValues(alpha: .055);
    canvas.drawCircle(Offset(rect.width * .86, rect.height * .12), rect.width * .18, bubble);
    canvas.drawCircle(Offset(rect.width * .08, rect.height * .76), rect.width * .14, bubble);
    bubble.color = colors.secondaryAccentColor.withValues(alpha: .05);
    canvas.drawCircle(Offset(rect.width * .55, rect.height * .92), rect.width * .22, bubble);
  }

  void _paintNeon(Canvas canvas, Rect rect) {
    final base = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF01040C), Color(0xFF03112B), Color(0xFF080016)],
      ).createShader(rect);
    canvas.drawRect(rect, base);

    final cyanGlow = Paint()
      ..shader = RadialGradient(
        center: const Alignment(-.8, -.65),
        radius: .9,
        colors: [colors.accentColor.withValues(alpha: .18), Colors.transparent],
      ).createShader(rect);
    canvas.drawRect(rect, cyanGlow);
    final magentaGlow = Paint()
      ..shader = RadialGradient(
        center: const Alignment(.85, .7),
        radius: 1,
        colors: [colors.secondaryAccentColor.withValues(alpha: .16), Colors.transparent],
      ).createShader(rect);
    canvas.drawRect(rect, magentaGlow);

    final grid = Paint()
      ..color = colors.accentColor.withValues(alpha: .075)
      ..strokeWidth = .7;
    const step = 36.0;
    for (double x = 0; x <= rect.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, rect.height), grid);
    }
    for (double y = 0; y <= rect.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(rect.width, y), grid);
    }
  }

  void _paintTropical(Canvas canvas, Rect rect) {
    final base = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Color(0xFF5ED3D6),
          Color(0xFFB8F0E7),
          Color(0xFFF6E1B5),
          Color(0xFFECCB8C),
        ],
        stops: [0, .56, .76, 1],
      ).createShader(rect);
    canvas.drawRect(rect, base);

    final sun = Paint()..color = const Color(0xFFFFC45C).withValues(alpha: .36);
    canvas.drawCircle(Offset(rect.width * .84, rect.height * .17), rect.height * .12, sun);

    final wave = Paint()
      ..color = const Color(0xFFFFFFFF).withValues(alpha: .28)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4;
    for (var i = 0; i < 4; i++) {
      final path = Path()..moveTo(0, rect.height * (.60 + i * .035));
      for (double x = 0; x <= rect.width; x += 28) {
        path.quadraticBezierTo(
          x + 7,
          rect.height * (.60 + i * .035) - 5,
          x + 14,
          rect.height * (.60 + i * .035),
        );
        path.quadraticBezierTo(
          x + 21,
          rect.height * (.60 + i * .035) + 5,
          x + 28,
          rect.height * (.60 + i * .035),
        );
      }
      canvas.drawPath(path, wave);
    }

    final leaf = Paint()
      ..color = const Color(0xFF087E68).withValues(alpha: .22)
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round;
    _drawPalm(canvas, Offset(8, 18), 1, leaf);
    _drawPalm(canvas, Offset(rect.width - 8, 24), -1, leaf);
  }

  void _drawPalm(Canvas canvas, Offset origin, double direction, Paint paint) {
    final stem = Path()
      ..moveTo(origin.dx, origin.dy)
      ..quadraticBezierTo(
        origin.dx + 34 * direction,
        origin.dy + 28,
        origin.dx + 54 * direction,
        origin.dy + 74,
      );
    canvas.drawPath(stem, paint);
    for (var i = 0; i < 5; i++) {
      final y = origin.dy + 12 + i * 11;
      canvas.drawLine(
        Offset(origin.dx + (12 + i * 7) * direction, y),
        Offset(origin.dx + (58 + i * 8) * direction, y - 22 + i * 2),
        paint..strokeWidth = 3,
      );
    }
  }

  void _paintIndustrial(Canvas canvas, Rect rect) {
    final base = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF11100F), Color(0xFF292521), Color(0xFF171513)],
      ).createShader(rect);
    canvas.drawRect(rect, base);

    final seam = Paint()
      ..color = const Color(0xFF8A7C6B).withValues(alpha: .12)
      ..strokeWidth = 1.2;
    const plateW = 180.0;
    const plateH = 120.0;
    for (double x = 0; x < rect.width; x += plateW) {
      canvas.drawLine(Offset(x, 0), Offset(x, rect.height), seam);
    }
    for (double y = 0; y < rect.height; y += plateH) {
      canvas.drawLine(Offset(0, y), Offset(rect.width, y), seam);
    }
    final rivet = Paint()..color = const Color(0xFFB7AA98).withValues(alpha: .18);
    for (double x = 12; x < rect.width; x += plateW) {
      for (double y = 12; y < rect.height; y += plateH) {
        canvas.drawCircle(Offset(x, y), 2.2, rivet);
      }
    }
    final slash = Paint()
      ..color = colors.accentColor.withValues(alpha: .035)
      ..strokeWidth = 9;
    for (double x = -rect.height; x < rect.width; x += 76) {
      canvas.drawLine(Offset(x, rect.height), Offset(x + rect.height, 0), slash);
    }
  }

  void _paintVintage(Canvas canvas, Rect rect) {
    final base = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFFFFEDC7), Color(0xFFEAD0A0), Color(0xFFF7E5BF)],
      ).createShader(rect);
    canvas.drawRect(rect, base);

    final grain = Paint()..color = const Color(0xFF5D351B).withValues(alpha: .055);
    var seed = 17;
    for (var i = 0; i < 460; i++) {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      final x = (seed % 10000) / 10000 * rect.width;
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      final y = (seed % 10000) / 10000 * rect.height;
      canvas.drawCircle(Offset(x, y), .55 + (seed % 3) * .25, grain);
    }
    final frame = Paint()
      ..color = colors.accentColor.withValues(alpha: .28)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3;
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect.deflate(8), const Radius.circular(12)),
      frame,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect.deflate(13), const Radius.circular(9)),
      frame..color = colors.accentColor.withValues(alpha: .13),
    );
  }

  @override
  bool shouldRepaint(covariant _CocktailBotThemeBackgroundPainter oldDelegate) {
    return oldDelegate.colors.toJson().toString() != colors.toJson().toString();
  }
}

BoxDecoration cocktailBotNavigationDecoration(AppColorThemeConfig colors) {
  final radius = switch (colors.visualStyle) {
    AppVisualStyle.industrial => 0.0,
    AppVisualStyle.vintage => 0.0,
    _ => 0.0,
  };
  return BoxDecoration(
    color: colors.navigationColor.withValues(alpha: .94),
    gradient: switch (colors.visualStyle) {
      AppVisualStyle.custom => null,
      AppVisualStyle.elegant => LinearGradient(
          colors: [const Color(0xFF080808), colors.navigationColor, const Color(0xFF151006)],
        ),
      AppVisualStyle.neon => LinearGradient(
          colors: [const Color(0xFF02091A), colors.navigationColor, const Color(0xFF09031A)],
        ),
      AppVisualStyle.tropical => LinearGradient(
          colors: [const Color(0xFF078C9A), colors.navigationColor, const Color(0xFF0BB9B0)],
        ),
      AppVisualStyle.industrial => LinearGradient(
          colors: [const Color(0xFF161310), colors.navigationColor, const Color(0xFF27211B)],
        ),
      AppVisualStyle.vintage => LinearGradient(
          colors: [const Color(0xFFE0BD84), colors.navigationColor, const Color(0xFFF0D7A6)],
        ),
      AppVisualStyle.modern => LinearGradient(
          colors: [const Color(0xFFFFFFFF), colors.navigationColor, const Color(0xFFF0F5FA)],
        ),
    },
    borderRadius: BorderRadius.circular(radius),
    border: Border(bottom: BorderSide(color: colors.borderColor, width: 1)),
    boxShadow: colors.visualStyle == AppVisualStyle.neon
        ? [BoxShadow(color: colors.accentColor.withValues(alpha: .16), blurRadius: 16)]
        : null,
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


enum AppVisualStyle { custom, elegant, modern, neon, tropical, industrial, vintage }

extension AppVisualStyleMeta on AppVisualStyle {
  String get storageValue => name;
}

AppVisualStyle _appVisualStyleFromStorage(String? value) {
  return AppVisualStyle.values.firstWhere(
    (style) => style.name == value,
    orElse: () => AppVisualStyle.custom,
  );
}

AppVisualStyle _inferVisualStyle(int background, int accent) {
  const signatures = <(int, int), AppVisualStyle>{
    (0xFF070907, 0xFFB7FF00): AppVisualStyle.custom,
    (0xFF070707, 0xFFD8A62A): AppVisualStyle.elegant,
    (0xFFF3F6FA, 0xFF1976F3): AppVisualStyle.modern,
    (0xFF020817, 0xFF00E7FF): AppVisualStyle.neon,
    (0xFFE8F8F4, 0xFFFF7A1A): AppVisualStyle.tropical,
    (0xFF171513, 0xFFE88719): AppVisualStyle.industrial,
    (0xFFF0DFC0, 0xFF7A3F12): AppVisualStyle.vintage,
  };
  return signatures[(background, accent)] ?? AppVisualStyle.custom;
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
    this.visualStyle = AppVisualStyle.custom,
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
  final AppVisualStyle visualStyle;

  factory AppColorThemeConfig.defaults() => const AppColorThemeConfig(
        // V20 Standard / Benutzerdefiniert: Black / Lime
        // Bewusst ohne speziellen Hintergrund oder Textur.
        background: 0xFF070907,
        surface: 0xFF0B0E0B,
        card: 0xFF101410,
        navigation: 0xFF050705,
        accent: 0xFFB7FF00,
        secondaryAccent: 0xFF7DFF00,
        border: 0xFF33451F,
        textPrimary: 0xFFF4F7F2,
        textSecondary: 0xFFAEB7AA,
        progressTrack: 0xFF1E2A17,
        success: 0xFF68E28D,
        warning: 0xFFFFB300,
        error: 0xFFFF3B30,
        visualStyle: AppVisualStyle.custom,
      );

  factory AppColorThemeConfig.fromJson(Map<String, dynamic> json) {
    final defaults = AppColorThemeConfig.defaults();

    int value(String key, int fallback) =>
        (json[key] as num?)?.toInt() ?? fallback;

    final background = value('background', defaults.background);
    final accent = value('accent', defaults.accent);
    final savedStyle = json['visualStyle'] as String?;
    final visualStyle = savedStyle == null
        ? _inferVisualStyle(background, accent)
        : _appVisualStyleFromStorage(savedStyle);

    return AppColorThemeConfig(
      background: background,
      surface: value('surface', defaults.surface),
      card: value('card', defaults.card),
      navigation: value('navigation', defaults.navigation),
      accent: accent,
      secondaryAccent:
          value('secondaryAccent', defaults.secondaryAccent),
      border: value('border', defaults.border),
      textPrimary: value('textPrimary', defaults.textPrimary),
      textSecondary: value('textSecondary', defaults.textSecondary),
      progressTrack: value('progressTrack', defaults.progressTrack),
      success: value('success', defaults.success),
      warning: value('warning', defaults.warning),
      error: value('error', defaults.error),
      visualStyle: visualStyle,
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
        'visualStyle': visualStyle.storageValue,
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
  Color get navigationTextColor => navigationColor.computeLuminance() > .48
      ? const Color(0xFF17202A)
      : const Color(0xFFF7FAFC);
  Color get navigationSecondaryTextColor =>
      Color.lerp(navigationTextColor, navigationColor, .34)!;

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
      visualStyle: visualStyle,
    );
  }
}

bool _isLegacyDesignPreset(AppColorThemeConfig colors) {
  const legacySignatures = <(int, int)>{
    (0xFF07111A, 0xFF14B8A6),
    (0xFF0D1117, 0xFFD84C7F),
    (0xFFF6F1E9, 0xFFCB9B3E),
    (0xFFF4F8FA, 0xFF16C2BE),
    (0xFF061225, 0xFF4EA8DE),
    (0xFFF5F2FA, 0xFF8B7FD6),
  };
  return legacySignatures.contains((colors.background, colors.accent));
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
    'Hinweise für die Zubereitung': {AppLanguage.de: 'Hinweise für die Zubereitung', AppLanguage.en: 'Preparation notes', AppLanguage.es: 'Notas de preparación', AppLanguage.it: 'Note di preparazione', AppLanguage.nl: 'Bereidingsnotities', AppLanguage.fr: 'Notes de préparation', AppLanguage.pt: 'Notas de preparação', AppLanguage.pl: 'Uwagi do przygotowania', AppLanguage.tr: 'Hazırlama notları', AppLanguage.ru: 'Примечания к приготовлению'},
    'Ein Hinweis pro Zeile. Zum Beispiel: Frische Minze hinzufügen oder Limettenstücke ins Glas geben.': {AppLanguage.de: 'Ein Hinweis pro Zeile. Zum Beispiel: Frische Minze hinzufügen oder Limettenstücke ins Glas geben.', AppLanguage.en: 'One note per line. For example: Add fresh mint or add lime pieces to the glass.', AppLanguage.es: 'Una nota por línea. Por ejemplo: Añadir menta fresca o trozos de lima al vaso.', AppLanguage.it: 'Una nota per riga. Ad esempio: Aggiungere menta fresca o pezzi di lime nel bicchiere.', AppLanguage.nl: 'Eén opmerking per regel. Bijvoorbeeld: Verse munt toevoegen of stukjes limoen in het glas doen.', AppLanguage.fr: 'Une note par ligne. Par exemple : ajouter de la menthe fraîche ou des morceaux de citron vert dans le verre.', AppLanguage.pt: 'Uma nota por linha. Por exemplo: Adicionar hortelã fresca ou pedaços de lima ao copo.', AppLanguage.pl: 'Jedna uwaga w każdym wierszu. Na przykład: dodać świeżą miętę lub kawałki limonki do szklanki.', AppLanguage.tr: 'Her satıra bir not. Örneğin: Taze nane ekleyin veya bardağa lime parçaları koyun.', AppLanguage.ru: 'Одна подсказка на строку. Например: добавить свежую мяту или кусочки лайма в стакан.'},
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
    'Mehrere Größen können gleichzeitig aktiviert werden. Die Standardgröße ist beim Öffnen eines Cocktails vorausgewählt.': {AppLanguage.de: 'Mehrere Größen können gleichzeitig aktiviert werden. Die Standardgröße ist beim Öffnen eines Cocktails vorausgewählt.', AppLanguage.en: 'Multiple sizes can be enabled at the same time. The default size is preselected when a drink is opened.', AppLanguage.es: 'Se pueden activar varios tamaños al mismo tiempo. El tamaño predeterminado aparece preseleccionado al abrir una bebida.', AppLanguage.it: 'È possibile attivare più dimensioni contemporaneamente. La dimensione predefinita viene preselezionata quando si apre una bevanda.', AppLanguage.nl: 'Meerdere formaten kunnen tegelijk worden ingeschakeld. Het standaardformaat is vooraf geselecteerd wanneer een drankje wordt geopend.', AppLanguage.fr: 'Plusieurs tailles peuvent être activées en même temps. La taille par défaut est présélectionnée à l’ouverture d’une boisson.', AppLanguage.pt: 'Vários tamanhos podem ser ativados ao mesmo tempo. O tamanho padrão fica pré-selecionado ao abrir uma bebida.', AppLanguage.pl: 'Można włączyć kilka rozmiarów jednocześnie. Domyślny rozmiar jest wstępnie wybrany po otwarciu napoju.', AppLanguage.tr: 'Birden fazla boyut aynı anda etkinleştirilebilir. Bir içecek açıldığında varsayılan boyut önceden seçilir.', AppLanguage.ru: 'Можно одновременно включить несколько размеров. При открытии напитка стандартный размер выбирается заранее.'},
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
    'Bild im Dateibrowser auswählen': {AppLanguage.de: 'Bild im Dateibrowser auswählen', AppLanguage.en: 'Select image in file browser', AppLanguage.es: 'Seleccionar imagen en el explorador de archivos', AppLanguage.it: 'Seleziona immagine nel file manager', AppLanguage.nl: 'Afbeelding kiezen in bestandsbrowser', AppLanguage.fr: 'Choisir une image dans le navigateur de fichiers', AppLanguage.pt: 'Selecionar imagem no navegador de arquivos', AppLanguage.pl: 'Wybierz obraz w przeglądarce plików', AppLanguage.tr: 'Dosya tarayıcısında resim seç', AppLanguage.ru: 'Выбрать изображение в файловом браузере'},
    'Bild vom USB-Stick auswählen': {AppLanguage.de: 'Bild vom USB-Stick auswählen', AppLanguage.en: 'Select image from USB drive', AppLanguage.es: 'Seleccionar imagen del USB', AppLanguage.it: 'Seleziona immagine da USB', AppLanguage.nl: 'Afbeelding van USB kiezen', AppLanguage.fr: 'Choisir une image sur la clé USB', AppLanguage.pt: 'Selecionar imagem do USB', AppLanguage.pl: 'Wybierz obraz z USB', AppLanguage.tr: 'USB bellekte resim seç', AppLanguage.ru: 'Выбрать изображение с USB'},
    'USB-Bilder': {AppLanguage.de: 'USB-Bilder', AppLanguage.en: 'USB images', AppLanguage.es: 'Imágenes USB', AppLanguage.it: 'Immagini USB', AppLanguage.nl: 'USB-afbeeldingen', AppLanguage.fr: 'Images USB', AppLanguage.pt: 'Imagens USB', AppLanguage.pl: 'Obrazy USB', AppLanguage.tr: 'USB resimleri', AppLanguage.ru: 'Изображения USB'},
    'USB-Stick einstecken und neu laden.': {AppLanguage.de: 'USB-Stick einstecken und neu laden.', AppLanguage.en: 'Insert a USB drive and refresh.', AppLanguage.es: 'Inserta una memoria USB y actualiza.', AppLanguage.it: 'Inserisci una chiavetta USB e aggiorna.', AppLanguage.nl: 'Plaats een USB-stick en vernieuw.', AppLanguage.fr: 'Insérez une clé USB puis actualisez.', AppLanguage.pt: 'Insira um dispositivo USB e atualize.', AppLanguage.pl: 'Włóż pamięć USB i odśwież.', AppLanguage.tr: 'USB belleği takın ve yenileyin.', AppLanguage.ru: 'Вставьте USB-накопитель и обновите.'},
    'Keine Bilder auf dem USB-Stick gefunden.': {AppLanguage.de: 'Keine Bilder auf dem USB-Stick gefunden.', AppLanguage.en: 'No images found on the USB drive.', AppLanguage.es: 'No se encontraron imágenes en el USB.', AppLanguage.it: 'Nessuna immagine trovata sull’USB.', AppLanguage.nl: 'Geen afbeeldingen op de USB-stick gevonden.', AppLanguage.fr: 'Aucune image trouvée sur la clé USB.', AppLanguage.pt: 'Nenhuma imagem encontrada no USB.', AppLanguage.pl: 'Nie znaleziono obrazów na USB.', AppLanguage.tr: 'USB bellekte resim bulunamadı.', AppLanguage.ru: 'На USB-накопителе нет изображений.'},
    'Unterstützt werden JPG, PNG und WebP.': {AppLanguage.de: 'Unterstützt werden JPG, PNG und WebP.', AppLanguage.en: 'JPG, PNG and WebP are supported.', AppLanguage.es: 'Se admiten JPG, PNG y WebP.', AppLanguage.it: 'Sono supportati JPG, PNG e WebP.', AppLanguage.nl: 'JPG, PNG en WebP worden ondersteund.', AppLanguage.fr: 'JPG, PNG et WebP sont pris en charge.', AppLanguage.pt: 'JPG, PNG e WebP são suportados.', AppLanguage.pl: 'Obsługiwane są JPG, PNG i WebP.', AppLanguage.tr: 'JPG, PNG ve WebP desteklenir.', AppLanguage.ru: 'Поддерживаются JPG, PNG и WebP.'},
    'Neu laden': {AppLanguage.de: 'Neu laden', AppLanguage.en: 'Refresh', AppLanguage.es: 'Actualizar', AppLanguage.it: 'Aggiorna', AppLanguage.nl: 'Vernieuwen', AppLanguage.fr: 'Actualiser', AppLanguage.pt: 'Atualizar', AppLanguage.pl: 'Odśwież', AppLanguage.tr: 'Yenile', AppLanguage.ru: 'Обновить'},
    'Bild konnte nicht geladen werden': {AppLanguage.de: 'Bild konnte nicht geladen werden', AppLanguage.en: 'Image could not be loaded', AppLanguage.es: 'No se pudo cargar la imagen', AppLanguage.it: 'Impossibile caricare l’immagine', AppLanguage.nl: 'Afbeelding kon niet worden geladen', AppLanguage.fr: 'Impossible de charger l’image', AppLanguage.pt: 'Não foi possível carregar a imagem', AppLanguage.pl: 'Nie udało się wczytać obrazu', AppLanguage.tr: 'Resim yüklenemedi', AppLanguage.ru: 'Не удалось загрузить изображение'},
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
  final settingsSupplementalTexts = <String, Map<AppLanguage, String>>{
    'Weniger': {
      AppLanguage.de: 'Weniger',
      AppLanguage.en: 'Less',
      AppLanguage.es: 'Menos',
      AppLanguage.it: 'Meno',
      AppLanguage.nl: 'Minder',
      AppLanguage.fr: 'Moins',
      AppLanguage.pt: 'Menos',
      AppLanguage.pl: 'Mniej',
      AppLanguage.tr: 'Daha az',
      AppLanguage.ru: 'Меньше',
    },
    'Mehr': {
      AppLanguage.de: 'Mehr',
      AppLanguage.en: 'More',
      AppLanguage.es: 'Más',
      AppLanguage.it: 'Più',
      AppLanguage.nl: 'Meer',
      AppLanguage.fr: 'Plus',
      AppLanguage.pt: 'Mais',
      AppLanguage.pl: 'Więcej',
      AppLanguage.tr: 'Daha fazla',
      AppLanguage.ru: 'Больше',
    },
    'Warnschwellen': {
      AppLanguage.de: 'Warnschwellen',
      AppLanguage.en: 'Warning thresholds',
      AppLanguage.es: 'Umbrales de aviso',
      AppLanguage.it: 'Soglie di avviso',
      AppLanguage.nl: 'Waarschuwingsdrempels',
      AppLanguage.fr: 'Seuils d’alerte',
      AppLanguage.pt: 'Limites de aviso',
      AppLanguage.pl: 'Progi ostrzegawcze',
      AppLanguage.tr: 'Uyarı eşikleri',
      AppLanguage.ru: 'Пороги предупреждений',
    },
    'Cocktailkarte orange ab': {
      AppLanguage.de: 'Cocktailkarte orange ab',
      AppLanguage.en: 'Cocktail card orange at',
      AppLanguage.es: 'Tarjeta naranja a partir de',
      AppLanguage.it: 'Scheda cocktail arancione da',
      AppLanguage.nl: 'Cocktailkaart oranje vanaf',
      AppLanguage.fr: 'Carte cocktail orange à partir de',
      AppLanguage.pt: 'Cartão do coquetel laranja a partir de',
      AppLanguage.pl: 'Pomarańczowa karta koktajlu od',
      AppLanguage.tr: 'Kokteyl kartı turuncu eşiği',
      AppLanguage.ru: 'Оранжевая карточка коктейля при',
    },
    'Restcocktails': {
      AppLanguage.de: 'Restcocktails',
      AppLanguage.en: 'cocktails remaining',
      AppLanguage.es: 'cócteles restantes',
      AppLanguage.it: 'cocktail rimanenti',
      AppLanguage.nl: 'cocktails resterend',
      AppLanguage.fr: 'cocktails restants',
      AppLanguage.pt: 'coquetéis restantes',
      AppLanguage.pl: 'pozostałych koktajlach',
      AppLanguage.tr: 'kalan kokteyl',
      AppLanguage.ru: 'оставшихся коктейлях',
    },
    'Füllstandsseite orange unter': {
      AppLanguage.de: 'Füllstandsseite orange unter',
      AppLanguage.en: 'Fill-level page orange below',
      AppLanguage.es: 'Página de niveles naranja por debajo de',
      AppLanguage.it: 'Pagina livelli arancione sotto',
      AppLanguage.nl: 'Vulniveaupagina oranje onder',
      AppLanguage.fr: 'Page des niveaux orange sous',
      AppLanguage.pt: 'Página de níveis laranja abaixo de',
      AppLanguage.pl: 'Strona poziomów pomarańczowa poniżej',
      AppLanguage.tr: 'Doluluk sayfası turuncu alt sınırı',
      AppLanguage.ru: 'Страница уровней оранжевая ниже',
    },
    'Diese Werte bestimmen nur die Warnanzeige. Die tatsächliche Verfügbarkeit wird weiterhin aus der benötigten Rezeptmenge berechnet.': {
      AppLanguage.de: 'Diese Werte bestimmen nur die Warnanzeige. Die tatsächliche Verfügbarkeit wird weiterhin aus der benötigten Rezeptmenge berechnet.',
      AppLanguage.en: 'These values only control the warning display. Actual availability is still calculated from the recipe amount required.',
      AppLanguage.es: 'Estos valores solo controlan el aviso. La disponibilidad real se sigue calculando según la cantidad necesaria de la receta.',
      AppLanguage.it: 'Questi valori controllano solo l’avviso. La disponibilità reale continua a essere calcolata dalla quantità richiesta dalla ricetta.',
      AppLanguage.nl: 'Deze waarden bepalen alleen de waarschuwing. De werkelijke beschikbaarheid wordt nog steeds berekend uit de benodigde recepthoeveelheid.',
      AppLanguage.fr: 'Ces valeurs règlent uniquement l’alerte. La disponibilité réelle reste calculée selon la quantité requise par la recette.',
      AppLanguage.pt: 'Estes valores controlam apenas o aviso. A disponibilidade real continua sendo calculada pela quantidade exigida pela receita.',
      AppLanguage.pl: 'Te wartości sterują tylko ostrzeżeniem. Rzeczywista dostępność nadal jest obliczana na podstawie wymaganej ilości z przepisu.',
      AppLanguage.tr: 'Bu değerler yalnızca uyarı görünümünü belirler. Gerçek kullanılabilirlik tarif için gereken miktara göre hesaplanmaya devam eder.',
      AppLanguage.ru: 'Эти значения управляют только предупреждением. Фактическая доступность по-прежнему рассчитывается по требуемому объёму рецепта.',
    },
    'Sicherheit & Freigaben': {
      AppLanguage.de: 'Sicherheit & Freigaben',
      AppLanguage.en: 'Security & permissions',
      AppLanguage.es: 'Seguridad y permisos',
      AppLanguage.it: 'Sicurezza e autorizzazioni',
      AppLanguage.nl: 'Beveiliging en rechten',
      AppLanguage.fr: 'Sécurité et autorisations',
      AppLanguage.pt: 'Segurança e permissões',
      AppLanguage.pl: 'Bezpieczeństwo i uprawnienia',
      AppLanguage.tr: 'Güvenlik ve izinler',
      AppLanguage.ru: 'Безопасность и разрешения',
    },
    'Stärkeregler und Einstellungs-Passwort': {
      AppLanguage.de: 'Stärkeregler und Einstellungs-Passwort',
      AppLanguage.en: 'Strength control and settings password',
      AppLanguage.es: 'Control de intensidad y contraseña de ajustes',
      AppLanguage.it: 'Controllo intensità e password impostazioni',
      AppLanguage.nl: 'Sterkteregeling en instellingenwachtwoord',
      AppLanguage.fr: 'Réglage de l’intensité et mot de passe',
      AppLanguage.pt: 'Controle de intensidade e senha das configurações',
      AppLanguage.pl: 'Regulacja mocy i hasło ustawień',
      AppLanguage.tr: 'Yoğunluk kontrolü ve ayarlar parolası',
      AppLanguage.ru: 'Регулировка крепости и пароль настроек',
    },
    'Sortierung und Cocktails pro Seite einstellen': {
      AppLanguage.de: 'Sortierung und Cocktails pro Seite einstellen',
      AppLanguage.en: 'Configure sorting and cocktails per page',
      AppLanguage.es: 'Configurar orden y cócteles por página',
      AppLanguage.it: 'Configura ordinamento e cocktail per pagina',
      AppLanguage.nl: 'Sortering en cocktails per pagina instellen',
      AppLanguage.fr: 'Configurer le tri et les cocktails par page',
      AppLanguage.pt: 'Configurar ordenação e coquetéis por página',
      AppLanguage.pl: 'Ustaw sortowanie i koktajle na stronę',
      AppLanguage.tr: 'Sıralama ve sayfa başına kokteyl ayarla',
      AppLanguage.ru: 'Настроить сортировку и коктейли на странице',
    },
    'Gewerbelizenz': {
      AppLanguage.de: 'Gewerbelizenz',
      AppLanguage.en: 'Commercial license',
      AppLanguage.es: 'Licencia comercial',
      AppLanguage.it: 'Licenza commerciale',
      AppLanguage.nl: 'Commerciële licentie',
      AppLanguage.fr: 'Licence commerciale',
      AppLanguage.pt: 'Licença comercial',
      AppLanguage.pl: 'Licencja komercyjna',
      AppLanguage.tr: 'Ticari lisans',
      AppLanguage.ru: 'Коммерческая лицензия',
    },
    'Gewerbelizenz erforderlich': {
      AppLanguage.de: 'Gewerbelizenz erforderlich',
      AppLanguage.en: 'Commercial license required',
      AppLanguage.es: 'Se requiere licencia comercial',
      AppLanguage.it: 'Licenza commerciale richiesta',
      AppLanguage.nl: 'Commerciële licentie vereist',
      AppLanguage.fr: 'Licence commerciale requise',
      AppLanguage.pt: 'Licença comercial necessária',
      AppLanguage.pl: 'Wymagana licencja komercyjna',
      AppLanguage.tr: 'Ticari lisans gerekli',
      AppLanguage.ru: 'Требуется коммерческая лицензия',
    },
    'Gewerbelizenz aktiv': {
      AppLanguage.de: 'Gewerbelizenz aktiv',
      AppLanguage.en: 'Commercial license active',
      AppLanguage.es: 'Licencia comercial activa',
      AppLanguage.it: 'Licenza commerciale attiva',
      AppLanguage.nl: 'Commerciële licentie actief',
      AppLanguage.fr: 'Licence commerciale active',
      AppLanguage.pt: 'Licença comercial ativa',
      AppLanguage.pl: 'Licencja komercyjna aktywna',
      AppLanguage.tr: 'Ticari lisans etkin',
      AppLanguage.ru: 'Коммерческая лицензия активна',
    },
    'Privatmodus': {
      AppLanguage.de: 'Privatmodus',
      AppLanguage.en: 'Private mode',
      AppLanguage.es: 'Modo privado',
      AppLanguage.it: 'Modalità privata',
      AppLanguage.nl: 'Privémodus',
      AppLanguage.fr: 'Mode privé',
      AppLanguage.pt: 'Modo privado',
      AppLanguage.pl: 'Tryb prywatny',
      AppLanguage.tr: 'Özel mod',
      AppLanguage.ru: 'Частный режим',
    },
    'Privatmodus aktiv': {
      AppLanguage.de: 'Privatmodus aktiv',
      AppLanguage.en: 'Private mode active',
      AppLanguage.es: 'Modo privado activo',
      AppLanguage.it: 'Modalità privata attiva',
      AppLanguage.nl: 'Privémodus actief',
      AppLanguage.fr: 'Mode privé actif',
      AppLanguage.pt: 'Modo privado ativo',
      AppLanguage.pl: 'Tryb prywatny aktywny',
      AppLanguage.tr: 'Özel mod etkin',
      AppLanguage.ru: 'Частный режим активен',
    },
    'Verbrauchsstatistik': {
      AppLanguage.de: 'Verbrauchsstatistik',
      AppLanguage.en: 'Consumption statistics',
      AppLanguage.es: 'Estadísticas de consumo',
      AppLanguage.it: 'Statistiche di consumo',
      AppLanguage.nl: 'Verbruiksstatistieken',
      AppLanguage.fr: 'Statistiques de consommation',
      AppLanguage.pt: 'Estatísticas de consumo',
      AppLanguage.pl: 'Statystyki zużycia',
      AppLanguage.tr: 'Tüketim istatistikleri',
      AppLanguage.ru: 'Статистика расхода',
    },
    'Cocktail-Ranking, Kosten und Zutatenverbrauch': {
      AppLanguage.de: 'Cocktail-Ranking, Kosten und Zutatenverbrauch',
      AppLanguage.en: 'Cocktail ranking, costs and ingredient consumption',
      AppLanguage.es: 'Ranking de cócteles, costes y consumo de ingredientes',
      AppLanguage.it: 'Classifica cocktail, costi e consumo ingredienti',
      AppLanguage.nl: 'Cocktailranglijst, kosten en ingrediëntenverbruik',
      AppLanguage.fr: 'Classement des cocktails, coûts et consommation d’ingrédients',
      AppLanguage.pt: 'Ranking de coquetéis, custos e consumo de ingredientes',
      AppLanguage.pl: 'Ranking koktajli, koszty i zużycie składników',
      AppLanguage.tr: 'Kokteyl sıralaması, maliyetler ve malzeme tüketimi',
      AppLanguage.ru: 'Рейтинг коктейлей, расходы и расход ингредиентов',
    },
    'Partykarten': {
      AppLanguage.de: 'Partykarten',
      AppLanguage.en: 'Party cards',
      AppLanguage.es: 'Tarjetas de fiesta',
      AppLanguage.it: 'Schede festa',
      AppLanguage.nl: 'Partykaarten',
      AppLanguage.fr: 'Cartes de fête',
      AppLanguage.pt: 'Cartões de festa',
      AppLanguage.pl: 'Karty imprezowe',
      AppLanguage.tr: 'Parti kartları',
      AppLanguage.ru: 'Карты вечеринок',
    },
    'Auswahl und Beliebtheit für Veranstaltungen': {
      AppLanguage.de: 'Auswahl und Beliebtheit für Veranstaltungen',
      AppLanguage.en: 'Selection and popularity for events',
      AppLanguage.es: 'Selección y popularidad para eventos',
      AppLanguage.it: 'Selezione e popolarità per eventi',
      AppLanguage.nl: 'Selectie en populariteit voor evenementen',
      AppLanguage.fr: 'Sélection et popularité pour les événements',
      AppLanguage.pt: 'Seleção e popularidade para eventos',
      AppLanguage.pl: 'Wybór i popularność na wydarzenia',
      AppLanguage.tr: 'Etkinlikler için seçim ve popülerlik',
      AppLanguage.ru: 'Выбор и популярность для мероприятий',
    },
    'Partyplaner': {
      AppLanguage.de: 'Partyplaner',
      AppLanguage.en: 'Party planner',
      AppLanguage.es: 'Planificador de fiestas',
      AppLanguage.it: 'Pianificatore feste',
      AppLanguage.nl: 'Partyplanner',
      AppLanguage.fr: 'Planificateur de fête',
      AppLanguage.pt: 'Planejador de festas',
      AppLanguage.pl: 'Planer imprezy',
      AppLanguage.tr: 'Parti planlayıcı',
      AppLanguage.ru: 'Планировщик вечеринки',
    },
    'Prognose aus vergangenen Partys': {
      AppLanguage.de: 'Prognose aus vergangenen Partys',
      AppLanguage.en: 'Forecast based on past parties',
      AppLanguage.es: 'Previsión basada en fiestas anteriores',
      AppLanguage.it: 'Previsione basata sulle feste passate',
      AppLanguage.nl: 'Prognose op basis van eerdere feesten',
      AppLanguage.fr: 'Prévision basée sur les fêtes passées',
      AppLanguage.pt: 'Previsão com base em festas anteriores',
      AppLanguage.pl: 'Prognoza na podstawie wcześniejszych imprez',
      AppLanguage.tr: 'Geçmiş partilere dayalı tahmin',
      AppLanguage.ru: 'Прогноз на основе прошлых вечеринок',
    },
    'Einkaufsliste': {
      AppLanguage.de: 'Einkaufsliste',
      AppLanguage.en: 'Shopping list',
      AppLanguage.es: 'Lista de compras',
      AppLanguage.it: 'Lista della spesa',
      AppLanguage.nl: 'Boodschappenlijst',
      AppLanguage.fr: 'Liste de courses',
      AppLanguage.pt: 'Lista de compras',
      AppLanguage.pl: 'Lista zakupów',
      AppLanguage.tr: 'Alışveriş listesi',
      AppLanguage.ru: 'Список покупок',
    },
    'Zutatenbedarf und fehlende Mengen planen': {
      AppLanguage.de: 'Zutatenbedarf und fehlende Mengen planen',
      AppLanguage.en: 'Plan ingredient requirements and missing quantities',
      AppLanguage.es: 'Planificar ingredientes necesarios y cantidades faltantes',
      AppLanguage.it: 'Pianifica ingredienti necessari e quantità mancanti',
      AppLanguage.nl: 'Benodigde ingrediënten en ontbrekende hoeveelheden plannen',
      AppLanguage.fr: 'Planifier les besoins en ingrédients et les quantités manquantes',
      AppLanguage.pt: 'Planejar ingredientes necessários e quantidades em falta',
      AppLanguage.pl: 'Zaplanuj zapotrzebowanie na składniki i brakujące ilości',
      AppLanguage.tr: 'Malzeme ihtiyacını ve eksik miktarları planla',
      AppLanguage.ru: 'Планировать потребность в ингредиентах и недостающие количества',
    },
    'Hinweis zur Lernphase': {
      AppLanguage.de: 'Hinweis zur Lernphase',
      AppLanguage.en: 'Learning phase notice',
      AppLanguage.es: 'Aviso de fase de aprendizaje',
      AppLanguage.it: 'Avviso sulla fase di apprendimento',
      AppLanguage.nl: 'Melding leerfase',
      AppLanguage.fr: 'Information sur la phase d’apprentissage',
      AppLanguage.pt: 'Aviso sobre a fase de aprendizagem',
      AppLanguage.pl: 'Informacja o fazie uczenia',
      AppLanguage.tr: 'Öğrenme aşaması bilgisi',
      AppLanguage.ru: 'Информация об этапе обучения',
    },
    'Partyplaner und Einkaufsliste lernen aus abgeschlossenen Partys. Aussagekräftige Ergebnisse entstehen erst nach mehreren Partys mit derselben Partykarte. Bis dahin sind die Werte nur Schätzungen.': {
      AppLanguage.de: 'Partyplaner und Einkaufsliste lernen aus abgeschlossenen Partys. Aussagekräftige Ergebnisse entstehen erst nach mehreren Partys mit derselben Partykarte. Bis dahin sind die Werte nur Schätzungen.',
      AppLanguage.en: 'The party planner and shopping list learn from completed parties. Meaningful results only emerge after several parties with the same party card. Until then, the values are estimates.',
      AppLanguage.es: 'El planificador de fiestas y la lista de compras aprenden de fiestas finalizadas. Los resultados fiables aparecen tras varias fiestas con la misma tarjeta. Hasta entonces, los valores son estimaciones.',
      AppLanguage.it: 'Il pianificatore feste e la lista della spesa apprendono dalle feste concluse. Risultati attendibili emergono solo dopo più feste con la stessa scheda. Fino ad allora i valori sono stime.',
      AppLanguage.nl: 'De partyplanner en boodschappenlijst leren van afgeronde feesten. Betrouwbare resultaten ontstaan pas na meerdere feesten met dezelfde partykaart. Tot die tijd zijn de waarden schattingen.',
      AppLanguage.fr: 'Le planificateur de fête et la liste de courses apprennent à partir des fêtes terminées. Des résultats fiables n’apparaissent qu’après plusieurs fêtes avec la même carte. D’ici là, les valeurs sont des estimations.',
      AppLanguage.pt: 'O planejador de festas e a lista de compras aprendem com festas concluídas. Resultados confiáveis só aparecem após várias festas com o mesmo cartão. Até lá, os valores são estimativas.',
      AppLanguage.pl: 'Planer imprezy i lista zakupów uczą się na podstawie zakończonych imprez. Wiarygodne wyniki pojawiają się dopiero po kilku imprezach z tą samą kartą. Do tego czasu wartości są szacunkowe.',
      AppLanguage.tr: 'Parti planlayıcı ve alışveriş listesi tamamlanan partilerden öğrenir. Anlamlı sonuçlar aynı parti kartıyla birkaç partiden sonra oluşur. O zamana kadar değerler tahmindir.',
      AppLanguage.ru: 'Планировщик вечеринки и список покупок обучаются на завершённых вечеринках. Достоверные результаты появляются только после нескольких вечеринок с одной и той же картой. До этого значения являются оценочными.',
    },
    'Bestand für Einkaufsliste': {
      AppLanguage.de: 'Bestand für Einkaufsliste',
      AppLanguage.en: 'Inventory for shopping list',
      AppLanguage.es: 'Existencias para la lista de compras',
      AppLanguage.it: 'Scorte per la lista della spesa',
      AppLanguage.nl: 'Voorraad voor boodschappenlijst',
      AppLanguage.fr: 'Stock pour la liste de courses',
      AppLanguage.pt: 'Estoque para a lista de compras',
      AppLanguage.pl: 'Stan magazynowy do listy zakupów',
      AppLanguage.tr: 'Alışveriş listesi stoğu',
      AppLanguage.ru: 'Запасы для списка покупок',
    },
    'Trage deinen aktuellen Bestand einmal ein. Nach jeder erfolgreichen Zubereitung werden die verwendeten Zutaten automatisch abgezogen. Leere Felder bleiben unbekannt; dann wird der komplette geplante Bedarf als Einkaufsmenge angezeigt.': {
      AppLanguage.de: 'Trage deinen aktuellen Bestand einmal ein. Nach jeder erfolgreichen Zubereitung werden die verwendeten Zutaten automatisch abgezogen. Leere Felder bleiben unbekannt; dann wird der komplette geplante Bedarf als Einkaufsmenge angezeigt.',
      AppLanguage.en: 'Enter your current inventory once. After every successful preparation, the used ingredients are deducted automatically. Empty fields remain unknown; in that case the full planned requirement is shown as the amount to buy.',
      AppLanguage.es: 'Introduce una vez tus existencias actuales. Después de cada preparación correcta, los ingredientes usados se descuentan automáticamente. Los campos vacíos quedan como desconocidos; en ese caso se muestra toda la necesidad planificada como cantidad a comprar.',
      AppLanguage.it: 'Inserisci una volta le scorte attuali. Dopo ogni preparazione riuscita, gli ingredienti utilizzati vengono sottratti automaticamente. I campi vuoti restano sconosciuti; in tal caso l’intero fabbisogno pianificato viene mostrato come quantità da acquistare.',
      AppLanguage.nl: 'Voer je huidige voorraad één keer in. Na elke geslaagde bereiding worden de gebruikte ingrediënten automatisch afgetrokken. Lege velden blijven onbekend; dan wordt de volledige geplande behoefte als inkoophoeveelheid getoond.',
      AppLanguage.fr: 'Saisis une fois ton stock actuel. Après chaque préparation réussie, les ingrédients utilisés sont déduits automatiquement. Les champs vides restent inconnus ; dans ce cas, le besoin planifié complet est affiché comme quantité à acheter.',
      AppLanguage.pt: 'Insira uma vez o estoque atual. Após cada preparo concluído, os ingredientes usados são descontados automaticamente. Campos vazios permanecem desconhecidos; nesse caso, toda a necessidade planejada é mostrada como quantidade a comprar.',
      AppLanguage.pl: 'Wprowadź raz aktualny stan magazynowy. Po każdym udanym przygotowaniu zużyte składniki są automatycznie odejmowane. Puste pola pozostają nieznane; wtedy całe planowane zapotrzebowanie jest pokazane jako ilość do zakupu.',
      AppLanguage.tr: 'Mevcut stoğunu bir kez gir. Her başarılı hazırlamadan sonra kullanılan malzemeler otomatik olarak düşülür. Boş alanlar bilinmiyor olarak kalır; bu durumda planlanan ihtiyacın tamamı satın alınacak miktar olarak gösterilir.',
      AppLanguage.ru: 'Введите текущий запас один раз. После каждого успешного приготовления использованные ингредиенты автоматически списываются. Пустые поля считаются неизвестными; в этом случае весь планируемый объём показывается как количество для покупки.',
    },
    'Bestand (ml)': {
      AppLanguage.de: 'Bestand (ml)', AppLanguage.en: 'Inventory (ml)', AppLanguage.es: 'Existencias (ml)', AppLanguage.it: 'Scorte (ml)', AppLanguage.nl: 'Voorraad (ml)', AppLanguage.fr: 'Stock (ml)', AppLanguage.pt: 'Estoque (ml)', AppLanguage.pl: 'Stan (ml)', AppLanguage.tr: 'Stok (ml)', AppLanguage.ru: 'Запас (мл)',
    },
    'Bestand speichern': {
      AppLanguage.de: 'Bestand speichern', AppLanguage.en: 'Save inventory', AppLanguage.es: 'Guardar existencias', AppLanguage.it: 'Salva scorte', AppLanguage.nl: 'Voorraad opslaan', AppLanguage.fr: 'Enregistrer le stock', AppLanguage.pt: 'Salvar estoque', AppLanguage.pl: 'Zapisz stan', AppLanguage.tr: 'Stoğu kaydet', AppLanguage.ru: 'Сохранить запас',
    },
    'Bestand gespeichert': {
      AppLanguage.de: 'Bestand gespeichert', AppLanguage.en: 'Inventory saved', AppLanguage.es: 'Existencias guardadas', AppLanguage.it: 'Scorte salvate', AppLanguage.nl: 'Voorraad opgeslagen', AppLanguage.fr: 'Stock enregistré', AppLanguage.pt: 'Estoque salvo', AppLanguage.pl: 'Stan zapisany', AppLanguage.tr: 'Stok kaydedildi', AppLanguage.ru: 'Запас сохранён',
    },
    'nicht eingetragen': {
      AppLanguage.de: 'nicht eingetragen', AppLanguage.en: 'not entered', AppLanguage.es: 'no indicado', AppLanguage.it: 'non inserito', AppLanguage.nl: 'niet ingevuld', AppLanguage.fr: 'non renseigné', AppLanguage.pt: 'não informado', AppLanguage.pl: 'nie wpisano', AppLanguage.tr: 'girilmedi', AppLanguage.ru: 'не указан',
    },
    'Bedarf': {
      AppLanguage.de: 'Bedarf', AppLanguage.en: 'Required', AppLanguage.es: 'Necesario', AppLanguage.it: 'Fabbisogno', AppLanguage.nl: 'Benodigd', AppLanguage.fr: 'Besoin', AppLanguage.pt: 'Necessário', AppLanguage.pl: 'Zapotrzebowanie', AppLanguage.tr: 'İhtiyaç', AppLanguage.ru: 'Требуется',
    },
    'Einkaufen': {
      AppLanguage.de: 'Einkaufen', AppLanguage.en: 'Buy', AppLanguage.es: 'Comprar', AppLanguage.it: 'Acquistare', AppLanguage.nl: 'Inkopen', AppLanguage.fr: 'Acheter', AppLanguage.pt: 'Comprar', AppLanguage.pl: 'Kupić', AppLanguage.tr: 'Satın al', AppLanguage.ru: 'Купить',
    },
    'PayPal Kassenmodus': {
      AppLanguage.de: 'PayPal Kassenmodus',
      AppLanguage.en: 'PayPal checkout mode',
      AppLanguage.es: 'Modo de caja PayPal',
      AppLanguage.it: 'Modalità cassa PayPal',
      AppLanguage.nl: 'PayPal-kassamodus',
      AppLanguage.fr: 'Mode caisse PayPal',
      AppLanguage.pt: 'Modo de caixa PayPal',
      AppLanguage.pl: 'Tryb kasy PayPal',
      AppLanguage.tr: 'PayPal kasa modu',
      AppLanguage.ru: 'Режим кассы PayPal',
    },
    'Lokale PayPal-Zahlung über den Raspberry Pi': {
      AppLanguage.de: 'Lokale PayPal-Zahlung über den Raspberry Pi',
      AppLanguage.en: 'Local PayPal payments via the Raspberry Pi',
      AppLanguage.es: 'Pagos PayPal locales mediante Raspberry Pi',
      AppLanguage.it: 'Pagamenti PayPal locali tramite Raspberry Pi',
      AppLanguage.nl: 'Lokale PayPal-betalingen via de Raspberry Pi',
      AppLanguage.fr: 'Paiements PayPal locaux via le Raspberry Pi',
      AppLanguage.pt: 'Pagamentos PayPal locais pelo Raspberry Pi',
      AppLanguage.pl: 'Lokalne płatności PayPal przez Raspberry Pi',
      AppLanguage.tr: 'Raspberry Pi üzerinden yerel PayPal ödemeleri',
      AppLanguage.ru: 'Локальные платежи PayPal через Raspberry Pi',
    },
    'Cocktailpreise': {
      AppLanguage.de: 'Cocktailpreise',
      AppLanguage.en: 'Cocktail prices',
      AppLanguage.es: 'Precios de cócteles',
      AppLanguage.it: 'Prezzi cocktail',
      AppLanguage.nl: 'Cocktailprijzen',
      AppLanguage.fr: 'Prix des cocktails',
      AppLanguage.pt: 'Preços dos coquetéis',
      AppLanguage.pl: 'Ceny koktajli',
      AppLanguage.tr: 'Kokteyl fiyatları',
      AppLanguage.ru: 'Цены коктейлей',
    },
    'Einzelpreise pro Cocktail festlegen': {
      AppLanguage.de: 'Einzelpreise pro Cocktail festlegen',
      AppLanguage.en: 'Set individual prices per cocktail',
      AppLanguage.es: 'Definir precios individuales por cóctel',
      AppLanguage.it: 'Imposta prezzi individuali per cocktail',
      AppLanguage.nl: 'Individuele prijzen per cocktail instellen',
      AppLanguage.fr: 'Définir un prix individuel par cocktail',
      AppLanguage.pt: 'Definir preços individuais por coquetel',
      AppLanguage.pl: 'Ustaw indywidualne ceny koktajli',
      AppLanguage.tr: 'Kokteyl başına ayrı fiyat belirle',
      AppLanguage.ru: 'Задать отдельные цены для коктейлей',
    },
    'Branding': {
      AppLanguage.de: 'Branding',
      AppLanguage.en: 'Branding',
      AppLanguage.es: 'Marca',
      AppLanguage.it: 'Branding',
      AppLanguage.nl: 'Branding',
      AppLanguage.fr: 'Image de marque',
      AppLanguage.pt: 'Marca',
      AppLanguage.pl: 'Branding',
      AppLanguage.tr: 'Markalama',
      AppLanguage.ru: 'Брендинг',
    },
    'Barname und Gewerbehinweis': {
      AppLanguage.de: 'Barname und Gewerbehinweis',
      AppLanguage.en: 'Bar name and commercial note',
      AppLanguage.es: 'Nombre del bar y nota comercial',
      AppLanguage.it: 'Nome del bar e nota commerciale',
      AppLanguage.nl: 'Barnaam en commerciële melding',
      AppLanguage.fr: 'Nom du bar et mention commerciale',
      AppLanguage.pt: 'Nome do bar e aviso comercial',
      AppLanguage.pl: 'Nazwa baru i informacja handlowa',
      AppLanguage.tr: 'Bar adı ve ticari not',
      AppLanguage.ru: 'Название бара и коммерческая пометка',
    },
    'Raspberry Pi verbunden': {
      AppLanguage.de: 'Raspberry Pi verbunden',
      AppLanguage.en: 'Raspberry Pi connected',
      AppLanguage.es: 'Raspberry Pi conectado',
      AppLanguage.it: 'Raspberry Pi connesso',
      AppLanguage.nl: 'Raspberry Pi verbonden',
      AppLanguage.fr: 'Raspberry Pi connecté',
      AppLanguage.pt: 'Raspberry Pi conectado',
      AppLanguage.pl: 'Raspberry Pi połączony',
      AppLanguage.tr: 'Raspberry Pi bağlı',
      AppLanguage.ru: 'Raspberry Pi подключён',
    },
    'Lokale GPIO-Steuerung': {
      AppLanguage.de: 'Lokale GPIO-Steuerung',
      AppLanguage.en: 'Local GPIO control',
      AppLanguage.es: 'Control GPIO local',
      AppLanguage.it: 'Controllo GPIO locale',
      AppLanguage.nl: 'Lokale GPIO-besturing',
      AppLanguage.fr: 'Commande GPIO locale',
      AppLanguage.pt: 'Controle GPIO local',
      AppLanguage.pl: 'Lokalne sterowanie GPIO',
      AppLanguage.tr: 'Yerel GPIO kontrolü',
      AppLanguage.ru: 'Локальное управление GPIO',
    },
    'App schließen': {
      AppLanguage.de: 'App schließen',
      AppLanguage.en: 'Close app',
      AppLanguage.es: 'Cerrar aplicación',
      AppLanguage.it: 'Chiudi app',
      AppLanguage.nl: 'App sluiten',
      AppLanguage.fr: 'Fermer l’application',
      AppLanguage.pt: 'Fechar app',
      AppLanguage.pl: 'Zamknij aplikację',
      AppLanguage.tr: 'Uygulamayı kapat',
      AppLanguage.ru: 'Закрыть приложение',
    },
    'CocktailBot wirklich schließen und zum Raspberry-Desktop zurückkehren?': {
      AppLanguage.de: 'CocktailBot wirklich schließen und zum Raspberry-Desktop zurückkehren?',
      AppLanguage.en: 'Really close CocktailBot and return to the Raspberry desktop?',
      AppLanguage.es: '¿Cerrar CocktailBot y volver al escritorio de Raspberry?',
      AppLanguage.it: 'Chiudere CocktailBot e tornare al desktop Raspberry?',
      AppLanguage.nl: 'CocktailBot echt sluiten en terugkeren naar het Raspberry-bureaublad?',
      AppLanguage.fr: 'Fermer CocktailBot et revenir au bureau Raspberry ?',
      AppLanguage.pt: 'Fechar o CocktailBot e voltar à área de trabalho do Raspberry?',
      AppLanguage.pl: 'Zamknąć CocktailBot i wrócić do pulpitu Raspberry?',
      AppLanguage.tr: 'CocktailBot kapatılsın ve Raspberry masaüstüne dönülsün mü?',
      AppLanguage.ru: 'Закрыть CocktailBot и вернуться на рабочий стол Raspberry?',
    },
    'App konnte nicht geschlossen werden.': {
      AppLanguage.de: 'App konnte nicht geschlossen werden.',
      AppLanguage.en: 'The app could not be closed.',
      AppLanguage.es: 'No se pudo cerrar la aplicación.',
      AppLanguage.it: 'Impossibile chiudere l’app.',
      AppLanguage.nl: 'De app kon niet worden gesloten.',
      AppLanguage.fr: 'Impossible de fermer l’application.',
      AppLanguage.pt: 'Não foi possível fechar o app.',
      AppLanguage.pl: 'Nie udało się zamknąć aplikacji.',
      AppLanguage.tr: 'Uygulama kapatılamadı.',
      AppLanguage.ru: 'Не удалось закрыть приложение.',
    },
    'Einstellungen gesperrt': {
      AppLanguage.de: 'Einstellungen gesperrt',
      AppLanguage.en: 'Settings locked',
      AppLanguage.es: 'Ajustes bloqueados',
      AppLanguage.it: 'Impostazioni bloccate',
      AppLanguage.nl: 'Instellingen vergrendeld',
      AppLanguage.fr: 'Paramètres verrouillés',
      AppLanguage.pt: 'Configurações bloqueadas',
      AppLanguage.pl: 'Ustawienia zablokowane',
      AppLanguage.tr: 'Ayarlar kilitli',
      AppLanguage.ru: 'Настройки заблокированы',
    },
    'Einstellungen': {
      AppLanguage.de: 'Einstellungen',
      AppLanguage.en: 'Settings',
      AppLanguage.es: 'Ajustes',
      AppLanguage.it: 'Impostazioni',
      AppLanguage.nl: 'Instellingen',
      AppLanguage.fr: 'Paramètres',
      AppLanguage.pt: 'Configurações',
      AppLanguage.pl: 'Ustawienia',
      AppLanguage.tr: 'Ayarlar',
      AppLanguage.ru: 'Настройки',
    },
    'Zubereitung starten': {
      AppLanguage.de: 'Zubereitung starten',
      AppLanguage.en: 'Start preparation',
      AppLanguage.es: 'Iniciar preparación',
      AppLanguage.it: 'Avvia preparazione',
      AppLanguage.nl: 'Bereiding starten',
      AppLanguage.fr: 'Démarrer la préparation',
      AppLanguage.pt: 'Iniciar preparo',
      AppLanguage.pl: 'Rozpocznij przygotowanie',
      AppLanguage.tr: 'Hazırlamayı başlat',
      AppLanguage.ru: 'Начать приготовление',
    },
    'Lizenzierte Maschine': {
      AppLanguage.de: 'Lizenzierte Maschine',
      AppLanguage.en: 'Licensed machine',
      AppLanguage.es: 'Máquina con licencia',
      AppLanguage.it: 'Macchina con licenza',
      AppLanguage.nl: 'Gelicentieerde machine',
      AppLanguage.fr: 'Machine sous licence',
      AppLanguage.pt: 'Máquina licenciada',
      AppLanguage.pl: 'Licencjonowana maszyna',
      AppLanguage.tr: 'Lisanslı makine',
      AppLanguage.ru: 'Лицензированная машина',
    },
    'Neu prüfen': {
      AppLanguage.de: 'Neu prüfen',
      AppLanguage.en: 'Check again',
      AppLanguage.es: 'Comprobar de nuevo',
      AppLanguage.it: 'Controlla di nuovo',
      AppLanguage.nl: 'Opnieuw controleren',
      AppLanguage.fr: 'Vérifier à nouveau',
      AppLanguage.pt: 'Verificar novamente',
      AppLanguage.pl: 'Sprawdź ponownie',
      AppLanguage.tr: 'Tekrar kontrol et',
      AppLanguage.ru: 'Проверить снова',
    },
  };
  final settingsEnglishFallback = <String, String>{
    'Netzwerk & Tablet': 'Network & tablet',
    'Zugriff im lokalen WLAN/LAN und Admin-PIN': 'Local Wi-Fi/LAN access and admin PIN',
    'CocktailBot auf Tablet oder PC öffnen': 'Open CocktailBot on a tablet or PC',
    'Der Zugriff funktioniert nur im gleichen lokalen WLAN/LAN. CocktailBot wird nicht für das Internet freigegeben.': 'Access works only on the same local Wi-Fi/LAN. CocktailBot is not exposed to the Internet.',
    'Zugriff im lokalen Netzwerk erlauben': 'Allow access on the local network',
    'Tablet- und PC-Zugriff ist aktiviert.': 'Tablet and PC access is enabled.',
    'Nur der Raspberry selbst kann CocktailBot öffnen.': 'Only the Raspberry itself can open CocktailBot.',
    'Admin-PIN': 'Admin PIN',
    'Vom Tablet oder PC sind die Einstellungen nur nach Eingabe dieses PINs erreichbar. Cocktails können ohne Admin-PIN ausgewählt und zubereitet werden.': 'From a tablet or PC, settings are available only after entering this PIN. Cocktails can be selected and prepared without the admin PIN.',
    'Admin-PIN ändern': 'Change admin PIN',
    'Admin-PIN festlegen': 'Set admin PIN',
    'Leer lassen, wenn der vorhandene PIN bleiben soll': 'Leave empty to keep the current PIN',
    '4 bis 8 Ziffern': '4 to 8 digits',
    'Adresse für Tablet oder PC': 'Address for tablet or PC',
    'Keine Netzwerkadresse erkannt.': 'No network address detected.',
    'Adresse kopiert': 'Address copied',
    'Netzwerkfehler': 'Network error',
    'Netzwerkeinstellungen gespeichert': 'Network settings saved',
    'Netzwerkstatus aktualisieren': 'Refresh network status',
    'Bitte zuerst einen Admin-PIN festlegen': 'Please set an admin PIN first',
    'Admin-PIN muss aus 4 bis 8 Ziffern bestehen': 'Admin PIN must contain 4 to 8 digits',
    'Für Einstellungen vom Tablet oder PC bitte den Admin-PIN eingeben.': 'Enter the admin PIN to access settings from a tablet or PC.',
    'Falscher Admin-PIN': 'Incorrect admin PIN',
    'Speichere …': 'Saving …',
    'Diese Einstellungen gelten für Cocktails, alkoholfreie Cocktails und Shots. Auf den Cocktail-Seiten selbst wird die obere Navigation angezeigt.': 'These settings apply to cocktails, alcohol-free cocktails and shots. The top navigation is shown on the cocktail pages.',
    'Laden': 'Load',
    'Rezepte': 'Recipes',
    'Für eigene Reihenfolge „Originale Reihenfolge“ verwenden.': 'Use “Original order” for a custom order.',
    'Verschiebe einzelne Cocktails mit den Pfeilen. Die App stellt danach automatisch auf „Originale Reihenfolge“, damit deine eigene Reihenfolge sichtbar ist.': 'Move individual cocktails with the arrows. The app then automatically switches to “Original order” so your custom order remains visible.',
    'LED-Einstellungen wurden übernommen': 'LED settings applied',
    'LED-Einstellungen gespeichert. Sie werden beim nächsten Verbinden übertragen.': 'LED settings saved. They will be transferred the next time a connection is established.',
    'Nächste Pumpe wird vorbereitet': 'Preparing next pump',
    'läuft': 'running',
    'Zeitüberschreitung beim Warten auf die Raspberry-Steuerung': 'Timed out while waiting for Raspberry control',
    'Statistik': 'Statistics',
    'Kosten- und Margenberechnung': 'Cost and margin calculation',
    'CSV/PDF-Export vorbereitet': 'CSV/PDF export prepared',
    'Bar-/Firmenbranding': 'Bar/company branding',
    'wird noch in': 'is still used in',
    'Rezept(en) verwendet. Entferne die Zutat zuerst aus den betroffenen Rezepten.': 'recipe(s). Remove the ingredient from the affected recipes first.',
    'ist noch': 'is still assigned to',
    'Pumpe(n) zugeordnet. Beim Löschen wird die Zuordnung entfernt und die Pumpenkalibrierung zurückgesetzt.': 'pump(s). Deleting it will remove the assignment and reset the pump calibration.',
    'wirklich löschen?': 'really delete?',
    'wurde gelöscht.': 'was deleted.',
    'Kiosk-Steuerung über den lokalen Raspberry-Pi-Dienst. Das Feld bleibt leer, wenn App und GPIO-API auf demselben Raspberry Pi laufen.': 'Kiosk control via the local Raspberry Pi service. Leave the field empty when the app and GPIO API run on the same Raspberry Pi.',
    '1. Fülle einen großen Behälter mit etwa 40–50 °C warmem Wasser und etwas Spülmittel. Lege alle Ansaugschläuche in den Behälter und starte die Reinigung.\n\n2. Fülle den Behälter anschließend mit klarem Wasser und starte die Reinigung erneut.\n\n3. Entferne die Schläuche aus dem Wasser und lasse sie nochmal trocken durchlaufen. Der Auffangbehälter muss weiterhin unter dem Ausguss stehen.\n\n4. Bei Membranpumpen bitte alle Schläuche der Pumpen entfernen und das Reinigungsprogramm erneut starten. Lege vorher ein Handtuch unter die Pumpen. Dieser Schritt ist wichtig, um Schimmel in den Pumpen zu verhindern.': '1. Fill a large container with warm water at about 40–50 °C and a little detergent. Put all intake tubes into the container and start cleaning.\n\n2. Then fill the container with clean water and start cleaning again.\n\n3. Remove the tubes from the water and run them dry once more. Keep the collection container under the outlet.\n\n4. For diaphragm pumps, remove all pump tubes and start the cleaning program again. Place a towel under the pumps first. This step is important to prevent mold inside the pumps.',
    'Hinweis: Verbrauch und Kosten werden aus den Rezeptmengen und den eingetragenen Literpreisen berechnet. Manuelle Zutaten werden in der Statistik mitgezählt, sofern sie im Rezept als Zutat hinterlegt sind.': 'Note: Consumption and costs are calculated from recipe quantities and the entered prices per liter. Manual ingredients are included in the statistics if they are stored as ingredients in the recipe.',
    'Kiosk-Steuerung über den lokalen Raspberry-Pi-Dienst.': 'Kiosk control via the local Raspberry Pi service.',
    'API-Host (optional)': 'API host (optional)',
    'Aktive Party': 'Active party',
    'Aktivieren': 'Enable',
    'Aktiviert am': 'Activated on',
    'Aktuell': 'Current',
    'Alkoholfrei Preis EUR': 'Alcohol-free price EUR',
    'Anzeige gespeichert': 'Display settings saved',
    'App konnte nicht geschlossen werden.': 'The app could not be closed.',
    'App schließen': 'Close app',
    'Ausgewählt': 'Selected',
    'Auswahl und Beliebtheit für Veranstaltungen': 'Selection and popularity for events',
    'Automatische Sortierung': 'Automatic sorting',
    'Bar- oder Firmenname': 'Bar or company name',
    'Barname und Gewerbehinweis': 'Bar name and commercial note',
    'Basis': 'Base',
    'Bestellungen und Zahlungsstatus laufen direkt über den Raspberry Pi. Es wird kein Cloudflare-Backend benötigt. PayPal-Client-ID und Secret werden ausschließlich auf dem Raspberry gespeichert.': 'Orders and payment status are handled directly by the Raspberry Pi. No Cloudflare backend is required. PayPal client ID and secret are stored only on the Raspberry.',
    'Bezahlung erfolgreich': 'Payment successful',
    'Bitte Passwort eingeben. Das Notfall-Passwort cocktailbot funktioniert immer.': 'Enter the password. The emergency password cocktailbot always works.',
    'Bitte eine gültige Zahl eingeben': 'Please enter a valid number',
    'Bitte mindestens einen Cocktail auswählen': 'Please select at least one cocktail',
    'Bitte zuerst ein Passwort festlegen': 'Please set a password first',
    'Bitte zuerst unter Einstellungen → Partykarten eine Partykarte erstellen.': 'First create a party card under Settings → Party cards.',
    'Branding': 'Branding',
    'Branding speichern': 'Save branding',
    'Branding wurde gespeichert': 'Branding saved',
    'Cocktail Preis EUR': 'Cocktail price EUR',
    'Cocktail zubereiten': 'Prepare cocktail',
    'Cocktail-Listen': 'Cocktail lists',
    'Cocktail-Ranking, Kosten und Zutatenverbrauch': 'Cocktail ranking, costs and ingredient consumption',
    'CocktailBot Lizenzdatei auswählen': 'Select CocktailBot license file',
    'CocktailBot wirklich schließen und zum Raspberry-Desktop zurückkehren?': 'Really close CocktailBot and return to the Raspberry desktop?',
    'Cocktailpreise': 'Cocktail prices',
    'Cocktails': 'Cocktails',
    'Cocktails einzeln sortieren': 'Sort cocktails individually',
    'Cocktails können direkt gestartet werden': 'Cocktails can be started directly',
    'Cocktails pro Gast werden automatisch aus vergangenen Partys berechnet.': 'Cocktails per guest are calculated automatically from past parties.',
    'Cocktails starten erst nach Zahlungsfreigabe': 'Cocktails start only after payment approval',
    'Deaktivieren': 'Disable',
    'Der Raspberry installiert die Lizenz nach erfolgreicher Prüfung automatisch. Es sind keine Terminal- oder sudo-Befehle nötig.': 'The Raspberry installs the license automatically after successful verification. No terminal or sudo commands are required.',
    'Design wurde gespeichert': 'Design saved',
    'Standard / Benutzerdefiniert': 'Default / Custom',
    'Edel / Exklusiv': 'Elegant / Exclusive',
    'Modern / Clean': 'Modern / Clean',
    'Futuristisch / Neon': 'Futuristic / Neon',
    'Tropisch / Sommer': 'Tropical / Summer',
    'Industrial / Loft': 'Industrial / Loft',
    'Vintage / Klassisch': 'Vintage / Classic',
    'Die Lizenzdatei ist leer.': 'The license file is empty.',
    'Die ausgewählte Datei ist keine gültige CocktailBot-Lizenzdatei.': 'The selected file is not a valid CocktailBot license file.',
    'Diese Daten können später auf Kassenmodus, Exporten und Berichten angezeigt werden.': 'These details can later be shown in checkout mode, exports and reports.',
    'Diese Zahlung wurde bereits verwendet': 'This payment has already been used',
    'Eigener Preis aktiv': 'Custom price enabled',
    'Eine Partykarte ist die kleinere Auswahl aus deiner Cocktailliste. Dazu wird je Cocktail eine erwartete Beliebtheit gespeichert.': 'A party card is a smaller selection from your cocktail list. An expected popularity is stored for each cocktail.',
    'Einkaufsliste': 'Shopping list',
    'Einstellungen sperren': 'Lock settings',
    'Einstellungsbereich sperren': 'Lock settings area',
    'Einzelpreise pro Cocktail': 'Individual prices per cocktail',
    'Einzelpreise pro Cocktail festlegen': 'Set individual prices per cocktail',
    'Enthaltene Gewerbefunktionen': 'Included commercial features',
    'Entsperren': 'Unlock',
    'Falsches Passwort': 'Wrong password',
    'Fehlt ca.': 'Approx. missing',
    'Geplant': 'Planned',
    'Geplanter Zutatenbedarf': 'Planned ingredient requirement',
    'Geräte-ID': 'Device ID',
    'Geräte-ID für Zahlungen': 'Device ID for payments',
    'Geräte-ID kopiert': 'Device ID copied',
    'Gerätegebundene Offline-Lizenz': 'Device-bound offline license',
    'Gespeicherte Lizenz gehört zu einem anderen Gerät': 'Stored license belongs to another device',
    'Gewerbelizenz': 'Commercial license',
    'Gewerbelizenz aktiv': 'Commercial license active',
    'Gewerbelizenz erforderlich': 'Commercial license required',
    'Gewerbelizenz wurde aktiviert': 'Commercial license activated',
    'Gewerbelizenz wurde deaktiviert': 'Commercial license deactivated',
    'Gewerbelizenz wurde erfolgreich importiert und aktiviert.': 'Commercial license imported and activated successfully.',
    'Gewerbelizenz öffnen': 'Open commercial license',
    'Gewerbliche Nutzung erlaubt': 'Commercial use permitted',
    'Gäste': 'Guests',
    'Gästezahl': 'Number of guests',
    'Hier kannst du die wichtigsten App-Farben selbst anpassen.': 'You can customize the most important app colors here.',
    'Hier legst du die Verkaufspreise pro Cocktail fest. Ohne Einzelpreis gilt der Standardpreis aus dem PayPal Kassenmodus.': 'Set the selling price for each cocktail here. If no individual price is set, the default price from PayPal checkout mode applies.',
    'In der Datei wurde kein CocktailBot-Lizenzcode gefunden.': 'No CocktailBot license code was found in the file.',
    'Keine Zutaten berechnet': 'No ingredients calculated',
    'Kopieren': 'Copy',
    'Leer lassen, wenn das vorhandene Passwort bleiben soll': 'Leave empty to keep the current password',
    'Liste auswählen': 'Select list',
    'Literpreise und Kostenberechnung sind nur in der Lizenzversion verfügbar.': 'Liter prices and cost calculation are only available with a commercial license.',
    'Live-Vorschau': 'Live preview',
    'Lizenz gültig': 'License valid',
    'Lizenz wird geprüft …': 'Checking license …',
    'Lizenzcode hat ein ungültiges Format': 'License code has an invalid format',
    'Lizenzcode hat eine ungültige Länge': 'License code has an invalid length',
    'Lizenzcode ist für dieses Gerät ungültig': 'License code is invalid for this device',
    'Lizenzcode ist leer': 'License code is empty',
    'Lizenzcode kann nicht gelesen werden': 'License code cannot be read',
    'Lizenzdatei importieren': 'Import license file',
    'Lizenzdatei vom CocktailBot-Anbieter': 'License file from your CocktailBot provider',
    'Lizenzimport fehlgeschlagen': 'License import failed',
    'Lizenzprüfung fehlgeschlagen': 'License verification failed',
    'Lizenzstatus aktualisieren': 'Refresh license status',
    'Lizenzstatus wird geprüft …': 'Checking license status …',
    'Lokale GPIO-Steuerung': 'Local GPIO control',
    'Lokale PayPal-Zahlung über den Raspberry Pi': 'Local PayPal payments via the Raspberry Pi',
    'Lokale PayPal-Zahlungsfreigabe': 'Local PayPal payment approval',
    'Lokales Zahlungsbackend nicht erreichbar': 'Local payment backend is not reachable',
    'Lokales Zahlungsbackend wird geprüft …': 'Checking local payment backend …',
    'Löschen': 'Delete',
    'Max': 'Max',
    'Max. gesamt': 'Max. total',
    'Min': 'Min',
    'Min. gesamt': 'Min. total',
    'Modus': 'Mode',
    'Nach oben': 'Move up',
    'Nach unten': 'Move down',
    'Name der Partykarte': 'Party card name',
    'Neue Partykarte erstellen': 'Create new party card',
    'Neues Passwort': 'New password',
    'Noch keine Min/Ø/Max-Werte': 'No min/avg/max values yet',
    'Noch keine Partykarte gespeichert': 'No party card saved yet',
    'Noch keine abgeschlossene Party mit dieser Partykarte. Die Planung nutzt Standardwerte und die Beliebtheit der Partykarte.': 'No completed party with this party card yet. Planning uses default values and the party card popularity.',
    'Party beenden': 'End party',
    'Party planen': 'Plan party',
    'Party starten': 'Start party',
    'Partykarte': 'Party card',
    'Partykarte bearbeiten': 'Edit party card',
    'Partykarte speichern': 'Save party card',
    'Partykarten': 'Party cards',
    'Partyname': 'Party name',
    'Partyplaner': 'Party planner',
    'Passwort': 'Password',
    'Passwort ändern': 'Change password',
    'PayPal Kassenmodus': 'PayPal checkout mode',
    'PayPal Kassenmodus gespeichert': 'PayPal checkout mode saved',
    'PayPal Zahlung': 'PayPal payment',
    'PayPal lokal auf dem Raspberry konfiguriert': 'PayPal configured locally on the Raspberry',
    'PayPal-Zahlung vor Zubereitung erzwingen': 'Require PayPal payment before preparation',
    'PayPal-Zugangsdaten auf dem Raspberry fehlen': 'PayPal credentials are missing on the Raspberry',
    'Plan': 'Plan',
    'Preise': 'Prices',
    'Privatmodus': 'Private mode',
    'Privatmodus aktiv': 'Private mode active',
    'Prognose aus vergangenen Partys': 'Forecast based on past parties',
    'QR-Code scannen und mit PayPal bezahlen': 'Scan the QR code and pay with PayPal',
    'Raspberry Pi verbunden': 'Raspberry Pi connected',
    'Reserve in Prozent': 'Reserve in percent',
    'Sende diese Geräte-ID an deinen CocktailBot-Anbieter. Du erhältst eine TXT-Lizenzdatei, die ausschließlich auf diesem Raspberry funktioniert. Speichere die Datei z. B. auf einem USB-Stick und importiere sie hier. Eine Internetverbindung ist nicht erforderlich.': 'Send this device ID to your CocktailBot provider. You will receive a TXT license file that works only on this Raspberry. Save it, for example, on a USB drive and import it here. No internet connection is required.',
    'Shot Preis EUR': 'Shot price EUR',
    'Shots': 'Shots',
    'Sicherheit & Freigaben': 'Security & permissions',
    'Sicherheitseinstellungen gespeichert': 'Security settings saved',
    'So wirken Navigation, Cocktailkarten, Buttons und Statusfarben zusammen.': 'This preview shows how navigation, cocktail cards, buttons and status colors work together.',
    'Sortierung und Cocktails pro Seite einstellen': 'Configure sorting and cocktails per page',
    'Speichern': 'Save',
    'Speichern fehlgeschlagen': 'Save failed',
    'Standardpreis': 'Default price',
    'Standardpreis verwenden': 'Use default price',
    'Stärkeregler für alkoholische Cocktails freigeben': 'Enable strength control for alcoholic cocktails',
    'Stärkeregler und Einstellungs-Passwort': 'Strength control and settings password',
    'TXT-Datei auswählen. Geräte-ID und Signatur werden automatisch geprüft.': 'Select the TXT file. Device ID and signature are checked automatically.',
    'Untertitel / Hinweis': 'Subtitle / note',
    'Verbrauchsstatistik': 'Consumption statistics',
    'Vergangene Partys': 'Past parties',
    'Voreingestellte Designs': 'Preset designs',
    'Warte auf Zahlung': 'Waiting for payment',
    'Wenn aktiv, erscheint in alkoholischen Cocktail-Details ein Slider von 0 bis 25 % vol.': 'When enabled, alcoholic cocktail details show a slider from 0 to 25% vol.',
    'Wenn aktiv, kommt man nur mit deinem Passwort in die Einstellungen. Das Notfall-Passwort cocktailbot funktioniert immer.': 'When enabled, settings can only be opened with your password. The emergency password cocktailbot always works.',
    'Wird automatisch aus der hardwaregebundenen CocktailBot Geräte-ID übernommen.': 'Automatically taken from the hardware-bound CocktailBot device ID.',
    'Wird ermittelt …': 'Detecting …',
    'Wird freigegeben …': 'Approving …',
    'Wähle eine hochwertige Farbkombination mit direkter Vorschau.': 'Choose a high-quality color combination with a live preview.',
    'Zahlung bestätigt – Cocktail kann zubereitet werden': 'Payment confirmed – cocktail can be prepared',
    'Zahlung konnte nicht freigegeben werden': 'Payment could not be approved',
    'Zahlung prüfen': 'Check payment',
    'Zahlungseinstellungen speichern': 'Save payment settings',
    'Zahlungsstatus konnte nicht geprüft werden': 'Payment status could not be checked',
    'Zutat kann nicht gelöscht werden': 'Ingredient cannot be deleted',
    'Zutat löschen': 'Delete ingredient',
    'Zutat löschen?': 'Delete ingredient?',
    'Zutatenbedarf und fehlende Mengen planen': 'Plan ingredient requirements and missing quantities',
    'abgeschlossene Partys mit dieser Partykarte': 'completed parties with this party card',
    'fehlt': 'missing',
    'ist Teil der CocktailBot Gewerbelizenz. Die Grundfunktionen der Maschine bleiben im Privatmodus nutzbar.': 'is part of the CocktailBot commercial license. The machine’s basic functions remain available in private mode.',
    'leer = lokale Steuerung': 'empty = local control',
    'ml': 'ml',
    'vorhanden': 'available',
    'Ø gesamt': 'Average total',
    'Verkaufspreise nach Cocktailgröße': 'Selling prices by cocktail size',
    'Für jede aktivierte Größe kann ein eigener Preis hinterlegt werden. Ohne Einzelpreis gilt der Standardpreis dieser Größe aus dem PayPal-Kassenmodus.': 'A separate price can be set for every enabled size. Without an individual price, the default price for that size from PayPal checkout mode applies.',
    'Nur die in den Größeneinstellungen aktivierten Größen werden angezeigt.': 'Only sizes enabled in the size settings are shown.',
    'Eigener Preis für diese Größe': 'Custom price for this size',
    'Standardpreise nach Größe': 'Default prices by size',
    'Diese Preise gelten, wenn für einen einzelnen Cocktail und diese Größe kein eigener Preis gesetzt wurde.': 'These prices apply when no individual price is set for a cocktail and this size.',
    'Einzelpreise pro Cocktail und Größe stellst du im Menü „Cocktailpreise“ ein.': 'Set individual prices per cocktail and size in the Cocktail prices menu.',
    'Zubereitet': 'Prepared',
    'Gesamtkosten': 'Total cost',
    'Ø Kosten / Cocktail': 'Avg. cost / cocktail',
    'Ausgegeben': 'Dispensed',
    'Cocktails im Detail': 'Cocktails in detail',
    'Häufigkeit': 'Frequency',
    'Kosten': 'Cost',
    'Info & Lizenz': 'Info & license',
    'Copyright, Kontakt und Nutzungsbedingungen': 'Copyright, contact and terms of use',
    'Lizenz- und Nutzungshinweis': 'License and usage notice',
    'Private Nutzung ohne Gewerbelizenz': 'Private use without a commercial license',
    'Die Nutzung von CocktailBot und der damit betriebenen Maschine ist ohne aktive Gewerbelizenz ausschließlich für private und nicht-kommerzielle Zwecke erlaubt.': 'Use of CocktailBot and the machine operated with it is permitted without an active commercial license only for private, non-commercial purposes.',
    'Eine gewerbliche Nutzung – zum Beispiel in der Gastronomie, in Unternehmen, auf gewerblichen Veranstaltungen oder zur entgeltlichen Abgabe von Getränken – ist ohne entsprechende Gewerbelizenz nicht gestattet.': 'Commercial use – for example in hospitality, businesses, commercial events or for serving drinks for payment – is not permitted without the appropriate commercial license.',
    'Für eine gewerbliche Nutzung ist eine gültige Printcore-Gewerbelizenz erforderlich.': 'A valid Printcore commercial license is required for commercial use.',
    'Mit „Akzeptieren“ bestätigst du, dass du diesen Hinweis gelesen hast und CocktailBot ohne Gewerbelizenz nicht gewerblich nutzt.': 'By selecting “Accept”, you confirm that you have read this notice and will not use CocktailBot commercially without a commercial license.',
    'Diesen Hinweis nicht mehr anzeigen': 'Do not show this notice again',
    'Ablehnen': 'Decline',
    'Akzeptieren': 'Accept',
    'Nutzung nicht akzeptiert': 'Usage terms not accepted',
    'Die Nutzung wurde nicht akzeptiert. Bitte schließe dieses Browserfenster. Die CocktailBot-Maschine wurde nicht beendet.': 'The usage notice was not accepted. Please close this browser window. The CocktailBot machine was not shut down.',
    'CocktailBot wird beendet …': 'CocktailBot is closing …',
    'CocktailBot konnte nicht automatisch beendet werden. Die Anwendung bleibt gesperrt.': 'CocktailBot could not be closed automatically. The application remains locked.',
    'Entwicklung & Copyright': 'Development & copyright',
    'Alle Rechte vorbehalten.': 'All rights reserved.',
    'Kontakt': 'Contact',
    'Nutzungsrecht': 'Right of use',
    'Ohne Gewerbelizenz': 'Without commercial license',
    'Nur private und nicht-kommerzielle Nutzung': 'Private, non-commercial use only',
    'Mit gültiger Gewerbelizenz': 'With a valid commercial license',
    'Gewerbliche Nutzung gemäß Lizenzumfang erlaubt': 'Commercial use permitted within the scope of the license',
    'Als gewerbliche Nutzung gilt insbesondere der Einsatz im Rahmen eines Unternehmens, Gewerbes, einer Gastronomie, eines Caterings, einer gewerblichen Veranstaltung oder die entgeltliche Abgabe von Getränken oder Dienstleistungen.': 'Commercial use includes, in particular, use within a business, trade, hospitality operation, catering service, commercial event, or the provision of drinks or services for payment.',
    'Die Software und die zugehörigen Inhalte sind urheberrechtlich geschützt. Eine unerlaubte Vervielfältigung, Weitergabe, Veröffentlichung oder kommerzielle Nutzung außerhalb des eingeräumten Lizenzumfangs ist nicht gestattet.': 'The software and associated content are protected by copyright. Unauthorized reproduction, distribution, publication or commercial use outside the granted license scope is not permitted.',
    'Aktueller Lizenzstatus': 'Current license status',
    'Gewerbelizenz verwalten': 'Manage commercial license',
    'Start-Hinweis wieder anzeigen': 'Show startup notice again',
    'Der Lizenz- und Nutzungshinweis wird beim nächsten Start wieder angezeigt.': 'The license and usage notice will be shown again the next time CocktailBot starts.',
    'Zuletzt': 'Most recent',
    'Heute': 'Today',
    '7 Tage': '7 days',
    '30 Tage': '30 days',
    'Gesamt': 'All time',
    'Beliebtester Cocktail': 'Most popular cocktail',
    'Beliebteste Größe': 'Most popular size',
    'Einnahmen': 'Revenue',
    'Einnahmen − Zutatenkosten': 'Revenue − ingredient cost',
    'Gesamtmenge': 'Total volume',
    'Ø Kosten': 'Avg. cost',
    'Nach Größe': 'By size',
    'Verkauf': 'Sales',
    'Kosten unvollständig – mindestens eine Zutat ohne Literpreis': 'Incomplete cost – at least one ingredient has no liter price',
    'Kein Literpreis hinterlegt': 'No liter price set',
    'Für diesen Zeitraum sind noch keine Zubereitungen vorhanden.': 'No preparations are available for this period yet.',
    'Zubereitungen fehlen Zutatenpreise. Die angezeigten Kosten sind deshalb unvollständig.': 'preparations have missing ingredient prices. The displayed costs are therefore incomplete.',
    'ältere Zubereitungen sind nicht in der Detailhistorie enthalten. Anzahl und bisheriger Gesamtverbrauch bleiben gespeichert; Größen- und historische Kostenanalyse gilt für die vorhandene V28-Detailhistorie.': 'older preparations are not included in the detailed history. Counts and previous total usage remain stored; size and historical cost analysis applies to the available V28 detailed history.',
    'Cocktail-Ranking, Größenstatistik, Kostenhistorie und Zutatenverbrauch werden gelöscht. Füllstände und Kalibrierungen bleiben erhalten.': 'Cocktail ranking, size statistics, cost history and ingredient usage will be deleted. Fill levels and calibrations remain unchanged.',
    'PayPal': 'PayPal',
    'Bei': 'For',
    'Ø': 'Avg.',
  };

  final directTranslation =
      texts[key]?[language] ??
      uiTexts[key]?[language] ??
      settingsSupplementalTexts[key]?[language];
  if (directTranslation != null) return directTranslation;

  // Neuere Einstellungsseiten dürfen bei einer Nicht-Deutsch-Sprache niemals
  // still auf den deutschen Schlüssel zurückfallen. Bis für einen seltenen
  // Hinweis eine eigene Sprachvariante ergänzt ist, wird mindestens Englisch
  // angezeigt.
  if (language != AppLanguage.de) {
    final englishFallback =
        settingsSupplementalTexts[key]?[AppLanguage.en] ??
        texts[key]?[AppLanguage.en] ??
        uiTexts[key]?[AppLanguage.en] ??
        settingsEnglishFallback[key];
    if (englishFallback != null) return englishFallback;
  }

  return texts[key]?[AppLanguage.de] ??
      uiTexts[key]?[AppLanguage.de] ??
      settingsSupplementalTexts[key]?[AppLanguage.de] ??
      key;

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

class ConsumptionRecord {
  ConsumptionRecord({
    required this.timestamp,
    required this.recipeId,
    required this.recipeName,
    required this.category,
    required this.sizeMl,
    required this.ingredientAmountsMl,
    required this.ingredientCostsEur,
    required this.totalCostEur,
    required this.missingPriceIngredientIds,
    this.salePriceEur,
    this.partySessionId,
  });

  final DateTime timestamp;
  final String recipeId;
  final String recipeName;
  final DrinkCategory category;
  final double sizeMl;
  final Map<String, double> ingredientAmountsMl;
  final Map<String, double> ingredientCostsEur;
  final double totalCostEur;
  final List<String> missingPriceIngredientIds;
  final double? salePriceEur;
  final String? partySessionId;

  bool get paid => salePriceEur != null;

  Map<String, dynamic> toJson() => {
        'timestamp': timestamp.toIso8601String(),
        'recipeId': recipeId,
        'recipeName': recipeName,
        'category': category.name,
        'sizeMl': sizeMl,
        'ingredientAmountsMl': ingredientAmountsMl,
        'ingredientCostsEur': ingredientCostsEur,
        'totalCostEur': totalCostEur,
        'missingPriceIngredientIds': missingPriceIngredientIds,
        'salePriceEur': salePriceEur,
        'partySessionId': partySessionId,
      };

  factory ConsumptionRecord.fromJson(Map<String, dynamic> json) {
    Map<String, double> parseDoubleMap(Object? value) {
      if (value is! Map) return {};
      return Map<String, double>.from(
        value.map(
          (key, item) => MapEntry(
            key.toString(),
            ((item as num?) ?? 0).toDouble(),
          ),
        ),
      );
    }

    final categoryName = json['category']?.toString();
    final category = DrinkCategory.values
            .where((item) => item.name == categoryName)
            .firstOrNull ??
        DrinkCategory.cocktail;

    return ConsumptionRecord(
      timestamp: DateTime.tryParse(json['timestamp']?.toString() ?? '') ??
          DateTime.now(),
      recipeId: json['recipeId']?.toString() ?? '',
      recipeName: json['recipeName']?.toString() ?? 'Cocktail',
      category: category,
      sizeMl: ((json['sizeMl'] as num?) ?? 0).toDouble(),
      ingredientAmountsMl: parseDoubleMap(json['ingredientAmountsMl']),
      ingredientCostsEur: parseDoubleMap(json['ingredientCostsEur']),
      totalCostEur: ((json['totalCostEur'] as num?) ?? 0).toDouble(),
      missingPriceIngredientIds:
          ((json['missingPriceIngredientIds'] as List?) ?? const [])
              .map((item) => item.toString())
              .toList(),
      salePriceEur: (json['salePriceEur'] as num?)?.toDouble(),
      partySessionId: json['partySessionId']?.toString(),
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
  final List<ConsumptionRecord> consumptionHistory = [];
  // Optionaler Lagerbestand fuer die Party-Einkaufsliste. Fehlt ein Eintrag,
  // gilt der Bestand als nicht erfasst; dann wird der komplette geplante
  // Bedarf als Einkaufsmenge ausgewiesen.
  Map<String, double> shoppingInventoryMl = {};
  bool darkMode = true;
  AppLanguage appLanguage = AppLanguage.de;
  AppColorThemeConfig appColors = AppColorThemeConfig.defaults();
  bool connected = false;
  ConnectionMode connectionMode = ConnectionMode.wifi;
  String wifiHost = ''; // leer = gleicher Host wie die Kiosk-Webseite
  String status = 'Nicht verbunden';
  bool loaded = false;
  List<double> servingSizes = [200, 300, 400];
  List<double> enabledServingSizes = [200, 300, 400];
  double defaultServingSizeMl = 200;
  List<double> shotSizes = [20, 40];
  List<double> enabledShotSizes = [20, 40];
  double defaultShotSizeMl = 20;
  List<double> primeTimesSeconds = List<double>.filled(18, 5);
  double cleaningSeconds = 15;
  int cocktailsPerPage = 10;
  int lowStockWarningPortions = 2;
  int lowFillWarningPercent = 20;
  RecipeSortMode recipeSortMode = RecipeSortMode.original;
  bool paypalPaymentEnabled = false;
  String paymentMachineId = 'CB-DEMO';
  double cocktailPriceEur = 6.50;
  double mocktailPriceEur = 4.50;
  double shotPriceEur = 3.00;
  // Legacy-Preise bleiben als Fallback erhalten, damit bestehende
  // Installationen nach dem Update ihre bisherigen Preise nicht verlieren.
  Map<String, double> recipePricesEur = {};
  // V28: Verkaufspreise koennen pro aktivierter Groesse gepflegt werden.
  // Key: "category|size" bzw. "recipeId|size".
  Map<String, double> categorySizePricesEur = {};
  Map<String, double> recipeSizePricesEur = {};
  bool alcoholStrengthSliderEnabled = false;
  bool settingsLockEnabled = false;
  String settingsPassword = '';
  bool networkAccessEnabled = false;
  bool networkAdminPinConfigured = false;
  List<String> networkAccessUrls = [];
  String _networkAdminToken = '';
  DateTime? _networkAdminExpiresAt;
  bool commercialLicenseActive = false;
  String commercialLicenseCode = '';
  String commercialLicensedMachineId = '';
  String commercialDeviceId = '';
  String commercialLicenseMessage = 'Privatmodus';
  String commercialLicenseType = 'PRIVATE';
  bool commercialPublicKeyInstalled = false;
  DateTime? commercialLicenseActivatedAt;
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

  Future<void> load({bool skipConnect = false}) async {
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
        consumptionHistory
          ..clear()
          ..addAll(
            ((j['consumptionHistory'] as List?) ?? const [])
                .whereType<Map>()
                .map(
                  (entry) => ConsumptionRecord.fromJson(
                    Map<String, dynamic>.from(entry),
                  ),
                ),
          );
        shoppingInventoryMl = Map<String, double>.from(
          ((j['shoppingInventoryMl'] as Map?) ?? const {}).map(
            (key, value) => MapEntry(
              key.toString(),
              math.max(0.0, (value as num).toDouble()),
            ),
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
        enabledServingSizes =
            ((j['enabledServingSizes'] as List?) ?? servingSizes)
                .map((e) => (e as num).toDouble())
                .where((e) => e > 0 && servingSizes.contains(e))
                .toSet()
                .toList()
              ..sort();
        if (!enabledServingSizes.contains(defaultServingSizeMl)) {
          enabledServingSizes.add(defaultServingSizeMl);
          enabledServingSizes.sort();
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
        enabledShotSizes = ((j['enabledShotSizes'] as List?) ?? shotSizes)
            .map((e) => (e as num).toDouble())
            .where((e) => e > 0 && shotSizes.contains(e))
            .toSet()
            .toList()
          ..sort();
        if (!enabledShotSizes.contains(defaultShotSizeMl)) {
          enabledShotSizes.add(defaultShotSizeMl);
          enabledShotSizes.sort();
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
        lowStockWarningPortions =
            ((j['lowStockWarningPortions'] as num?)?.toInt() ?? 2)
                .clamp(1, 10)
                .toInt();
        lowFillWarningPercent =
            ((j['lowFillWarningPercent'] as num?)?.toInt() ?? 20)
                .clamp(5, 90)
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
        categorySizePricesEur = Map<String, double>.from(
          ((j['categorySizePricesEur'] as Map?) ?? const {}).map(
            (key, value) => MapEntry(
              key.toString(),
              (value as num).toDouble().clamp(0, 9999).toDouble(),
            ),
          ),
        );
        recipeSizePricesEur = Map<String, double>.from(
          ((j['recipeSizePricesEur'] as Map?) ?? const {}).map(
            (key, value) => MapEntry(
              key.toString(),
              (value as num).toDouble().clamp(0, 9999).toDouble(),
            ),
          ),
        );
        // Einmalige V27 -> V28 Migration: Ein alter Einzelpreis wird fuer
        // alle aktuell aktivierten Groessen uebernommen. Danach kann jede
        // Groesse unabhaengig bearbeitet oder auf den Standard zurueckgesetzt
        // werden.
        if (recipeSizePricesEur.isEmpty && recipePricesEur.isNotEmpty) {
          for (final recipe in recipes) {
            final legacyPrice = recipePricesEur[recipe.id];
            if (legacyPrice == null) continue;
            for (final size in sizesFor(recipe.category)) {
              recipeSizePricesEur[_sizePriceKey(recipe.id, size)] = legacyPrice;
            }
          }
          recipePricesEur = {};
        }
        alcoholStrengthSliderEnabled =
            j['alcoholStrengthSliderEnabled'] == true;
        settingsLockEnabled = j['settingsLockEnabled'] == true;
        settingsPassword = j['settingsPassword']?.toString() ?? '';
        // Gewerbelizenz wird nicht mehr aus SharedPreferences vertraut.
        // Autoritativ ist ausschließlich die signierte Lizenzdatei auf dem Raspberry.
        commercialLicenseActive = false;
        commercialLicenseCode = '';
        commercialLicensedMachineId = '';
        commercialDeviceId = '';
        commercialLicenseMessage = 'Lizenzstatus wird geprüft …';
        commercialLicenseType = 'PRIVATE';
        commercialPublicKeyInstalled = false;
        commercialLicenseActivatedAt = null;
        final savedLanguage = j['appLanguage']?.toString();
        appLanguage = AppLanguage.values.where(
          (language) => language.name == savedLanguage,
        ).firstOrNull ?? AppLanguage.de;
        final savedColors = j['appColors'];
        if (savedColors is Map) {
          final loadedColors = AppColorThemeConfig.fromJson(
            Map<String, dynamic>.from(savedColors),
          );
          // V18: alte Preset-Designs werden beim Update bewusst entfernt.
          // Individuell angepasste Farbschemata bleiben erhalten.
          appColors = _isLegacyDesignPreset(loadedColors)
              ? AppColorThemeConfig.defaults()
              : loadedColors;
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
    if (!skipConnect) {
      unawaited(connect());
    }
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
        manualNotes: ['Frische Minzblätter ins Glas geben', 'Limettenstücke hinzufügen'],
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

  Map<String, dynamic> _persistentStateJson() {
    return {
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
      'consumptionHistory': consumptionHistory.map((e) => e.toJson()).toList(),
      'shoppingInventoryMl': shoppingInventoryMl,
      'darkMode': darkMode,
      'appLanguage': appLanguage.name,
      'appColors': appColors.toJson(),
      'wifiHost': wifiHost,
      'servingSizes': servingSizes,
      'enabledServingSizes': enabledServingSizes,
      'defaultServingSizeMl': defaultServingSizeMl,
      'shotSizes': shotSizes,
      'enabledShotSizes': enabledShotSizes,
      'defaultShotSizeMl': defaultShotSizeMl,
      'primeTimesSeconds': primeTimesSeconds,
      'cleaningSeconds': cleaningSeconds,
      'cocktailsPerPage': cocktailsPerPage,
      'lowStockWarningPortions': lowStockWarningPortions,
      'lowFillWarningPercent': lowFillWarningPercent,
      'recipeSortMode': recipeSortMode.name,
      'paypalPaymentEnabled': paypalPaymentEnabled,
      'paymentMachineId': paymentMachineId,
      'cocktailPriceEur': cocktailPriceEur,
      'mocktailPriceEur': mocktailPriceEur,
      'shotPriceEur': shotPriceEur,
      'recipePricesEur': recipePricesEur,
      'categorySizePricesEur': categorySizePricesEur,
      'recipeSizePricesEur': recipeSizePricesEur,
      'alcoholStrengthSliderEnabled': alcoholStrengthSliderEnabled,
      'settingsLockEnabled': settingsLockEnabled,
      'settingsPassword': settingsPassword,
      'commercialLicenseActive': commercialLicenseActive,
      'commercialLicenseCode': commercialLicenseCode,
      'commercialLicensedMachineId': commercialLicensedMachineId,
      'commercialLicenseActivatedAt':
          commercialLicenseActivatedAt?.toIso8601String(),
      'ledIdleMode': ledIdleMode.name,
      'ledColorValue': ledColorValue,
      'ledBrightness': ledBrightness,
    };
  }

  Map<String, dynamic> _sharedAppStateForController() {
    final state = Map<String, dynamic>.from(_persistentStateJson());
    // Browser-/Lizenzgeheimnisse werden nicht an andere Geräte im LAN verteilt.
    state.remove('settingsPassword');
    state.remove('commercialLicenseCode');
    // Das Tablet soll immer dieselbe Origin für Web-App und API verwenden.
    state['wifiHost'] = '';
    state['sharedAt'] = DateTime.now().toIso8601String();
    return state;
  }

  Future<void> _syncAppStateToController() async {
    if (!connected || connectionMode == ConnectionMode.bluetooth) {
      return;
    }
    if (isRemoteBrowser && !remoteAdminUnlocked) {
      return;
    }
    try {
      await http
          .post(
            _apiUri('/api/app-state'),
            headers: _apiHeaders(json: true),
            body: jsonEncode({'state': _sharedAppStateForController()}),
          )
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      // LAN-Snapshot ist Komfortfunktion. Lokales Speichern darf nie scheitern.
    }
  }

  Future<bool> _loadSharedAppStateFromController() async {
    if (connectionMode == ConnectionMode.bluetooth) {
      return false;
    }
    try {
      final response = await http
          .get(_apiUri('/api/app-state'), headers: _apiHeaders())
          .timeout(const Duration(seconds: 5));
      if (response.statusCode < 200 || response.statusCode >= 300) return false;
      final decoded = jsonDecode(response.body);
      if (decoded is! Map || decoded['state'] is! Map) return false;
      final state = Map<String, dynamic>.from(decoded['state'] as Map);
      if (state.isEmpty) return false;
      if (!isRemoteBrowser) {
        // These values intentionally never leave the Raspberry browser.
        state['settingsPassword'] = settingsPassword;
        state['commercialLicenseCode'] = commercialLicenseCode;
      }
      final p = await SharedPreferences.getInstance();
      await p.setString('machine_state', jsonEncode(state));
      await load(skipConnect: true);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> save() async {
    notifyListeners();
    final state = _persistentStateJson();
    final p = await SharedPreferences.getInstance();
    await p.setString('machine_state', jsonEncode(state));
    if (connected && (!isRemoteBrowser || remoteAdminUnlocked)) {
      unawaited(_syncAppStateToController());
    }
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
      category == DrinkCategory.shot
          ? List<double>.unmodifiable(enabledShotSizes)
          : List<double>.unmodifiable(enabledServingSizes);

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

  int ingredientRecipeReferenceCount(String ingredientId) {
    var count = recipes.where(
      (recipe) => recipe.parts.any((part) => part.ingredientId == ingredientId),
    ).length;

    for (final list in cocktailLists) {
      count += list.recipes.where(
        (recipe) => recipe.parts.any((part) => part.ingredientId == ingredientId),
      ).length;
    }

    return count;
  }

  int ingredientPumpReferenceCount(String ingredientId) => pumps
      .where((pump) => pump.ingredientId == ingredientId)
      .length;

  Future<String?> deleteIngredient(String ingredientId) async {
    final recipeReferences = ingredientRecipeReferenceCount(ingredientId);
    if (recipeReferences > 0) {
      return 'Diese Zutat wird noch in $recipeReferences Rezept(en) verwendet. '
          'Entferne sie zuerst aus den betroffenen Rezepten.';
    }

    for (final pump in pumps) {
      if (pump.ingredientId == ingredientId) {
        pump.ingredientId = null;
        pump.mlPerSecond = 0;
      }
    }

    ingredients.removeWhere((ingredient) => ingredient.id == ingredientId);
    ingredientUsageMl.remove(ingredientId);
    shoppingInventoryMl.remove(ingredientId);

    await save();
    notifyListeners();
    return null;
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
      ? t('Gewerbelizenz aktiv')
      : t('Privatmodus');

  bool get hasCommercialMachineMatch =>
      commercialLicenseActive &&
      commercialDeviceId.isNotEmpty &&
      commercialLicensedMachineId == commercialDeviceId;

  void _applyCommercialLicenseStatus(Map<String, dynamic> data) {
    final deviceId = data['deviceId']?.toString().trim() ?? '';
    commercialDeviceId = deviceId;
    commercialLicenseActive = data['active'] == true;
    commercialLicenseType = data['licenseType']?.toString() ??
        (commercialLicenseActive ? 'COMMERCIAL' : 'PRIVATE');
    commercialLicenseMessage = data['message']?.toString() ??
        (commercialLicenseActive ? 'Lizenz gültig' : 'Privatmodus');
    commercialPublicKeyInstalled = data['publicKeyInstalled'] == true;
    commercialLicensedMachineId = commercialLicenseActive ? deviceId : '';
    commercialLicenseActivatedAt = DateTime.tryParse(
      data['activatedAt']?.toString() ?? '',
    );

    // Für den lokalen PayPal-Kassenmodus wird dieselbe echte Geräte-ID benutzt.
    if (deviceId.isNotEmpty) {
      paymentMachineId = deviceId;
    }
    if (!commercialLicenseActive) {
      paypalPaymentEnabled = false;
    }
  }

  Future<bool> refreshCommercialLicenseStatus() async {
    try {
      final response = await http
          .get(_apiUri('/api/license/status'))
          .timeout(const Duration(seconds: 5));
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) {
        throw Exception('Ungültige Lizenzantwort');
      }
      final data = Map<String, dynamic>.from(decoded);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception(data['error']?.toString() ?? 'Lizenzstatus nicht verfügbar');
      }
      _applyCommercialLicenseStatus(data);
      await save();
      notifyListeners();
      return true;
    } catch (error) {
      commercialLicenseActive = false;
      commercialLicensedMachineId = '';
      paypalPaymentEnabled = false;
      commercialLicenseMessage = 'Lizenzprüfung nicht verfügbar: $error';
      notifyListeners();
      return false;
    }
  }

  Future<bool> activateCommercialLicense(String code) async {
    final normalized = code.trim();
    if (normalized.isEmpty) {
      commercialLicenseMessage = 'Bitte Lizenzcode eingeben';
      notifyListeners();
      return false;
    }

    try {
      final response = await http
          .post(
            _apiUri('/api/license/activate'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({'code': normalized}),
          )
          .timeout(const Duration(seconds: 8));
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) throw Exception('Ungültige Lizenzantwort');
      final data = Map<String, dynamic>.from(decoded);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        commercialLicenseActive = false;
        commercialLicenseMessage = data['error']?.toString() ??
            data['message']?.toString() ??
            'Lizenzcode ist ungültig';
        notifyListeners();
        return false;
      }
      _applyCommercialLicenseStatus(data);
      commercialLicenseCode = normalized;
      await save();
      notifyListeners();
      return commercialLicenseActive;
    } catch (error) {
      commercialLicenseActive = false;
      commercialLicenseMessage = 'Aktivierung fehlgeschlagen: $error';
      notifyListeners();
      return false;
    }
  }

  Future<void> deactivateCommercialLicense() async {
    try {
      final response = await http
          .post(_apiUri('/api/license/deactivate'))
          .timeout(const Duration(seconds: 5));
      final decoded = jsonDecode(response.body);
      if (decoded is Map) {
        _applyCommercialLicenseStatus(Map<String, dynamic>.from(decoded));
      } else {
        commercialLicenseActive = false;
        commercialLicensedMachineId = '';
      }
    } catch (error) {
      commercialLicenseMessage = 'Deaktivierung fehlgeschlagen: $error';
    }
    commercialLicenseCode = '';
    paypalPaymentEnabled = false;
    await save();
    notifyListeners();
  }

  double categoryPriceFor(DrinkCategory category) => switch (category) {
        DrinkCategory.cocktail => cocktailPriceEur,
        DrinkCategory.mocktail => mocktailPriceEur,
        DrinkCategory.shot => shotPriceEur,
      };

  String _sizePriceKey(String prefix, double sizeMl) =>
      '$prefix|${sizeMl.round()}';

  double categoryPriceForSize(DrinkCategory category, double sizeMl) {
    final custom = categorySizePricesEur[_sizePriceKey(category.name, sizeMl)];
    return custom ?? categoryPriceFor(category);
  }

  bool hasCategorySizePrice(DrinkCategory category, double sizeMl) =>
      categorySizePricesEur.containsKey(_sizePriceKey(category.name, sizeMl));

  double priceForRecipe(Recipe recipe, {double? targetVolumeMl}) {
    final size = targetVolumeMl ?? defaultSizeFor(recipe.category);
    final sizeCustom = recipeSizePricesEur[_sizePriceKey(recipe.id, size)];
    if (sizeCustom != null) return sizeCustom;

    // Bestehende Einzelpreise aus V27 gelten weiterhin fuer jede Groesse,
    // bis fuer diese Groesse ein neuer V28-Preis hinterlegt wird.
    final legacyCustom = recipePricesEur[recipe.id];
    if (legacyCustom != null) return legacyCustom;

    return categoryPriceForSize(recipe.category, size);
  }

  bool hasRecipeSizePrice(Recipe recipe, double sizeMl) =>
      recipeSizePricesEur.containsKey(_sizePriceKey(recipe.id, sizeMl));

  Future<void> setCategorySizePrice(
    DrinkCategory category,
    double sizeMl,
    double? price,
  ) async {
    final key = _sizePriceKey(category.name, sizeMl);
    if (price == null) {
      categorySizePricesEur.remove(key);
    } else {
      categorySizePricesEur[key] = price.clamp(0, 9999).toDouble();
    }
    await save();
    if (connected && connectionMode == ConnectionMode.wifi) {
      try {
        await syncPaymentSettingsToController();
      } catch (_) {}
    }
    notifyListeners();
  }

  Future<void> setRecipeSizePrice(
    Recipe recipe,
    double sizeMl,
    double? price,
  ) async {
    final key = _sizePriceKey(recipe.id, sizeMl);
    if (price == null) {
      recipeSizePricesEur.remove(key);
    } else {
      recipeSizePricesEur[key] = price.clamp(0, 9999).toDouble();
    }
    await save();
    if (connected && connectionMode == ConnectionMode.wifi) {
      try {
        await syncPaymentSettingsToController();
      } catch (_) {}
    }
    notifyListeners();
  }

  // Legacy-API fuer alte Aufrufe. Setzt weiterhin einen allgemeinen
  // Einzelpreis, der als Fallback fuer alle Groessen gilt.
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
      } catch (_) {}
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
      'defaultSizePrices': categorySizePricesEur.map(
        (key, value) => MapEntry(key, value.toStringAsFixed(2)),
      ),
      'recipeSizePrices': recipeSizePricesEur.map(
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
    Map<String, double>? sizePrices,
  }) async {
    paypalPaymentEnabled = enabled && commercialLicenseActive;
    paymentMachineId = commercialDeviceId.isNotEmpty
        ? commercialDeviceId
        : (machineId.trim().isEmpty ? 'CB-DEMO' : machineId.trim());
    cocktailPriceEur = cocktailPrice.clamp(0, 9999).toDouble();
    mocktailPriceEur = mocktailPrice.clamp(0, 9999).toDouble();
    shotPriceEur = shotPrice.clamp(0, 9999).toDouble();
    if (sizePrices != null) {
      categorySizePricesEur = Map<String, double>.from(
        sizePrices.map(
          (key, value) => MapEntry(
            key,
            value.clamp(0, 9999).toDouble(),
          ),
        ),
      );
    }
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

    final amount = priceForRecipe(recipe, targetVolumeMl: targetVolumeMl);
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

  bool get isRemoteBrowser {
    final host = Uri.base.host.toLowerCase().trim();
    if (host.isEmpty) return false;
    return host != '127.0.0.1' &&
        host != 'localhost' &&
        host != '::1' &&
        host != '[::1]';
  }

  bool get remoteAdminUnlocked =>
      _networkAdminToken.isNotEmpty &&
      (_networkAdminExpiresAt == null ||
          DateTime.now().isBefore(_networkAdminExpiresAt!));

  Map<String, String> _apiHeaders({bool json = false}) {
    final headers = <String, String>{};
    if (json) headers['Content-Type'] = 'application/json';
    if (remoteAdminUnlocked) {
      headers['X-CocktailBot-Admin-Token'] = _networkAdminToken;
    }
    return headers;
  }

  Future<Map<String, dynamic>> refreshNetworkAccessStatus() async {
    final response = await http
        .get(_apiUri('/api/network/access'), headers: _apiHeaders())
        .timeout(const Duration(seconds: 4));
    final decoded = response.body.trim().isEmpty
        ? <String, dynamic>{}
        : jsonDecode(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final message = decoded is Map ? decoded['error']?.toString() : null;
      throw Exception(message ?? 'Netzwerkstatus HTTP ${response.statusCode}');
    }
    if (decoded is! Map) {
      throw Exception('Ungültige Netzwerkstatus-Antwort');
    }
    final data = Map<String, dynamic>.from(decoded);
    networkAccessEnabled = data['lanEnabled'] == true;
    networkAdminPinConfigured = data['adminPinConfigured'] == true;
    networkAccessUrls = ((data['urls'] as List?) ?? const [])
        .map((item) => item.toString())
        .where((item) => item.isNotEmpty)
        .toList();
    notifyListeners();
    return data;
  }

  Future<bool> unlockRemoteAdmin(String pin) async {
    try {
      final response = await http
          .post(
            _apiUri('/api/network/admin-login'),
            headers: _apiHeaders(json: true),
            body: jsonEncode({'pin': pin.trim()}),
          )
          .timeout(const Duration(seconds: 4));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return false;
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map || decoded['ok'] != true) return false;
      _networkAdminToken = decoded['token']?.toString() ?? '';
      final ttl = (decoded['expiresInSeconds'] as num?)?.toInt() ?? 1800;
      _networkAdminExpiresAt = DateTime.now().add(Duration(seconds: ttl));
      notifyListeners();
      return remoteAdminUnlocked;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>> saveNetworkAccessSettings({
    required bool enabled,
    String adminPin = '',
  }) async {
    final response = await http
        .post(
          _apiUri('/api/network/access'),
          headers: _apiHeaders(json: true),
          body: jsonEncode({
            'lanEnabled': enabled,
            'adminPin': adminPin.trim(),
          }),
        )
        .timeout(const Duration(seconds: 5));
    final decoded = response.body.trim().isEmpty
        ? <String, dynamic>{}
        : jsonDecode(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final message = decoded is Map ? decoded['error']?.toString() : null;
      throw Exception(message ?? 'Netzwerkeinstellungen HTTP ${response.statusCode}');
    }
    if (decoded is! Map) {
      throw Exception('Ungültige Antwort der Netzwerkeinstellungen');
    }
    final data = Map<String, dynamic>.from(decoded);
    networkAccessEnabled = data['lanEnabled'] == true;
    networkAdminPinConfigured = data['adminPinConfigured'] == true;
    networkAccessUrls = ((data['urls'] as List?) ?? const [])
        .map((item) => item.toString())
        .where((item) => item.isNotEmpty)
        .toList();
    notifyListeners();
    return data;
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
    double? salePriceEur,
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

    final eventAmounts = <String, double>{};
    final eventCosts = <String, double>{};
    final missingPriceIds = <String>[];
    var eventCost = 0.0;

    for (final part in recipe.parts) {
      final amountMl = actualPartAmountsMl?[part] ?? part.amountMl * scale;
      ingredientUsageMl.update(
        part.ingredientId,
        (value) => value + amountMl,
        ifAbsent: () => amountMl,
      );
      eventAmounts.update(
        part.ingredientId,
        (value) => value + amountMl,
        ifAbsent: () => amountMl,
      );
      final ingredient = ingredientById(part.ingredientId);
      if (ingredient == null || ingredient.pricePerLiter <= 0) {
        if (!missingPriceIds.contains(part.ingredientId)) {
          missingPriceIds.add(part.ingredientId);
        }
      } else {
        final partCost = amountMl / 1000 * ingredient.pricePerLiter;
        eventCost += partCost;
        eventCosts.update(
          part.ingredientId,
          (value) => value + partCost,
          ifAbsent: () => partCost,
        );
      }
      // Ein in der Einkaufsliste gepflegter Lagerbestand wird nach jeder
      // tatsaechlich zubereiteten Portion reduziert. Das gilt auch fuer
      // manuelle Rezeptbestandteile, weil sie ebenfalls verbraucht werden.
      _consumeShoppingInventory(part.ingredientId, amountMl);
    }

    consumptionHistory.add(
      ConsumptionRecord(
        timestamp: DateTime.now(),
        recipeId: recipe.id,
        recipeName: recipe.name,
        category: recipe.category,
        sizeMl: targetVolumeMl,
        ingredientAmountsMl: eventAmounts,
        ingredientCostsEur: eventCosts,
        totalCostEur: eventCost,
        missingPriceIngredientIds: missingPriceIds,
        salePriceEur: salePriceEur,
        partySessionId: runningParty?.id,
      ),
    );
    // Begrenze die lokale Historie auf einen sehr grosszuegigen Rahmen.
    // 5.000 Detaildatensaetze halten den Browser-Speicher klein; die bisherigen
    // Gesamtzaehler bleiben davon unberuehrt.
    if (consumptionHistory.length > 5000) {
      consumptionHistory.removeRange(0, consumptionHistory.length - 5000);
    }
  }

  Future<void> _syncRemoteConsumptionEvent(ConsumptionRecord record) async {
    if (!connected || !isRemoteBrowser || remoteAdminUnlocked) return;
    try {
      await http
          .post(
            _apiUri('/api/usage/record'),
            headers: _apiHeaders(json: true),
            body: jsonEncode({'record': record.toJson()}),
          )
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      // Die Zubereitung selbst ist bereits abgeschlossen. Statistik-Sync darf
      // deshalb niemals den erfolgreichen Cocktail nachträglich als Fehler markieren.
    }
  }

  double? shoppingInventoryFor(String ingredientId) =>
      shoppingInventoryMl[ingredientId];

  Future<void> saveShoppingInventory(
    Map<String, double?> values,
  ) async {
    for (final entry in values.entries) {
      final value = entry.value;
      if (value == null) {
        shoppingInventoryMl.remove(entry.key);
      } else {
        shoppingInventoryMl[entry.key] = math.max(0.0, value);
      }
    }
    await save();
    notifyListeners();
  }

  void _consumeShoppingInventory(String ingredientId, double amountMl) {
    if (amountMl <= 0 || !shoppingInventoryMl.containsKey(ingredientId)) {
      return;
    }
    final current = shoppingInventoryMl[ingredientId] ?? 0;
    shoppingInventoryMl[ingredientId] = math.max(0.0, current - amountMl);
  }

  Future<void> resetConsumptionStatistics() async {
    recipeDrinkCounts = {};
    servingSizeCounts = {};
    ingredientUsageMl = {};
    consumptionHistory.clear();
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

    if (minimumPortions <= lowStockWarningPortions.toDouble()) {
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
          headers: _apiHeaders(json: true),
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
      final sharedLoaded = await _loadSharedAppStateFromController();
      if (!sharedLoaded && !isRemoteBrowser) {
        await _syncAppStateToController();
      }
      try {
        await sendLedSettings();
      } catch (_) {
        // LED-Befehle dürfen eine funktionierende Pumpenverbindung nicht trennen.
      }
      await refreshCommercialLicenseStatus();
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
    Duration pollInterval = const Duration(milliseconds: 200),
    void Function(Map<String, dynamic> status)? onStatus,
  }) async {
    if (!connected || connectionMode == ConnectionMode.bluetooth) {
      return;
    }

    final started = DateTime.now();

    while (DateTime.now().difference(started) < timeout) {
      final statusData = await fetchMachineStatus();
      onStatus?.call(statusData);

      final busy = statusData['busy'] == true;
      if (!busy) {
        return;
      }

      await Future.delayed(pollInterval);
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

  Future<bool> syncFillLevelsToController() async {
    if (!connected || connectionMode == ConnectionMode.bluetooth) {
      return false;
    }

    try {
      await sendCommand({
        'action': 'save_fill_state',
        'pumps': pumps
            .map((pump) => {
                  'number': pump.number,
                  'remainingMl': pump.remainingMl,
                })
            .toList(),
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
    void Function(Map<String, dynamic> status)? onStatus,
    double? salePriceEur,
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

    await waitUntilMachineIdle(
      pollInterval: const Duration(milliseconds: 180),
      onStatus: onStatus,
    );

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
      salePriceEur: salePriceEur,
    );

    await save();
    if (consumptionHistory.isNotEmpty) {
      await _syncRemoteConsumptionEvent(consumptionHistory.last);
    }
    await syncFillLevelsToController();
    notifyListeners();
  }
}

extension FirstOrNull<E> on Iterable<E> { E? get firstOrNull => isEmpty ? null : first; }

class StartupLicenseGate extends StatefulWidget {
  const StartupLicenseGate({super.key, required this.store});

  final MachineStore store;

  @override
  State<StartupLicenseGate> createState() => _StartupLicenseGateState();
}

class _StartupLicenseGateState extends State<StartupLicenseGate> {
  bool _preferenceLoaded = false;
  bool _acceptedForSession = false;
  bool _doNotShowAgain = false;
  bool _closing = false;
  bool _rejected = false;
  bool _closeFailed = false;

  @override
  void initState() {
    super.initState();
    _loadPreference();
  }

  Future<void> _loadPreference() async {
    final preferences = await SharedPreferences.getInstance();
    final hiddenVersion =
        preferences.getInt(_cocktailBotUsageNoticePreferenceKey) ?? 0;
    if (!mounted) return;
    setState(() {
      _acceptedForSession = hiddenVersion >= _cocktailBotUsageNoticeVersion;
      _preferenceLoaded = true;
    });
  }

  Future<void> _accept() async {
    if (_doNotShowAgain) {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setInt(
        _cocktailBotUsageNoticePreferenceKey,
        _cocktailBotUsageNoticeVersion,
      );
    }
    if (!mounted) return;
    setState(() => _acceptedForSession = true);
  }

  Future<void> _decline() async {
    if (_closing || _rejected) return;

    // Ein entfernter Browser darf beim Ablehnen niemals den Chromium-Kiosk
    // auf dem Raspberry beenden. Dort sperren wir stattdessen nur diese
    // Browser-Sitzung. Am Raspberry selbst wird der bestehende Kiosk-Exit-
    // Endpunkt verwendet und Chromium sauber geschlossen.
    if (widget.store.isRemoteBrowser) {
      setState(() => _rejected = true);
      return;
    }

    setState(() => _closing = true);
    final closed = await widget.store.closeKioskApp();
    if (!mounted || closed) return;
    setState(() {
      _closing = false;
      _rejected = true;
      _closeFailed = true;
    });
  }

  Widget _loadingView() {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Center(
        child: CircularProgressIndicator(color: widget.store.appColors.accentColor),
      ),
    );
  }

  Widget _noticeCard(BuildContext context) {
    final colors = widget.store.appColors;
    final size = MediaQuery.sizeOf(context);
    final maxWidth = math.min(760.0, size.width - 28).toDouble();
    final maxHeight = math.min(620.0, size.height - 32).toDouble();

    if (_rejected) {
      return ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Card(
          elevation: 28,
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.block, color: colors.errorColor, size: 46),
                const SizedBox(height: 14),
                Text(
                  tr('Nutzung nicht akzeptiert'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 12),
                Text(
                  tr(_closeFailed
                      ? 'CocktailBot konnte nicht automatisch beendet werden. Die Anwendung bleibt gesperrt.'
                      : 'Die Nutzung wurde nicht akzeptiert. Bitte schließe dieses Browserfenster. Die CocktailBot-Maschine wurde nicht beendet.'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: colors.textSecondaryColor, height: 1.45),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return SizedBox(
      width: maxWidth,
      height: maxHeight,
      child: Card(
        elevation: 28,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 20, 22, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: colors.warningColor.withValues(alpha: .14),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(
                      Icons.gavel,
                      color: colors.warningColor,
                      size: 27,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          tr('Lizenz- und Nutzungshinweis'),
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Printcore · Sascha Wenning',
                          style: TextStyle(
                            color: colors.textSecondaryColor,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: colors.borderColor),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(22, 18, 22, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tr('Private Nutzung ohne Gewerbelizenz'),
                      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      tr('Die Nutzung von CocktailBot und der damit betriebenen Maschine ist ohne aktive Gewerbelizenz ausschließlich für private und nicht-kommerzielle Zwecke erlaubt.'),
                      style: const TextStyle(height: 1.45),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      tr('Eine gewerbliche Nutzung – zum Beispiel in der Gastronomie, in Unternehmen, auf gewerblichen Veranstaltungen oder zur entgeltlichen Abgabe von Getränken – ist ohne entsprechende Gewerbelizenz nicht gestattet.'),
                      style: const TextStyle(height: 1.45),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: colors.warningColor.withValues(alpha: .10),
                        border: Border.all(
                          color: colors.warningColor.withValues(alpha: .45),
                        ),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        tr('Für eine gewerbliche Nutzung ist eine gültige Printcore-Gewerbelizenz erforderlich.'),
                        style: const TextStyle(fontWeight: FontWeight.w800, height: 1.4),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      tr('Mit „Akzeptieren“ bestätigst du, dass du diesen Hinweis gelesen hast und CocktailBot ohne Gewerbelizenz nicht gewerblich nutzt.'),
                      style: const TextStyle(height: 1.45),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'Printcore · Sascha Wenning\nPrintcore@outlook.de',
                      style: TextStyle(
                        color: colors.textSecondaryColor,
                        fontWeight: FontWeight.w700,
                        height: 1.45,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Divider(height: 1, color: colors.borderColor),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
              child: Column(
                children: [
                  CheckboxListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                    value: _doNotShowAgain,
                    onChanged: _closing
                        ? null
                        : (value) => setState(
                              () => _doNotShowAgain = value == true,
                            ),
                    title: Text(
                      tr('Diesen Hinweis nicht mehr anzeigen'),
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    controlAffinity: ListTileControlAffinity.leading,
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _closing ? null : _decline,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: colors.errorColor,
                            side: BorderSide(color: colors.errorColor),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          icon: _closing
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.close),
                          label: Text(
                            tr(_closing ? 'CocktailBot wird beendet …' : 'Ablehnen'),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _closing ? null : _accept,
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          icon: const Icon(Icons.check),
                          label: Text(tr('Akzeptieren')),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_preferenceLoaded || !widget.store.loaded) {
      return _loadingView();
    }
    if (_acceptedForSession) {
      return HomeShell(store: widget.store);
    }

    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          children: [
            Positioned.fill(child: HomeShell(store: widget.store)),
            const Positioned.fill(
              child: ModalBarrier(
                dismissible: false,
                color: Color(0xB3000000),
              ),
            ),
            Positioned.fill(
              child: SafeArea(
                minimum: const EdgeInsets.all(14),
                child: Center(child: _noticeCard(context)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

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
              color: widget.store.appColors.navigationColor.withValues(alpha: .96),
              border: Border(
                top: BorderSide(color: widget.store.appColors.borderColor),
              ),
              boxShadow: widget.store.appColors.visualStyle == AppVisualStyle.neon
                  ? [
                      BoxShadow(
                        color: widget.store.appColors.accentColor.withValues(alpha: .16),
                        blurRadius: 16,
                      ),
                    ]
                  : null,
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
                                  : widget.store.appColors.navigationSecondaryTextColor,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              nav[i].$3,
                              maxLines: 1,
                              style: TextStyle(
                                fontSize: 11,
                                color: index == i
                                    ? widget.store.appColors.accentColor
                                    : widget.store.appColors.navigationSecondaryTextColor,
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
        decoration: cocktailBotNavigationDecoration(store.appColors),
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
                                      : store.appColors.navigationSecondaryTextColor,
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
                                          : store.appColors.navigationTextColor,
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
                                    : store.appColors.navigationSecondaryTextColor,
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
                                        : store.appColors.navigationTextColor,
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
                                    : store.appColors.navigationSecondaryTextColor,
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
                                      : store.appColors.navigationTextColor,
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
  const LogoMark({super.key, this.extended = false});
  final bool extended;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.local_bar, color: theme.colorScheme.primary, size: 39),
        Padding(
          padding: const EdgeInsets.only(left: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tr('CocktailBot'),
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: extended ? 22 : 16,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              if (extended)
                Text(
                  tr('Cocktail-Maschine'),
                  style: TextStyle(
                    color: theme.colorScheme.primary,
                    fontSize: 11,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class MachineStatusCard extends StatelessWidget {
  const MachineStatusCard({super.key, required this.store}); final MachineStore store;
  @override Widget build(BuildContext context) => Padding(padding: const EdgeInsets.symmetric(horizontal: 14), child: Container(
    padding: const EdgeInsets.all(14), decoration: BoxDecoration(color: store.appColors.surfaceColor, borderRadius: BorderRadius.circular(12), border: Border.all(color: store.appColors.borderColor)),
    child: Row(children: [Icon(Icons.memory, color: store.appColors.textSecondaryColor), const SizedBox(width: 12), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(store.t('machine'), style: const TextStyle(fontWeight: FontWeight.w700)), T('CocktailBot-RaspberryPi', style: TextStyle(fontSize: 11, color: store.appColors.textSecondaryColor)), Text(store.connected ? store.t('online') : store.t('offline'), style: TextStyle(fontSize: 11, color: store.connected ? store.appColors.successColor : store.appColors.warningColor))]) )]),
  ));
}

class AppHeader extends StatelessWidget {
  const AppHeader({
    super.key,
    required this.store,
    required this.title,
    this.subtitle,
    this.showSearch = false,
  });
  final MachineStore store;
  final String title;
  final String? subtitle;
  final bool showSearch;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: store.appColors.textPrimaryColor,
                      ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    subtitle!,
                    style: TextStyle(
                      color: store.appColors.textSecondaryColor,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (showSearch)
            IconButton(
              onPressed: () {},
              icon: Icon(Icons.search, color: store.appColors.accentColor),
            ),
        ],
      );
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
      color: store.appColors.cardColor,
      borderRadius: BorderRadius.circular(10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: store.appColors.borderColor,
          width: store.appColors.visualStyle == AppVisualStyle.neon ? 1.4 : 1,
        ),
      ),
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
                          ? store.appColors.errorColor
                          : store.appColors.warningColor,
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
                    ? '${widget.store.priceForRecipe(r, targetVolumeMl: selectedSizeMl).toStringAsFixed(2).replaceAll('.', ',')} € ${tr('bezahlen')}'
                    : '${selectedSizeMl.toStringAsFixed(0)} ml ${tr('zubereiten')}',
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
        ),
      );
    }

    List<Widget> detailWidgets() => [
          Text(
            tr('Beschreibung'),
            style: TextStyle(
              color: widget.store.appColors.accentColor,
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
            style: TextStyle(
              color: widget.store.appColors.accentColor,
              fontWeight: FontWeight.w900,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 7),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: widget.store.sizesFor(r.category).map((size) {
              final selected = size == selectedSizeMl;
              return ChoiceChip(
                label: Text(
                  '${size.toStringAsFixed(size % 1 == 0 ? 0 : 1)} ml',
                  style: TextStyle(
                    fontWeight: selected ? FontWeight.w900 : FontWeight.w700,
                  ),
                ),
                selected: selected,
                onSelected: working
                    ? null
                    : (value) {
                        if (!value) return;
                        setState(() {
                          selectedSizeMl = size;
                          selectedAlcoholPercent =
                              selectedAlcoholPercent.clamp(0, 25).toDouble();
                        });
                      },
              );
            }).toList(),
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
                Icon(Icons.local_bar, size: 17, color: widget.store.appColors.secondaryAccentColor),
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
                color: (unavailable
                        ? widget.store.appColors.errorColor
                        : widget.store.appColors.warningColor)
                    .withValues(alpha: .14),
                borderRadius: BorderRadius.circular(9),
                border: Border.all(
                  color: unavailable
                      ? widget.store.appColors.errorColor
                      : widget.store.appColors.warningColor,
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
                        ? widget.store.appColors.errorColor
                        : widget.store.appColors.warningColor,
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
            style: TextStyle(
              color: widget.store.appColors.accentColor,
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
                        ? widget.store.appColors.warningColor
                        : widget.store.appColors.accentColor,
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      widget.store.displayIngredientNameById(p.ingredientId),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (!p.automatic) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: widget.store.appColors.warningColor.withValues(alpha: .14),
                        borderRadius: BorderRadius.circular(7),
                        border: Border.all(
                          color: widget.store.appColors.warningColor.withValues(alpha: .75),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.pan_tool_alt_outlined,
                            size: 12,
                            color: widget.store.appColors.warningColor,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            tr('Manuell'),
                            style: TextStyle(
                              color: widget.store.appColors.warningColor,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(width: 8),
                  Text(
                    '${scaledAmount.toStringAsFixed(scaledAmount < 10 ? 1 : 0)} ml',
                    style: TextStyle(
                      color: widget.store.appColors.accentColor,
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
              style: TextStyle(
                color: widget.store.appColors.accentColor,
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
                    Icon(
                      Icons.info_outline,
                      size: 17,
                      color: widget.store.appColors.warningColor,
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
                    icon: Icon(Icons.arrow_back, color: widget.store.appColors.accentColor),
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
                                    color: widget.store.appColors.cardColor,
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
                          color: widget.store.appColors.cardColor,
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
    final shouldPrepare = await Navigator.push<bool>(
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

    if (!mounted || shouldPrepare != true) return;
    await _make(paid: true);
  }

  Future<void> _make({bool paid = false}) async {
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
        salePriceEur: paid
            ? widget.store.priceForRecipe(
                recipe,
                targetVolumeMl: selectedSizeMl,
              )
            : null,
        onStatus: (status) {
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

          progress.value = busy
              ? statusProgress.clamp(0, 1).toDouble()
              : 1.0;
          activePumps.value = runningPumps;
        },
      );

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

  Future<void> _unlock() async {
    final success = widget.store.isRemoteBrowser
        ? await widget.store.unlockRemoteAdmin(passwordController.text)
        : widget.store.validateSettingsPassword(passwordController.text);
    if (!mounted) return;
    if (success) {
      setState(() {
        unlocked = true;
        passwordController.clear();
      });
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          tr(widget.store.isRemoteBrowser
              ? 'Falscher Admin-PIN'
              : 'Falsches Passwort'),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final remote = widget.store.isRemoteBrowser;
    if ((!remote && !widget.store.settingsLockEnabled) ||
        unlocked ||
        (remote && widget.store.remoteAdminUnlocked)) {
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
                    tr(remote
                        ? 'Für Einstellungen vom Tablet oder PC bitte den Admin-PIN eingeben.'
                        : 'Bitte Passwort eingeben. Das Notfall-Passwort cocktailbot funktioniert immer.'),
                    style: TextStyle(
                      color: widget.store.appColors.textSecondaryColor,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 18),
                  TextField(
                    controller: passwordController,
                    obscureText: true,
                    keyboardType: remote ? TextInputType.number : null,
                    decoration: InputDecoration(
                      labelText: tr(remote ? 'Admin-PIN' : 'Passwort'),
                      prefixIcon: const Icon(Icons.password),
                    ),
                    onSubmitted: (_) { _unlock(); },
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () { _unlock(); },
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

    final accent = store.appColors.accentColor;
    final secondary = store.appColors.secondaryAccentColor;
    final success = store.appColors.successColor;
    final warning = store.appColors.warningColor;
    final error = store.appColors.errorColor;
    final mixed = Color.lerp(accent, secondary, .5)!;

    final items = [
      (store.t('settingsConnection'), store.connected ? tr('Raspberry Pi verbunden') : tr('Lokale GPIO-Steuerung'), Icons.wifi, accent, ConnectionPage(store: store)),
      (tr('Netzwerk & Tablet'), tr('Zugriff im lokalen WLAN/LAN und Admin-PIN'), Icons.devices, secondary, NetworkAccessSettingsPage(store: store)),
      (store.t('settingsLanguage'), '${store.t('settingsLanguageSub')}: ${store.appLanguage.nativeName}', Icons.language, secondary, LanguageSettingsPage(store: store)),
      (store.t('settingsDesign'), store.t('settingsDesignSub'), Icons.palette_outlined, accent, ThemeSettingsPage(store: store)),
      (store.t('Anzeige'), store.t('Sortierung und Cocktails pro Seite einstellen'), Icons.grid_view_outlined, mixed, CocktailDisplaySettingsPage(store: store)),
      (store.t('Sicherheit & Freigaben'), store.t('Stärkeregler und Einstellungs-Passwort'), Icons.admin_panel_settings_outlined, success, SecuritySettingsPage(store: store)),
      (store.t('settingsLed'), store.t('settingsLedSub'), Icons.light_mode_outlined, warning, LedSettingsPage(store: store)),
      (store.t('settingsCalibration'), store.t('settingsCalibrationSub'), Icons.science_outlined, secondary, CalibrationPage(store: store)),
      (store.t('settingsSizes'), store.t('settingsSizesSub'), Icons.straighten, mixed, ServingSizesPage(store: store)),
      (store.t('settingsFill'), store.t('settingsFillSub'), Icons.inventory_2_outlined, warning, FillLevelsPage(store: store)),
      (store.t('settingsCleaning'), store.t('settingsCleaningSub'), Icons.cleaning_services_outlined, error, SequencePage(store: store, cleaning: true)),
      (store.t('settingsPriming'), store.t('settingsPrimingSub'), Icons.air, error, SequencePage(store: store, cleaning: false)),
      (store.t('settingsIngredients'), store.t('settingsIngredientsSub'), Icons.local_drink_outlined, success, IngredientPage(store: store)),
      (store.t('settingsRecipes'), store.t('settingsRecipesSub'), Icons.receipt_long_outlined, secondary, RecipeManagementPage(store: store)),

      (tr('Info & Lizenz'), tr('Copyright, Kontakt und Nutzungsbedingungen'), Icons.info_outline, accent, InfoAndLicensePage(store: store)),

      // Lizenzbereich: alle lizenzpflichtigen Funktionen stehen gesammelt unten.
      (store.t('Gewerbelizenz'), store.commercialLicenseStatusText, Icons.verified_user_outlined, store.commercialLicenseActive ? success : warning, CommercialLicensePage(store: store)),
      (store.t('Verbrauchsstatistik'), commercialSubtitle(store.t('Cocktail-Ranking, Kosten und Zutatenverbrauch')), Icons.bar_chart_outlined, success, commercialPage(store.t('Verbrauchsstatistik'), ConsumptionStatisticsPage(store: store))),
      (store.t('Partykarten'), commercialSubtitle(store.t('Auswahl und Beliebtheit für Veranstaltungen')), Icons.fact_check_outlined, mixed, commercialPage(store.t('Partykarten'), PartyCardsPage(store: store))),
      (store.t('Partyplaner'), commercialSubtitle(store.t('Prognose aus vergangenen Partys')), Icons.event_available_outlined, secondary, commercialPage(store.t('Partyplaner'), PartyPlannerPage(store: store))),
      (store.t('Einkaufsliste'), commercialSubtitle(store.t('Zutatenbedarf und fehlende Mengen planen')), Icons.shopping_cart_outlined, warning, commercialPage(store.t('Einkaufsliste'), ShoppingListPage(store: store))),
      (store.t('PayPal Kassenmodus'), commercialSubtitle(store.t('Lokale PayPal-Zahlung über den Raspberry Pi')), Icons.payments_outlined, accent, commercialPage(store.t('PayPal Kassenmodus'), PaymentSettingsPage(store: store))),
      (store.t('Cocktailpreise'), commercialSubtitle(store.t('Einzelpreise pro Cocktail festlegen')), Icons.euro_outlined, success, commercialPage(store.t('Cocktailpreise'), CocktailPricesPage(store: store))),
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
                    backgroundColor: store.appColors.errorColor,
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
                              backgroundColor: store.appColors.errorColor,
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




class InfoAndLicensePage extends StatelessWidget {
  const InfoAndLicensePage({super.key, required this.store});

  final MachineStore store;

  Widget _sectionCard({
    required BuildContext context,
    required IconData icon,
    required String title,
    required Widget child,
  }) {
    final colors = store.appColors;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: colors.accentColor),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            child,
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = store.appColors;
    final statusColor = store.commercialLicenseActive
        ? colors.successColor
        : colors.warningColor;

    return PageFrame(
      title: tr('Info & Lizenz'),
      child: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          _sectionCard(
            context: context,
            icon: Icons.copyright,
            title: tr('Entwicklung & Copyright'),
            child: Text(
              '© 2026 Sascha Wenning / Printcore\n${tr('Alle Rechte vorbehalten.')}',
              style: const TextStyle(height: 1.5, fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: 12),
          _sectionCard(
            context: context,
            icon: Icons.mail_outline,
            title: tr('Kontakt'),
            child: SelectableText(
              'Sascha Wenning\nPrintcore\nPrintcore@outlook.de',
              style: const TextStyle(height: 1.55),
            ),
          ),
          const SizedBox(height: 12),
          _sectionCard(
            context: context,
            icon: Icons.policy,
            title: tr('Nutzungsrecht'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _LicenseUseRow(
                  icon: Icons.person_outline,
                  title: tr('Ohne Gewerbelizenz'),
                  text: tr('Nur private und nicht-kommerzielle Nutzung'),
                  color: colors.warningColor,
                ),
                const SizedBox(height: 12),
                _LicenseUseRow(
                  icon: Icons.business_center,
                  title: tr('Mit gültiger Gewerbelizenz'),
                  text: tr('Gewerbliche Nutzung gemäß Lizenzumfang erlaubt'),
                  color: colors.successColor,
                ),
                const SizedBox(height: 16),
                Text(
                  tr('Die Nutzung von CocktailBot und der damit betriebenen Maschine ist ohne aktive Gewerbelizenz ausschließlich für private und nicht-kommerzielle Zwecke erlaubt.'),
                  style: const TextStyle(height: 1.5),
                ),
                const SizedBox(height: 12),
                Text(
                  tr('Als gewerbliche Nutzung gilt insbesondere der Einsatz im Rahmen eines Unternehmens, Gewerbes, einer Gastronomie, eines Caterings, einer gewerblichen Veranstaltung oder die entgeltliche Abgabe von Getränken oder Dienstleistungen.'),
                  style: const TextStyle(height: 1.5),
                ),
                const SizedBox(height: 12),
                Text(
                  tr('Die Software und die zugehörigen Inhalte sind urheberrechtlich geschützt. Eine unerlaubte Vervielfältigung, Weitergabe, Veröffentlichung oder kommerzielle Nutzung außerhalb des eingeräumten Lizenzumfangs ist nicht gestattet.'),
                  style: const TextStyle(height: 1.5),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr('Aktueller Lizenzstatus'),
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: statusColor.withValues(alpha: .10),
                      border: Border.all(color: statusColor.withValues(alpha: .40)),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          store.commercialLicenseActive
                              ? Icons.verified
                              : Icons.lock_outline,
                          color: statusColor,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            store.commercialLicenseStatusText,
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => CommercialLicensePage(store: store),
                        ),
                      ),
                      icon: const Icon(Icons.verified_user_outlined),
                      label: Text(tr('Gewerbelizenz verwalten')),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        final preferences = await SharedPreferences.getInstance();
                        await preferences.remove(
                          _cocktailBotUsageNoticePreferenceKey,
                        );
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              tr('Der Lizenz- und Nutzungshinweis wird beim nächsten Start wieder angezeigt.'),
                            ),
                          ),
                        );
                      },
                      icon: const Icon(Icons.restart_alt),
                      label: Text(tr('Start-Hinweis wieder anzeigen')),
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

class _LicenseUseRow extends StatelessWidget {
  const _LicenseUseRow({
    required this.icon,
    required this.title,
    required this.text,
    required this.color,
  });

  final IconData icon;
  final String title;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: color.withValues(alpha: .12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: color, size: 22),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w900)),
              const SizedBox(height: 3),
              Text(text, style: const TextStyle(height: 1.35)),
            ],
          ),
        ),
      ],
    );
  }
}

class NetworkAccessSettingsPage extends StatefulWidget {
  const NetworkAccessSettingsPage({super.key, required this.store});
  final MachineStore store;

  @override
  State<NetworkAccessSettingsPage> createState() =>
      _NetworkAccessSettingsPageState();
}

class _NetworkAccessSettingsPageState
    extends State<NetworkAccessSettingsPage> {
  final pinController = TextEditingController();
  bool enabled = false;
  bool pinConfigured = false;
  bool loading = true;
  bool saving = false;
  String? error;
  List<String> urls = [];

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    pinController.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final data = await widget.store.refreshNetworkAccessStatus();
      if (!mounted) return;
      setState(() {
        enabled = data['lanEnabled'] == true;
        pinConfigured = data['adminPinConfigured'] == true;
        urls = ((data['urls'] as List?) ?? const [])
            .map((item) => item.toString())
            .where((item) => item.isNotEmpty)
            .toList();
        loading = false;
        error = null;
      });
    } catch (exc) {
      if (!mounted) return;
      setState(() {
        loading = false;
        error = exc.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _save() async {
    final pin = pinController.text.trim();
    if (enabled && !pinConfigured && pin.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('Bitte zuerst einen Admin-PIN festlegen'))),
      );
      return;
    }
    if (pin.isNotEmpty && !RegExp(r'^\d{4,8}$').hasMatch(pin)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('Admin-PIN muss aus 4 bis 8 Ziffern bestehen'))),
      );
      return;
    }

    setState(() => saving = true);
    try {
      final data = await widget.store.saveNetworkAccessSettings(
        enabled: enabled,
        adminPin: pin,
      );
      if (!mounted) return;
      pinController.clear();
      setState(() {
        enabled = data['lanEnabled'] == true;
        pinConfigured = data['adminPinConfigured'] == true;
        urls = ((data['urls'] as List?) ?? const [])
            .map((item) => item.toString())
            .where((item) => item.isNotEmpty)
            .toList();
        saving = false;
        error = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('Netzwerkeinstellungen gespeichert'))),
      );
    } catch (exc) {
      if (!mounted) return;
      setState(() {
        saving = false;
        error = exc.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.store.appColors;
    return PageFrame(
      title: tr('Netzwerk & Tablet'),
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.tablet_android, size: 30),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          tr('CocktailBot auf Tablet oder PC öffnen'),
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 18,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          tr('Der Zugriff funktioniert nur im gleichen lokalen WLAN/LAN. CocktailBot wird nicht für das Internet freigegeben.'),
                          style: TextStyle(
                            color: colors.textSecondaryColor,
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
            child: SwitchListTile(
              value: enabled,
              onChanged: loading || saving
                  ? null
                  : (value) => setState(() => enabled = value),
              secondary: Icon(enabled ? Icons.lan : Icons.lan),
              title: Text(tr('Zugriff im lokalen Netzwerk erlauben')),
              subtitle: Text(
                tr(enabled
                    ? 'Tablet- und PC-Zugriff ist aktiviert.'
                    : 'Nur der Raspberry selbst kann CocktailBot öffnen.'),
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
                    tr('Admin-PIN'),
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 18,
                    ),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    tr('Vom Tablet oder PC sind die Einstellungen nur nach Eingabe dieses PINs erreichbar. Cocktails können ohne Admin-PIN ausgewählt und zubereitet werden.'),
                    style: TextStyle(
                      color: colors.textSecondaryColor,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: pinController,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    maxLength: 8,
                    decoration: InputDecoration(
                      labelText: pinConfigured
                          ? tr('Admin-PIN ändern')
                          : tr('Admin-PIN festlegen'),
                      helperText: pinConfigured
                          ? tr('Leer lassen, wenn der vorhandene PIN bleiben soll')
                          : tr('4 bis 8 Ziffern'),
                      prefixIcon: const Icon(Icons.dialpad),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (enabled) ...[
            const SizedBox(height: 14),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tr('Adresse für Tablet oder PC'),
                      style: const TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 18,
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (urls.isEmpty)
                      Text(tr('Keine Netzwerkadresse erkannt.'))
                    else
                      ...urls.map(
                        (url) => Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Row(
                            children: [
                              Expanded(
                                child: SelectableText(
                                  url,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                              IconButton(
                                tooltip: tr('Kopieren'),
                                onPressed: () async {
                                  await Clipboard.setData(ClipboardData(text: url));
                                  if (!mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text(tr('Adresse kopiert'))),
                                  );
                                },
                                icon: const Icon(Icons.copy_outlined),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
          if (error != null) ...[
            const SizedBox(height: 14),
            Card(
              child: ListTile(
                leading: Icon(Icons.error_outline, color: colors.errorColor),
                title: Text(tr('Netzwerkfehler')),
                subtitle: Text(error!),
              ),
            ),
          ],
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: loading || saving ? null : _save,
              icon: saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined),
              label: Text(tr(saving ? 'Speichere …' : 'Speichern')),
            ),
          ),
          const SizedBox(height: 12),
          TextButton.icon(
            onPressed: loading ? null : _refresh,
            icon: const Icon(Icons.refresh),
            label: Text(tr('Netzwerkstatus aktualisieren')),
          ),
        ],
      ),
    );
  }
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
                      'Diese Einstellungen gelten für Cocktails, alkoholfreie Cocktails und Shots. Auf den Cocktail-Seiten selbst wird die obere Navigation angezeigt.',
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
      'Standard / Benutzerdefiniert',
      AppColorThemeConfig(
        visualStyle: AppVisualStyle.custom,
        background: 0xFF070907,
        surface: 0xFF0B0E0B,
        card: 0xFF101410,
        navigation: 0xFF050705,
        accent: 0xFFB7FF00,
        secondaryAccent: 0xFF7DFF00,
        border: 0xFF33451F,
        textPrimary: 0xFFF4F7F2,
        textSecondary: 0xFFAEB7AA,
        progressTrack: 0xFF1E2A17,
        success: 0xFF68E28D,
        warning: 0xFFFFB300,
        error: 0xFFFF3B30,
      ),
    ),
    (
      'Edel / Exklusiv',
      AppColorThemeConfig(
        visualStyle: AppVisualStyle.elegant,
        background: 0xFF070707,
        surface: 0xFF0D0D0D,
        card: 0xFF14120E,
        navigation: 0xFF090909,
        accent: 0xFFD8A62A,
        secondaryAccent: 0xFFFFD76A,
        border: 0xFF5A4618,
        textPrimary: 0xFFFFF8E7,
        textSecondary: 0xFFC8B98F,
        progressTrack: 0xFF2A2417,
        success: 0xFF54D68B,
        warning: 0xFFFFB84D,
        error: 0xFFFF6565,
      ),
    ),
    (
      'Modern / Clean',
      AppColorThemeConfig(
        visualStyle: AppVisualStyle.modern,
        background: 0xFFF3F6FA,
        surface: 0xFFFFFFFF,
        card: 0xFFFFFFFF,
        navigation: 0xFFF9FBFD,
        accent: 0xFF1976F3,
        secondaryAccent: 0xFF65A9FF,
        border: 0xFFD7E0EA,
        textPrimary: 0xFF15202B,
        textSecondary: 0xFF667789,
        progressTrack: 0xFFDDE7F1,
        success: 0xFF20A66A,
        warning: 0xFFE79A22,
        error: 0xFFE14F4F,
      ),
    ),
    (
      'Futuristisch / Neon',
      AppColorThemeConfig(
        visualStyle: AppVisualStyle.neon,
        background: 0xFF020817,
        surface: 0xFF071127,
        card: 0xFF0A1530,
        navigation: 0xFF030C1E,
        accent: 0xFF00E7FF,
        secondaryAccent: 0xFFFF2BBF,
        border: 0xFF164D79,
        textPrimary: 0xFFF4FBFF,
        textSecondary: 0xFF83BBD1,
        progressTrack: 0xFF132844,
        success: 0xFF32F6A2,
        warning: 0xFFFFD64A,
        error: 0xFFFF397A,
      ),
    ),
    (
      'Tropisch / Sommer',
      AppColorThemeConfig(
        visualStyle: AppVisualStyle.tropical,
        background: 0xFFE8F8F4,
        surface: 0xFFD7F4EE,
        card: 0xFFFFFEF8,
        navigation: 0xFF08A7B7,
        accent: 0xFFFF7A1A,
        secondaryAccent: 0xFF15C6C0,
        border: 0xFF74D1C8,
        textPrimary: 0xFF123E43,
        textSecondary: 0xFF4F7778,
        progressTrack: 0xFFBFE8E0,
        success: 0xFF2DBB72,
        warning: 0xFFFFA928,
        error: 0xFFF24D61,
      ),
    ),
    (
      'Industrial / Loft',
      AppColorThemeConfig(
        visualStyle: AppVisualStyle.industrial,
        background: 0xFF171513,
        surface: 0xFF24211E,
        card: 0xFF302B26,
        navigation: 0xFF1B1815,
        accent: 0xFFE88719,
        secondaryAccent: 0xFFB9A17F,
        border: 0xFF5B5045,
        textPrimary: 0xFFF2EEE8,
        textSecondary: 0xFFB9AEA2,
        progressTrack: 0xFF443C34,
        success: 0xFF69BD79,
        warning: 0xFFFFAE3A,
        error: 0xFFE45F50,
      ),
    ),
    (
      'Vintage / Klassisch',
      AppColorThemeConfig(
        visualStyle: AppVisualStyle.vintage,
        background: 0xFFF0DFC0,
        surface: 0xFFF8E8C9,
        card: 0xFFFFF1D2,
        navigation: 0xFFE6C996,
        accent: 0xFF7A3F12,
        secondaryAccent: 0xFFC58A3B,
        border: 0xFFB48A55,
        textPrimary: 0xFF3A2616,
        textSecondary: 0xFF76583C,
        progressTrack: 0xFFD9BE91,
        success: 0xFF578A4D,
        warning: 0xFFC8791F,
        error: 0xFFB94B3D,
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
        a.error == b.error &&
        a.visualStyle == b.visualStyle;
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
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: theme.borderColor),
                ),
                clipBehavior: Clip.antiAlias,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: CocktailBotThemeBackground(colors: theme),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(10),
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
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Text(
                tr(preset.$1),
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
                ? tr('LED-Einstellungen wurden übernommen')
                : tr(
                    'LED-Einstellungen gespeichert. Sie werden beim nächsten Verbinden übertragen.',
                  ),
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
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.info_outline,
                            color: store.appColors.accentColor,
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
                          color: store.appColors.textSecondaryColor,
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

class FillLevelsPage extends StatefulWidget {
  const FillLevelsPage({super.key, required this.store});
  final MachineStore store;

  @override
  State<FillLevelsPage> createState() => _FillLevelsPageState();
}

class _FillLevelsPageState extends State<FillLevelsPage> {
  @override
  void initState() {
    super.initState();
    unawaited(_refreshPumpState());
  }

  Future<void> _refreshPumpState() async {
    if (!widget.store.connected) return;
    await widget.store.loadMachineStateFromController();
    if (mounted) setState(() {});
  }

  Future<void> _setLowStockWarning(int value) async {
    setState(() {
      widget.store.lowStockWarningPortions = value.clamp(1, 10).toInt();
    });
    await widget.store.save();
  }

  Future<void> _setLowFillWarning(int value) async {
    setState(() {
      widget.store.lowFillWarningPercent = value.clamp(5, 90).toInt();
    });
    await widget.store.save();
  }

  Widget _thresholdPanel({
    required IconData icon,
    required Color color,
    required String title,
    required String valueText,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required ValueChanged<double> onChanged,
    required ValueChanged<double> onChangeEnd,
  }) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: .38)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: .16),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: color, size: 22),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: .18),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  valueText,
                  style: TextStyle(
                    color: color,
                    fontWeight: FontWeight.w900,
                    fontSize: 15,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SliderTheme(
            data: theme.sliderTheme.copyWith(
              activeTrackColor: color,
              inactiveTrackColor: color.withValues(alpha: .18),
              thumbColor: color,
              overlayColor: color.withValues(alpha: .12),
              trackHeight: 5,
            ),
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: divisions,
              onChanged: onChanged,
              onChangeEnd: onChangeEnd,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final activePumps = store.pumps.where((pump) => pump.active).toList();

    return PageFrame(
      title: tr('Füllstände'),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.tune_rounded,
                        color: store.appColors.warningColor,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          tr('Warnschwellen'),
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final compact = constraints.maxWidth < 620;
                      final portions = _thresholdPanel(
                        icon: Icons.local_bar_rounded,
                        color: store.appColors.accentColor,
                        title: tr('Cocktailkarte orange ab'),
                        valueText:
                            '≤ ${store.lowStockWarningPortions} ${tr('Restcocktails')}',
                        value: store.lowStockWarningPortions.toDouble(),
                        min: 1,
                        max: 10,
                        divisions: 9,
                        onChanged: (raw) {
                          setState(() {
                            store.lowStockWarningPortions = raw.round();
                          });
                        },
                        onChangeEnd: (raw) =>
                            _setLowStockWarning(raw.round()),
                      );
                      final fill = _thresholdPanel(
                        icon: Icons.water_drop_rounded,
                        color: store.appColors.warningColor,
                        title: tr('Füllstandsseite orange unter'),
                        valueText: '≤ ${store.lowFillWarningPercent} %',
                        value: store.lowFillWarningPercent.toDouble(),
                        min: 5,
                        max: 90,
                        divisions: 17,
                        onChanged: (raw) {
                          setState(() {
                            store.lowFillWarningPercent =
                                (raw / 5).round() * 5;
                          });
                        },
                        onChangeEnd: (raw) =>
                            _setLowFillWarning((raw / 5).round() * 5),
                      );

                      if (compact) {
                        return Column(
                          children: [
                            portions,
                            const SizedBox(height: 10),
                            fill,
                          ],
                        );
                      }
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: portions),
                          const SizedBox(width: 12),
                          Expanded(child: fill),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 8),
                  Text(
                    tr('Diese Werte bestimmen nur die Warnanzeige. Die tatsächliche Verfügbarkeit wird weiterhin aus der benötigten Rezeptmenge berechnet.'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (activePumps.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Center(child: Text(tr('Keine Pumpen aktiviert'))),
            )
          else
            LayoutBuilder(
              builder: (context, constraints) {
                final columns = constraints.maxWidth >= 820
                    ? 3
                    : constraints.maxWidth >= 540
                        ? 2
                        : 1;
                return GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: activePumps.length,
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                    mainAxisExtent: 304,
                  ),
                  itemBuilder: (context, index) => FillCard(
                    store: store,
                    pump: activePumps[index],
                  ),
                );
              },
            ),
        ],
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
    final lowFill = percent <= widget.store.lowFillWarningPercent;
    final warning = widget.store.appColors.warningColor;

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: widget.store.appColors.accentColor.withValues(alpha: .14),
                    borderRadius: BorderRadius.circular(11),
                    border: Border.all(
                      color: widget.store.appColors.accentColor.withValues(alpha: .38),
                    ),
                  ),
                  child: Text(
                    '${widget.pump.number}',
                    style: TextStyle(
                      color: widget.store.appColors.accentColor,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    widget.store.displayIngredientName(ing),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 14,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: (lowFill ? warning : widget.store.appColors.successColor)
                        .withValues(alpha: .12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '$percent%',
                    style: TextStyle(
                      color: lowFill ? warning : widget.store.appColors.successColor,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            LinearProgressIndicator(
              value: widget.pump.level,
              color: lowFill ? warning : widget.store.appColors.accentColor,
              minHeight: 9,
              borderRadius: BorderRadius.circular(20),
            ),
            const SizedBox(height: 5),
            Text(
              '${widget.pump.remainingMl.toStringAsFixed(0)} / '
              '${widget.pump.capacityMl.toStringAsFixed(0)} ml',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: capacity,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: tr('Behältergröße'),
                suffixText: tr('ml'),
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 11, vertical: 11),
              ),
              onSubmitted: (_) => _saveValues(),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: remaining,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: tr('Aktueller Füllstand'),
                suffixText: tr('ml'),
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 11, vertical: 11),
              ),
              onSubmitted: (_) => _saveValues(),
            ),
            const Spacer(),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _saveValues,
                    icon: const Icon(Icons.save_outlined, size: 18),
                    label: Text(tr('Speichern')),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.tonalIcon(
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
                    icon: const Icon(Icons.water_drop_outlined, size: 18),
                    label: Text(tr('Auffüllen')),
                  ),
                ),
              ],
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
                        ? '${tr('Pumpe')} $currentPump ${tr('läuft')}'
                        : tr('Nächste Pumpe wird vorbereitet'),
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
              children: [
                Row(
                  children: [
                    Icon(Icons.info_outline, color: widget.store.appColors.accentColor),
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
                    color: widget.store.appColors.textSecondaryColor,
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
              children: [
                Row(
                  children: [
                    Icon(Icons.info_outline, color: widget.store.appColors.errorColor),
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
                    color: widget.store.appColors.textSecondaryColor,
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
    return PageFrame(
      title: tr('Getränkegrößen'),
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _sizeSection(
            title: tr('Größen für Cocktails'),
            description: tr(
              'Mehrere Größen können gleichzeitig aktiviert werden. Die Standardgröße ist beim Öffnen eines Cocktails vorausgewählt.',
            ),
            sizes: widget.store.servingSizes,
            enabledSizes: widget.store.enabledServingSizes,
            defaultSize: widget.store.defaultServingSizeMl,
            controller: cocktailController,
            onDefaultChanged: (value) async {
              if (!widget.store.enabledServingSizes.contains(value)) {
                widget.store.enabledServingSizes.add(value);
                widget.store.enabledServingSizes.sort();
              }
              widget.store.defaultServingSizeMl = value;
              await widget.store.save();
              if (mounted) setState(() {});
            },
            onEnabledChanged: (value, enabled) async {
              if (enabled) {
                if (!widget.store.enabledServingSizes.contains(value)) {
                  widget.store.enabledServingSizes.add(value);
                  widget.store.enabledServingSizes.sort();
                }
              } else {
                widget.store.enabledServingSizes.remove(value);
              }
              await widget.store.save();
              if (mounted) setState(() {});
            },
            onAdd: () => _addSize(
              controller: cocktailController,
              sizes: widget.store.servingSizes,
              enabledSizes: widget.store.enabledServingSizes,
              setDefault: (value) => widget.store.defaultServingSizeMl = value,
            ),
            onDelete: (value) async {
              widget.store.servingSizes.remove(value);
              widget.store.enabledServingSizes.remove(value);
              await widget.store.save();
              if (mounted) setState(() {});
            },
          ),
          const SizedBox(height: 24),
          _sizeSection(
            title: tr('Größen für Shots'),
            description: tr(
              'Mehrere Größen können gleichzeitig aktiviert werden. Die Standardgröße ist beim Öffnen eines Cocktails vorausgewählt.',
            ),
            sizes: widget.store.shotSizes,
            enabledSizes: widget.store.enabledShotSizes,
            defaultSize: widget.store.defaultShotSizeMl,
            controller: shotController,
            onDefaultChanged: (value) async {
              if (!widget.store.enabledShotSizes.contains(value)) {
                widget.store.enabledShotSizes.add(value);
                widget.store.enabledShotSizes.sort();
              }
              widget.store.defaultShotSizeMl = value;
              await widget.store.save();
              if (mounted) setState(() {});
            },
            onEnabledChanged: (value, enabled) async {
              if (enabled) {
                if (!widget.store.enabledShotSizes.contains(value)) {
                  widget.store.enabledShotSizes.add(value);
                  widget.store.enabledShotSizes.sort();
                }
              } else {
                widget.store.enabledShotSizes.remove(value);
              }
              await widget.store.save();
              if (mounted) setState(() {});
            },
            onAdd: () => _addSize(
              controller: shotController,
              sizes: widget.store.shotSizes,
              enabledSizes: widget.store.enabledShotSizes,
              setDefault: (value) => widget.store.defaultShotSizeMl = value,
            ),
            onDelete: (value) async {
              widget.store.shotSizes.remove(value);
              widget.store.enabledShotSizes.remove(value);
              await widget.store.save();
              if (mounted) setState(() {});
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
    required List<double> enabledSizes,
    required double defaultSize,
    required TextEditingController controller,
    required ValueChanged<double> onDefaultChanged,
    required void Function(double value, bool enabled) onEnabledChanged,
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

    final selectableDefaults = sizes
        .where(enabledSizes.contains)
        .toList()
      ..sort();

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
              key: ValueKey('$title-$defaultSize-${selectableDefaults.join(',')}'),
              initialValue: selectableDefaults.contains(defaultSize)
                  ? defaultSize
                  : null,
              decoration: InputDecoration(
                labelText: tr('Standardgröße'),
              ),
              items: selectableDefaults
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
            ...sizes.map((size) {
              final enabled = enabledSizes.contains(size);
              final isDefault = size == defaultSize;
              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Checkbox(
                  value: enabled,
                  onChanged: isDefault
                      ? null
                      : (value) => onEnabledChanged(size, value ?? false),
                ),
                title: Text(label(size)),
                subtitle: Text(
                  isDefault
                      ? tr('Aktuelle Standardgröße')
                      : enabled
                          ? tr('Verfügbare Größe')
                          : tr('Nicht verfügbar'),
                ),
                trailing: isDefault
                    ? const Icon(Icons.star, color: Color(0xFFFFC857))
                    : IconButton(
                        tooltip: tr('Größe löschen'),
                        onPressed: () => onDelete(size),
                        icon: const Icon(Icons.delete_outline),
                      ),
                onTap: isDefault
                    ? null
                    : () => onEnabledChanged(size, !enabled),
              );
            }),
          ],
        ),
      ),
    );
  }

  Future<void> _addSize({
    required TextEditingController controller,
    required List<double> sizes,
    required List<double> enabledSizes,
    required ValueChanged<double> setDefault,
  }) async {
    final value = double.tryParse(controller.text.replaceAll(',', '.'));
    if (value == null || value <= 0) return;

    if (!sizes.contains(value)) {
      sizes.add(value);
      sizes.sort();
    }
    if (!enabledSizes.contains(value)) {
      enabledSizes.add(value);
      enabledSizes.sort();
    }
    setDefault(value);
    controller.clear();
    await widget.store.save();
    if (mounted) setState(() {});
  }
}

enum _StatisticsPeriod { today, sevenDays, thirtyDays, party, all }
enum _StatisticsView { cocktails, ingredients }
enum _StatisticsSort { frequency, cost, name, recent }

class _SizeConsumptionAggregate {
  _SizeConsumptionAggregate(this.sizeMl);
  final double sizeMl;
  int count = 0;
  double totalCost = 0;
  double revenue = 0;
  int missingPriceCount = 0;

  double get averageCost => count == 0 ? 0.0 : totalCost / count;
}

class _RecipeConsumptionAggregate {
  _RecipeConsumptionAggregate({
    required this.recipeId,
    required this.name,
    required this.category,
  });

  final String recipeId;
  final String name;
  final DrinkCategory category;
  int count = 0;
  double totalCost = 0;
  double totalVolumeMl = 0;
  double revenue = 0;
  int missingPriceCount = 0;
  DateTime? lastPreparedAt;
  final Map<int, _SizeConsumptionAggregate> sizes = {};

  double get averageCost => count == 0 ? 0.0 : totalCost / count;
}

class _IngredientConsumptionAggregate {
  _IngredientConsumptionAggregate(this.ingredientId);
  final String ingredientId;
  double amountMl = 0;
  double totalCost = 0;
  int missingPriceUses = 0;
}

class ConsumptionStatisticsPage extends StatefulWidget {
  const ConsumptionStatisticsPage({
    super.key,
    required this.store,
  });

  final MachineStore store;

  @override
  State<ConsumptionStatisticsPage> createState() =>
      _ConsumptionStatisticsPageState();
}

class _ConsumptionStatisticsPageState extends State<ConsumptionStatisticsPage> {
  _StatisticsPeriod period = _StatisticsPeriod.all;
  _StatisticsView view = _StatisticsView.cocktails;
  _StatisticsSort sort = _StatisticsSort.frequency;

  MachineStore get store => widget.store;

  @override
  void initState() {
    super.initState();
    unawaited(_refreshSharedStatistics());
  }

  Future<void> _refreshSharedStatistics() async {
    if (!store.connected) return;
    await store._loadSharedAppStateFromController();
    if (mounted) setState(() {});
  }

  String _money(double value) =>
      '${value.toStringAsFixed(2).replaceAll('.', ',')} €';

  String _ml(double value) {
    if (value >= 1000) {
      final decimals = value >= 10000 ? 1 : 2;
      return '${(value / 1000).toStringAsFixed(decimals).replaceAll('.', ',')} L';
    }
    return '${value.toStringAsFixed(0)} ml';
  }

  String _periodLabel(_StatisticsPeriod value) => switch (value) {
        _StatisticsPeriod.today => tr('Heute'),
        _StatisticsPeriod.sevenDays => tr('7 Tage'),
        _StatisticsPeriod.thirtyDays => tr('30 Tage'),
        _StatisticsPeriod.party => tr('Party'),
        _StatisticsPeriod.all => tr('Gesamt'),
      };

  String _sortLabel(_StatisticsSort value) => switch (value) {
        _StatisticsSort.frequency => tr('Häufigkeit'),
        _StatisticsSort.cost => tr('Kosten'),
        _StatisticsSort.name => tr('Name'),
        _StatisticsSort.recent => tr('Zuletzt'),
      };

  String? _partySessionIdForFilter() {
    final active = store.activePartySession();
    if (active != null) return active.id;
    final sessions = store.partySessions.toList()
      ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return sessions.firstOrNull?.id;
  }

  List<ConsumptionRecord> _filteredRecords() {
    final now = DateTime.now();
    switch (period) {
      case _StatisticsPeriod.today:
        final start = DateTime(now.year, now.month, now.day);
        return store.consumptionHistory
            .where((event) => !event.timestamp.isBefore(start))
            .toList();
      case _StatisticsPeriod.sevenDays:
        final start = now.subtract(const Duration(days: 7));
        return store.consumptionHistory
            .where((event) => !event.timestamp.isBefore(start))
            .toList();
      case _StatisticsPeriod.thirtyDays:
        final start = now.subtract(const Duration(days: 30));
        return store.consumptionHistory
            .where((event) => !event.timestamp.isBefore(start))
            .toList();
      case _StatisticsPeriod.party:
        final partyId = _partySessionIdForFilter();
        if (partyId == null) return [];
        return store.consumptionHistory
            .where((event) => event.partySessionId == partyId)
            .toList();
      case _StatisticsPeriod.all:
        return List<ConsumptionRecord>.from(store.consumptionHistory);
    }
  }

  List<_RecipeConsumptionAggregate> _recipeAggregates(
    List<ConsumptionRecord> records,
  ) {
    final data = <String, _RecipeConsumptionAggregate>{};
    for (final event in records) {
      final current = data.putIfAbsent(
        event.recipeId,
        () => _RecipeConsumptionAggregate(
          recipeId: event.recipeId,
          name: event.recipeName,
          category: event.category,
        ),
      );
      current.count++;
      current.totalCost += event.totalCostEur;
      current.totalVolumeMl += event.sizeMl;
      current.revenue += event.salePriceEur ?? 0;
      if (event.missingPriceIngredientIds.isNotEmpty) {
        current.missingPriceCount++;
      }
      if (current.lastPreparedAt == null ||
          event.timestamp.isAfter(current.lastPreparedAt!)) {
        current.lastPreparedAt = event.timestamp;
      }
      final sizeKey = event.sizeMl.round();
      final size = current.sizes.putIfAbsent(
        sizeKey,
        () => _SizeConsumptionAggregate(event.sizeMl),
      );
      size.count++;
      size.totalCost += event.totalCostEur;
      size.revenue += event.salePriceEur ?? 0;
      if (event.missingPriceIngredientIds.isNotEmpty) {
        size.missingPriceCount++;
      }
    }

    final result = data.values.toList();
    switch (sort) {
      case _StatisticsSort.frequency:
        result.sort((a, b) => b.count.compareTo(a.count));
        break;
      case _StatisticsSort.cost:
        result.sort((a, b) => b.totalCost.compareTo(a.totalCost));
        break;
      case _StatisticsSort.name:
        result.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        break;
      case _StatisticsSort.recent:
        result.sort((a, b) => (b.lastPreparedAt ?? DateTime(1970))
            .compareTo(a.lastPreparedAt ?? DateTime(1970)));
        break;
    }
    return result;
  }

  List<_IngredientConsumptionAggregate> _ingredientAggregates(
    List<ConsumptionRecord> records,
  ) {
    final data = <String, _IngredientConsumptionAggregate>{};
    for (final event in records) {
      for (final entry in event.ingredientAmountsMl.entries) {
        final item = data.putIfAbsent(
          entry.key,
          () => _IngredientConsumptionAggregate(entry.key),
        );
        item.amountMl += entry.value;
        item.totalCost += event.ingredientCostsEur[entry.key] ?? 0;
        if (event.missingPriceIngredientIds.contains(entry.key)) {
          item.missingPriceUses++;
        }
      }
    }
    final result = data.values.toList()
      ..sort((a, b) => b.amountMl.compareTo(a.amountMl));
    return result;
  }

  String _categoryName(DrinkCategory category) => switch (category) {
        DrinkCategory.cocktail => tr('Cocktail'),
        DrinkCategory.mocktail => tr('Alkoholfrei'),
        DrinkCategory.shot => tr('Shot'),
      };

  Future<void> _reset() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr('Statistik zurücksetzen?')),
        content: Text(
          tr('Cocktail-Ranking, Größenstatistik, Kostenhistorie und Zutatenverbrauch werden gelöscht. Füllstände und Kalibrierungen bleiben erhalten.'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(tr('Abbrechen')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(tr('Zurücksetzen')),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await store.resetConsumptionStatistics();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PageFrame(
      title: tr('Verbrauchsstatistik'),
      actions: [
        IconButton(
          tooltip: tr('Statistik zurücksetzen'),
          onPressed: _reset,
          icon: const Icon(Icons.restart_alt),
        ),
      ],
      child: AnimatedBuilder(
        animation: store,
        builder: (context, _) {
          final records = _filteredRecords();
          final recipes = _recipeAggregates(records);
          final ingredients = _ingredientAggregates(records);
          final totalCost = records.fold<double>(
            0,
            (sum, item) => sum + item.totalCostEur,
          );
          final totalVolume = records.fold<double>(
            0,
            (sum, item) => sum + item.sizeMl,
          );
          final totalRevenue = records.fold<double>(
            0,
            (sum, item) => sum + (item.salePriceEur ?? 0),
          );
          final paidCount = records.where((item) => item.paid).length;
          final missingPriceEvents = records
              .where((item) => item.missingPriceIngredientIds.isNotEmpty)
              .length;
          final double averageCost = records.isEmpty ? 0.0 : totalCost / records.length;
          final topRecipe = recipes.isEmpty
              ? null
              : recipes.reduce((a, b) => a.count >= b.count ? a : b);
          final sizeCounts = <int, int>{};
          for (final event in records) {
            sizeCounts.update(
              event.sizeMl.round(),
              (value) => value + 1,
              ifAbsent: () => 1,
            );
          }
          final sizeEntries = sizeCounts.entries.toList()
            ..sort((a, b) => b.value.compareTo(a.value));
          final topSize = sizeEntries.firstOrNull;
          final legacyCount = period == _StatisticsPeriod.all
              ? math.max(0, store.totalDrinksConsumed - store.consumptionHistory.length)
              : 0;
          final displayedDrinkCount = period == _StatisticsPeriod.all
              ? store.totalDrinksConsumed
              : records.length;

          return ListView(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 24),
            children: [
              _StatisticsControlCard(
                store: store,
                period: period,
                view: view,
                onPeriodChanged: (value) => setState(() => period = value),
                onViewChanged: (value) => setState(() => view = value),
              ),
              const SizedBox(height: 12),
              LayoutBuilder(
                builder: (context, constraints) {
                  final columns = constraints.maxWidth >= 760 ? 4 : 2;
                  final gap = 10.0;
                  final width =
                      (constraints.maxWidth - gap * (columns - 1)) / columns;
                  return Wrap(
                    spacing: gap,
                    runSpacing: gap,
                    children: [
                      _StatSummaryCard(
                        width: width,
                        title: tr('Zubereitet'),
                        value: displayedDrinkCount.toString(),
                        icon: Icons.local_bar,
                        color: store.appColors.accentColor,
                      ),
                      _StatSummaryCard(
                        width: width,
                        title: tr('Gesamtkosten'),
                        value: _money(totalCost),
                        icon: Icons.account_balance_wallet_outlined,
                        color: store.appColors.warningColor,
                      ),
                      _StatSummaryCard(
                        width: width,
                        title: tr('Ø Kosten / Cocktail'),
                        value: _money(averageCost),
                        icon: Icons.calculate_outlined,
                        color: store.appColors.secondaryAccentColor,
                      ),
                      _StatSummaryCard(
                        width: width,
                        title: tr('Ausgegeben'),
                        value: _ml(totalVolume),
                        icon: Icons.water_drop_outlined,
                        color: store.appColors.successColor,
                      ),
                    ],
                  );
                },
              ),
              if (totalRevenue > 0) ...[
                const SizedBox(height: 10),
                _PaymentStatisticsStrip(
                  store: store,
                  paidCount: paidCount,
                  revenue: totalRevenue,
                  ingredientCost: records
                      .where((item) => item.paid)
                      .fold<double>(0, (sum, item) => sum + item.totalCostEur),
                ),
              ],
              if (topRecipe != null || topSize != null) ...[
                const SizedBox(height: 10),
                _StatisticsInsights(
                  store: store,
                  topRecipe: topRecipe?.name,
                  topRecipeCount: topRecipe?.count ?? 0,
                  topSizeMl: topSize?.key,
                  topSizeCount: topSize?.value ?? 0,
                ),
              ],
              if (missingPriceEvents > 0) ...[
                const SizedBox(height: 10),
                _StatisticsNotice(
                  icon: Icons.warning_amber_rounded,
                  color: store.appColors.warningColor,
                  text: '${tr('Bei')} $missingPriceEvents ${tr('Zubereitungen fehlen Zutatenpreise. Die angezeigten Kosten sind deshalb unvollständig.')}',
                ),
              ],
              if (legacyCount > 0) ...[
                const SizedBox(height: 10),
                _StatisticsNotice(
                  icon: Icons.history,
                  color: store.appColors.secondaryAccentColor,
                  text: '$legacyCount ${tr('ältere Zubereitungen sind nicht in der Detailhistorie enthalten. Anzahl und bisheriger Gesamtverbrauch bleiben gespeichert; Größen- und historische Kostenanalyse gilt für die vorhandene V28-Detailhistorie.')}',
                ),
              ],
              const SizedBox(height: 14),
              if (view == _StatisticsView.cocktails) ...[
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        tr('Cocktails im Detail'),
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 18,
                        ),
                      ),
                    ),
                    PopupMenuButton<_StatisticsSort>(
                      tooltip: tr('Sortierung'),
                      initialValue: sort,
                      onSelected: (value) => setState(() => sort = value),
                      itemBuilder: (context) => _StatisticsSort.values
                          .map(
                            (value) => PopupMenuItem<_StatisticsSort>(
                              value: value,
                              child: Row(
                                children: [
                                  if (value == sort)
                                    Icon(Icons.check,
                                        size: 18,
                                        color: store.appColors.accentColor)
                                  else
                                    const SizedBox(width: 18),
                                  const SizedBox(width: 8),
                                  Text(_sortLabel(value)),
                                ],
                              ),
                            ),
                          )
                          .toList(),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: store.appColors.borderColor),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.sort, size: 18),
                            const SizedBox(width: 6),
                            Text(_sortLabel(sort)),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (recipes.isEmpty)
                  _StatisticsEmpty(store: store)
                else
                  ...recipes.map(
                    (item) => _RecipeStatisticsCard(
                      store: store,
                      data: item,
                      money: _money,
                      ml: _ml,
                      categoryName: _categoryName(item.category),
                    ),
                  ),
              ] else ...[
                Text(
                  tr('Zutatenverbrauch'),
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 18,
                  ),
                ),
                const SizedBox(height: 8),
                if (ingredients.isEmpty)
                  _StatisticsEmpty(store: store)
                else
                  ...ingredients.map(
                    (item) => _IngredientStatisticsCard(
                      store: store,
                      data: item,
                      money: _money,
                      ml: _ml,
                    ),
                  ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _StatisticsControlCard extends StatelessWidget {
  const _StatisticsControlCard({
    required this.store,
    required this.period,
    required this.view,
    required this.onPeriodChanged,
    required this.onViewChanged,
  });

  final MachineStore store;
  final _StatisticsPeriod period;
  final _StatisticsView view;
  final ValueChanged<_StatisticsPeriod> onPeriodChanged;
  final ValueChanged<_StatisticsView> onViewChanged;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<_StatisticsPeriod>(
                segments: [
                  ButtonSegment(value: _StatisticsPeriod.today, label: Text(tr('Heute'))),
                  ButtonSegment(value: _StatisticsPeriod.sevenDays, label: Text(tr('7 Tage'))),
                  ButtonSegment(value: _StatisticsPeriod.thirtyDays, label: Text(tr('30 Tage'))),
                  ButtonSegment(value: _StatisticsPeriod.party, label: Text(tr('Party'))),
                  ButtonSegment(value: _StatisticsPeriod.all, label: Text(tr('Gesamt'))),
                ],
                selected: {period},
                showSelectedIcon: false,
                onSelectionChanged: (value) {
                  if (value.isNotEmpty) onPeriodChanged(value.first);
                },
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<_StatisticsView>(
                segments: [
                  ButtonSegment(
                    value: _StatisticsView.cocktails,
                    icon: const Icon(Icons.local_bar, size: 18),
                    label: Text(tr('Cocktails')),
                  ),
                  ButtonSegment(
                    value: _StatisticsView.ingredients,
                    icon: const Icon(Icons.inventory_2_outlined, size: 18),
                    label: Text(tr('Zutaten')),
                  ),
                ],
                selected: {view},
                showSelectedIcon: false,
                onSelectionChanged: (value) {
                  if (value.isNotEmpty) onViewChanged(value.first);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatSummaryCard extends StatelessWidget {
  const _StatSummaryCard({
    required this.width,
    required this.title,
    required this.value,
    required this.icon,
    required this.color,
  });

  final double width;
  final String title;
  final String value;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(13, 12, 13, 11),
          child: Row(
            children: [
              Container(
                width: 39,
                height: 39,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: .13),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(icon, color: color, size: 21),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 20,
                      ),
                    ),
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11.5),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PaymentStatisticsStrip extends StatelessWidget {
  const _PaymentStatisticsStrip({
    required this.store,
    required this.paidCount,
    required this.revenue,
    required this.ingredientCost,
  });

  final MachineStore store;
  final int paidCount;
  final double revenue;
  final double ingredientCost;

  String _money(double value) =>
      '${value.toStringAsFixed(2).replaceAll('.', ',')} €';

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: store.appColors.successColor.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(
          color: store.appColors.successColor.withValues(alpha: .35),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.payments_outlined, color: store.appColors.successColor),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '$paidCount× ${tr('PayPal')} · ${tr('Einnahmen')} ${_money(revenue)} · ${tr('Einnahmen − Zutatenkosten')} ${_money(revenue - ingredientCost)}',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatisticsInsights extends StatelessWidget {
  const _StatisticsInsights({
    required this.store,
    required this.topRecipe,
    required this.topRecipeCount,
    required this.topSizeMl,
    required this.topSizeCount,
  });

  final MachineStore store;
  final String? topRecipe;
  final int topRecipeCount;
  final int? topSizeMl;
  final int topSizeCount;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _InsightTile(
            store: store,
            icon: Icons.emoji_events_outlined,
            title: tr('Beliebtester Cocktail'),
            value: topRecipe == null ? '—' : '${tr(topRecipe!)} · $topRecipeCount×',
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _InsightTile(
            store: store,
            icon: Icons.straighten,
            title: tr('Beliebteste Größe'),
            value: topSizeMl == null ? '—' : '$topSizeMl ml · $topSizeCount×',
          ),
        ),
      ],
    );
  }
}

class _InsightTile extends StatelessWidget {
  const _InsightTile({
    required this.store,
    required this.icon,
    required this.title,
    required this.value,
  });
  final MachineStore store;
  final IconData icon;
  final String title;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: store.appColors.surfaceColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: store.appColors.borderColor),
      ),
      child: Row(
        children: [
          Icon(icon, color: store.appColors.accentColor, size: 20),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 11)),
                const SizedBox(height: 2),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatisticsNotice extends StatelessWidget {
  const _StatisticsNotice({
    required this.icon,
    required this.color,
    required this.text,
  });
  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: .3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 19),
          const SizedBox(width: 9),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 12))),
        ],
      ),
    );
  }
}

class _RecipeStatisticsCard extends StatelessWidget {
  const _RecipeStatisticsCard({
    required this.store,
    required this.data,
    required this.money,
    required this.ml,
    required this.categoryName,
  });

  final MachineStore store;
  final _RecipeConsumptionAggregate data;
  final String Function(double) money;
  final String Function(double) ml;
  final String categoryName;

  @override
  Widget build(BuildContext context) {
    final sizeItems = data.sizes.values.toList()
      ..sort((a, b) => a.sizeMl.compareTo(b.sizeMl));
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: store.appColors.accentColor.withValues(alpha: .12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    data.category == DrinkCategory.shot
                        ? Icons.liquor
                        : Icons.local_bar,
                    size: 20,
                    color: store.appColors.accentColor,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        tr(data.name),
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 16,
                        ),
                      ),
                      Text(
                        categoryName,
                        style: TextStyle(
                          color: store.appColors.textSecondaryColor,
                          fontSize: 11.5,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
                  decoration: BoxDecoration(
                    color: store.appColors.accentColor.withValues(alpha: .12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '${data.count}×',
                    style: TextStyle(
                      color: store.appColors.accentColor,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 11),
            Row(
              children: [
                Expanded(child: _MiniMetric(label: tr('Gesamtkosten'), value: money(data.totalCost))),
                Expanded(child: _MiniMetric(label: tr('Ø Kosten'), value: money(data.averageCost))),
                Expanded(child: _MiniMetric(label: tr('Gesamtmenge'), value: ml(data.totalVolumeMl))),
                if (data.revenue > 0)
                  Expanded(child: _MiniMetric(label: tr('Einnahmen'), value: money(data.revenue))),
              ],
            ),
            const SizedBox(height: 11),
            Text(
              tr('Nach Größe'),
              style: TextStyle(
                color: store.appColors.textSecondaryColor,
                fontWeight: FontWeight.w800,
                fontSize: 11.5,
              ),
            ),
            const SizedBox(height: 7),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: sizeItems.map((item) {
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: store.appColors.surfaceColor,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: store.appColors.borderColor),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${item.sizeMl.toStringAsFixed(0)} ml · ${item.count}×',
                        style: const TextStyle(fontWeight: FontWeight.w900),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${tr('Ø')} ${money(item.averageCost)} · ${tr('Gesamt')} ${money(item.totalCost)}',
                        style: TextStyle(
                          color: store.appColors.textSecondaryColor,
                          fontSize: 11,
                        ),
                      ),
                      if (item.revenue > 0)
                        Text(
                          '${tr('Verkauf')} ${money(item.revenue)}',
                          style: TextStyle(
                            color: store.appColors.successColor,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                    ],
                  ),
                );
              }).toList(),
            ),
            if (data.missingPriceCount > 0) ...[
              const SizedBox(height: 8),
              Text(
                '${data.missingPriceCount}× ${tr('Kosten unvollständig – mindestens eine Zutat ohne Literpreis')}',
                style: TextStyle(
                  color: store.appColors.warningColor,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MiniMetric extends StatelessWidget {
  const _MiniMetric({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 10.5)),
          const SizedBox(height: 2),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

class _IngredientStatisticsCard extends StatelessWidget {
  const _IngredientStatisticsCard({
    required this.store,
    required this.data,
    required this.money,
    required this.ml,
  });
  final MachineStore store;
  final _IngredientConsumptionAggregate data;
  final String Function(double) money;
  final String Function(double) ml;

  @override
  Widget build(BuildContext context) {
    final ingredient = store.ingredientById(data.ingredientId);
    final name = ingredient == null
        ? tr('Gelöschte Zutat')
        : store.displayIngredientName(ingredient);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Row(
          children: [
            Icon(Icons.local_drink_outlined,
                color: store.appColors.secondaryAccentColor),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, style: const TextStyle(fontWeight: FontWeight.w900)),
                  const SizedBox(height: 2),
                  Text(
                    ingredient == null || ingredient.pricePerLiter <= 0
                        ? tr('Kein Literpreis hinterlegt')
                        : '${tr('Literpreis')}: ${money(ingredient.pricePerLiter)} / L',
                    style: TextStyle(
                      color: ingredient == null || ingredient.pricePerLiter <= 0
                          ? store.appColors.warningColor
                          : store.appColors.textSecondaryColor,
                      fontSize: 11.5,
                    ),
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(ml(data.amountMl),
                    style: const TextStyle(fontWeight: FontWeight.w900)),
                Text(
                  money(data.totalCost),
                  style: TextStyle(color: store.appColors.textSecondaryColor),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StatisticsEmpty extends StatelessWidget {
  const _StatisticsEmpty({required this.store});
  final MachineStore store;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: store.appColors.surfaceColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: store.appColors.borderColor),
      ),
      child: Column(
        children: [
          Icon(Icons.query_stats,
              size: 38, color: store.appColors.textSecondaryColor),
          const SizedBox(height: 8),
          Text(
            tr('Für diesen Zeitraum sind noch keine Zubereitungen vorhanden.'),
            textAlign: TextAlign.center,
            style: TextStyle(color: store.appColors.textSecondaryColor),
          ),
        ],
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

  Future<void> _deleteIngredient(Ingredient ingredient) async {
    final recipeReferences =
        widget.store.ingredientRecipeReferenceCount(ingredient.id);
    final pumpReferences =
        widget.store.ingredientPumpReferenceCount(ingredient.id);

    if (recipeReferences > 0) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const T('Zutat kann nicht gelöscht werden'),
          content: Text(
            '${widget.store.displayIngredientName(ingredient)} '
            '${tr('wird noch in')} $recipeReferences '
            '${tr('Rezept(en) verwendet. Entferne die Zutat zuerst aus den betroffenen Rezepten.')}',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const T('Zutat löschen?'),
            content: Text(
              pumpReferences > 0
                  ? '${widget.store.displayIngredientName(ingredient)} '
                      '${tr('ist noch')} $pumpReferences '
                      '${tr('Pumpe(n) zugeordnet. Beim Löschen wird die Zuordnung entfernt und die Pumpenkalibrierung zurückgesetzt.')}'
                  : '${widget.store.displayIngredientName(ingredient)} '
                      '${tr('wirklich löschen?')}',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const T('Abbrechen'),
              ),
              FilledButton.icon(
                onPressed: () => Navigator.pop(context, true),
                icon: const Icon(Icons.delete_outline),
                label: const T('Löschen'),
              ),
            ],
          ),
        ) ??
        false;

    if (!confirmed) return;

    final error = await widget.store.deleteIngredient(ingredient.id);
    if (!mounted) return;

    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error)),
      );
      return;
    }

    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${widget.store.displayIngredientName(ingredient)} '
          '${tr('wurde gelöscht.')}',
        ),
      ),
    );
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
                        border: Border.all(color: widget.store.appColors.borderColor),
                      ),
                      child: Text(
                        tr('Literpreise und Kostenberechnung sind nur in der Lizenzversion verfügbar.'),
                        style: TextStyle(color: widget.store.appColors.textSecondaryColor),
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
                        const SizedBox(width: 8),
                        IconButton(
                          tooltip: tr('Zutat löschen'),
                          onPressed: () => _deleteIngredient(ingredient),
                          icon: const Icon(Icons.delete_outline),
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
  bool busy = false;
  String? importedFileName;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await widget.store.refreshCommercialLicenseStatus();
      if (mounted) setState(() {});
    });
  }

  Future<void> _deactivate() async {
    if (busy) return;
    setState(() => busy = true);
    await widget.store.deactivateCommercialLicense();
    if (!mounted) return;
    setState(() {
      busy = false;
      importedFileName = null;
    });
  }

  Future<void> _refresh() async {
    if (busy) return;
    setState(() => busy = true);
    await widget.store.refreshCommercialLicenseStatus();
    if (mounted) setState(() => busy = false);
  }

  Future<void> _copyDeviceId() async {
    final id = widget.store.commercialDeviceId;
    if (id.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: id));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${tr('Geräte-ID kopiert')}: $id')),
    );
  }

  String? _licenseCodeFromText(String text) {
    final labelled = RegExp(
      r'Lizenzcode\s*:\s*(CBL1-[A-Za-z0-9_-]+)',
      caseSensitive: false,
    ).firstMatch(text);
    if (labelled != null) return labelled.group(1);

    final plain = RegExp(
      r'CBL1-[A-Za-z0-9_-]+',
      caseSensitive: false,
    ).firstMatch(text);
    return plain?.group(0);
  }

  Future<void> _importLicenseFile() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['txt'],
        allowMultiple: false,
        withData: true,
        dialogTitle: tr('CocktailBot Lizenzdatei auswählen'),
      );
      if (result == null || result.files.isEmpty) {
        if (mounted) setState(() => busy = false);
        return;
      }

      final file = result.files.single;
      final bytes = file.bytes ?? await file.xFile.readAsBytes();
      if (bytes.isEmpty) {
        throw Exception(tr('Die Lizenzdatei ist leer.'));
      }
      if (bytes.length > 64 * 1024) {
        throw Exception(tr('Die ausgewählte Datei ist keine gültige CocktailBot-Lizenzdatei.'));
      }

      final text = utf8.decode(bytes, allowMalformed: true);
      final code = _licenseCodeFromText(text);
      if (code == null || code.isEmpty) {
        throw Exception(tr('In der Datei wurde kein CocktailBot-Lizenzcode gefunden.'));
      }

      final ok = await widget.store.activateCommercialLicense(code);
      if (!mounted) return;
      setState(() {
        busy = false;
        importedFileName = file.name;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ok
                ? tr('Gewerbelizenz wurde erfolgreich importiert und aktiviert.')
                : widget.store.commercialLicenseMessage,
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${tr('Lizenzimport fehlgeschlagen')}: $error')),
      );
    }
  }

  String _date(DateTime? value) {
    if (value == null) return '–';
    final local = value.toLocal();
    final day = local.day.toString().padLeft(2, '0');
    final month = local.month.toString().padLeft(2, '0');
    return '$day.$month.${local.year}';
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.store.commercialLicenseActive;
    final deviceId = widget.store.commercialDeviceId.isEmpty
        ? tr('Wird ermittelt …')
        : widget.store.commercialDeviceId;

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
                    active ? Icons.verified_user : Icons.lock_outline,
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
                          tr(widget.store.commercialLicenseMessage),
                          style: TextStyle(
                            color: widget.store.appColors.textSecondaryColor,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: tr('Lizenzstatus aktualisieren'),
                    onPressed: busy ? null : _refresh,
                    icon: busy
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh),
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
                    tr('Gerätegebundene Offline-Lizenz'),
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 18,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    tr('Sende diese Geräte-ID an deinen CocktailBot-Anbieter. Du erhältst eine TXT-Lizenzdatei, die ausschließlich auf diesem Raspberry funktioniert. Speichere die Datei z. B. auf einem USB-Stick und importiere sie hier. Eine Internetverbindung ist nicht erforderlich.'),
                    style: TextStyle(
                      color: widget.store.appColors.textSecondaryColor,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.memory),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                tr('Geräte-ID'),
                                style: TextStyle(
                                  color: widget.store.appColors.textSecondaryColor,
                                  fontSize: 12,
                                ),
                              ),
                              const SizedBox(height: 4),
                              SelectableText(
                                deviceId,
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 18,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.6,
                                ),
                              ),
                            ],
                          ),
                        ),
                        OutlinedButton.icon(
                          onPressed: widget.store.commercialDeviceId.isEmpty
                              ? null
                              : _copyDeviceId,
                          icon: const Icon(Icons.copy, size: 18),
                          label: Text(tr('Kopieren')),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  if (!active) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: Theme.of(context).colorScheme.outlineVariant,
                        ),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.description_outlined, size: 30),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  tr('Lizenzdatei vom CocktailBot-Anbieter'),
                                  style: const TextStyle(fontWeight: FontWeight.w800),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  importedFileName == null
                                      ? tr('TXT-Datei auswählen. Geräte-ID und Signatur werden automatisch geprüft.')
                                      : '${tr('Ausgewählt')}: $importedFileName',
                                  style: TextStyle(
                                    color: widget.store.appColors.textSecondaryColor,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: busy ? null : _importLicenseFile,
                        icon: busy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.file_open_outlined),
                        label: Text(
                          busy
                              ? tr('Lizenz wird geprüft …')
                              : tr('Lizenzdatei importieren'),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      tr('Der Raspberry installiert die Lizenz nach erfolgreicher Prüfung automatisch. Es sind keine Terminal- oder sudo-Befehle nötig.'),
                      style: TextStyle(
                        color: widget.store.appColors.textSecondaryColor,
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                  ] else ...[
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${tr('Lizenzierte Maschine')}: ${widget.store.commercialLicensedMachineId}\n'
                            '${tr('Aktiviert am')}: ${_date(widget.store.commercialLicenseActivatedAt)}',
                          ),
                        ),
                        OutlinedButton.icon(
                          onPressed: busy ? null : _deactivate,
                          icon: const Icon(Icons.lock_reset),
                          label: Text(tr('Deaktivieren')),
                        ),
                      ],
                    ),
                  ],
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

  List<double> _sizesFor(Recipe recipe) => widget.store.sizesFor(recipe.category);

  String _key(Recipe recipe, double size) => '${recipe.id}|${size.round()}';

  TextEditingController _controllerFor(Recipe recipe, double size) {
    return controllers.putIfAbsent(
      _key(recipe, size),
      () => TextEditingController(
        text: widget.store
            .priceForRecipe(recipe, targetVolumeMl: size)
            .toStringAsFixed(2),
      ),
    );
  }

  Future<void> _saveRecipeSizePrice(Recipe recipe, double size) async {
    final controller = _controllerFor(recipe, size);
    final parsed = double.tryParse(controller.text.replaceAll(',', '.').trim());
    if (parsed == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('Bitte eine gültige Zahl eingeben'))),
      );
      return;
    }
    await widget.store.setRecipeSizePrice(recipe, size, parsed);
    if (!mounted) return;
    setState(() {
      controller.text = widget.store
          .priceForRecipe(recipe, targetVolumeMl: size)
          .toStringAsFixed(2);
    });
  }

  Future<void> _resetRecipeSizePrice(Recipe recipe, double size) async {
    await widget.store.setRecipeSizePrice(recipe, size, null);
    final controller = _controllerFor(recipe, size);
    if (!mounted) return;
    setState(() {
      controller.text = widget.store
          .priceForRecipe(recipe, targetVolumeMl: size)
          .toStringAsFixed(2);
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
        padding: const EdgeInsets.all(18),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.sell_outlined,
                          color: widget.store.appColors.accentColor),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          tr('Verkaufspreise nach Cocktailgröße'),
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 18,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 7),
                  Text(
                    tr('Für jede aktivierte Größe kann ein eigener Preis hinterlegt werden. Ohne Einzelpreis gilt der Standardpreis dieser Größe aus dem PayPal-Kassenmodus.'),
                    style: TextStyle(
                      color: widget.store.appColors.textSecondaryColor,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 12),
                  SegmentedButton<DrinkCategory>(
                    segments: DrinkCategory.values
                        .map(
                          (category) => ButtonSegment<DrinkCategory>(
                            value: category,
                            label: Text(_categoryLabel(category)),
                          ),
                        )
                        .toList(),
                    selected: {selectedCategory},
                    showSelectedIcon: false,
                    onSelectionChanged: (value) {
                      if (value.isEmpty) return;
                      setState(() => selectedCategory = value.first);
                    },
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          ...recipes.map((recipe) {
            final sizes = _sizesFor(recipe);
            return Card(
              margin: const EdgeInsets.only(bottom: 10),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.store.displayRecipeName(recipe),
                      style: const TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      tr('Nur die in den Größeneinstellungen aktivierten Größen werden angezeigt.'),
                      style: TextStyle(
                        color: widget.store.appColors.textSecondaryColor,
                        fontSize: 11.5,
                      ),
                    ),
                    const SizedBox(height: 10),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final columns = constraints.maxWidth >= 720
                            ? 3
                            : constraints.maxWidth >= 460
                                ? 2
                                : 1;
                        final gap = 10.0;
                        final cellWidth =
                            (constraints.maxWidth - gap * (columns - 1)) /
                                columns;
                        return Wrap(
                          spacing: gap,
                          runSpacing: gap,
                          children: sizes.map((size) {
                            final controller = _controllerFor(recipe, size);
                            final custom =
                                widget.store.hasRecipeSizePrice(recipe, size);
                            final fallback = widget.store.categoryPriceForSize(
                              recipe.category,
                              size,
                            );
                            return SizedBox(
                              width: cellWidth,
                              child: Container(
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: widget.store.appColors.surfaceColor,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: custom
                                        ? widget.store.appColors.accentColor
                                        : widget.store.appColors.borderColor,
                                  ),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Text(
                                          '${size.toStringAsFixed(0)} ml',
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w900,
                                          ),
                                        ),
                                        const Spacer(),
                                        if (custom)
                                          Icon(
                                            Icons.check_circle,
                                            size: 17,
                                            color: widget
                                                .store.appColors.successColor,
                                          ),
                                      ],
                                    ),
                                    const SizedBox(height: 8),
                                    Row(
                                      children: [
                                        Expanded(
                                          child: TextField(
                                            controller: controller,
                                            keyboardType: const TextInputType
                                                .numberWithOptions(decimal: true),
                                            decoration: const InputDecoration(
                                              suffixText: '€',
                                              isDense: true,
                                            ),
                                            onSubmitted: (_) =>
                                                _saveRecipeSizePrice(recipe, size),
                                          ),
                                        ),
                                        IconButton(
                                          tooltip: tr('Speichern'),
                                          onPressed: () =>
                                              _saveRecipeSizePrice(recipe, size),
                                          icon: const Icon(Icons.save_outlined),
                                        ),
                                        IconButton(
                                          tooltip: tr('Standardpreis verwenden'),
                                          onPressed: custom
                                              ? () => _resetRecipeSizePrice(
                                                  recipe, size)
                                              : null,
                                          icon: const Icon(Icons.undo),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      custom
                                          ? tr('Eigener Preis für diese Größe')
                                          : '${tr('Standardpreis')}: ${fallback.toStringAsFixed(2).replaceAll('.', ',')} €',
                                      style: TextStyle(
                                        color: widget
                                            .store.appColors.textSecondaryColor,
                                        fontSize: 11,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          }).toList(),
                        );
                      },
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
  final priceControllers = <String, TextEditingController>{};
  bool? backendReady;
  String backendState = tr('Lokales Zahlungsbackend wird geprüft …');

  @override
  void initState() {
    super.initState();
    enabled = widget.store.paypalPaymentEnabled;
    _refreshBackendStatus();
  }

  @override
  void dispose() {
    machineIdController.dispose();
    for (final controller in priceControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  String _categoryLabel(DrinkCategory category) => switch (category) {
        DrinkCategory.cocktail => tr('Cocktails'),
        DrinkCategory.mocktail => tr('Alkoholfrei'),
        DrinkCategory.shot => tr('Shots'),
      };

  List<double> _sizes(DrinkCategory category) => widget.store.sizesFor(category);

  String _key(DrinkCategory category, double size) =>
      '${category.name}|${size.round()}';

  TextEditingController _controller(DrinkCategory category, double size) {
    return priceControllers.putIfAbsent(
      _key(category, size),
      () => TextEditingController(
        text: widget.store
            .categoryPriceForSize(category, size)
            .toStringAsFixed(2),
      ),
    );
  }

  double _read(DrinkCategory category, double size) {
    return double.tryParse(
          _controller(category, size).text.replaceAll(',', '.').trim(),
        ) ??
        widget.store.categoryPriceForSize(category, size);
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
            ? '${tr('PayPal lokal auf dem Raspberry konfiguriert')} ($mode)'
            : tr('PayPal-Zugangsdaten auf dem Raspberry fehlen');
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        backendReady = false;
        backendState =
            '${tr('Lokales Zahlungsbackend nicht erreichbar')}: $error';
      });
    }
  }

  Future<void> _save() async {
    try {
      final values = <String, double>{};
      for (final category in DrinkCategory.values) {
        for (final size in _sizes(category)) {
          values[_key(category, size)] = _read(category, size);
        }
      }
      await widget.store.savePaymentSettings(
        enabled: enabled,
        machineId: machineIdController.text,
        cocktailPrice: _read(
          DrinkCategory.cocktail,
          widget.store.defaultServingSizeMl,
        ),
        mocktailPrice: _read(
          DrinkCategory.mocktail,
          widget.store.defaultServingSizeMl,
        ),
        shotPrice: _read(
          DrinkCategory.shot,
          widget.store.defaultShotSizeMl,
        ),
        sizePrices: values,
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

  Widget _categoryPriceCard(DrinkCategory category) {
    final sizes = _sizes(category);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _categoryLabel(category),
              style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
            ),
            const SizedBox(height: 9),
            LayoutBuilder(
              builder: (context, constraints) {
                final columns = constraints.maxWidth >= 680 ? 3 : 2;
                final gap = 10.0;
                final width =
                    (constraints.maxWidth - gap * (columns - 1)) / columns;
                return Wrap(
                  spacing: gap,
                  runSpacing: gap,
                  children: sizes.map((size) {
                    return SizedBox(
                      width: width,
                      child: TextField(
                        controller: _controller(category, size),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: InputDecoration(
                          labelText: '${size.toStringAsFixed(0)} ml',
                          suffixText: '€',
                        ),
                      ),
                    );
                  }).toList(),
                );
              },
            ),
          ],
        ),
      ),
    );
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
        padding: const EdgeInsets.all(18),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
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
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
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
                  TextField(
                    controller: machineIdController,
                    readOnly: true,
                    decoration: InputDecoration(
                      labelText: tr('Geräte-ID für Zahlungen'),
                      suffixIcon: const Icon(Icons.lock_outline),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(Icons.payments_outlined,
                  color: widget.store.appColors.accentColor),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  tr('Standardpreise nach Größe'),
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 18,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            tr('Diese Preise gelten, wenn für einen einzelnen Cocktail und diese Größe kein eigener Preis gesetzt wurde.'),
            style: TextStyle(color: widget.store.appColors.textSecondaryColor),
          ),
          const SizedBox(height: 10),
          _categoryPriceCard(DrinkCategory.cocktail),
          _categoryPriceCard(DrinkCategory.mocktail),
          _categoryPriceCard(DrinkCategory.shot),
          const SizedBox(height: 6),
          SizedBox(
            height: 50,
            child: FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save_outlined),
              label: Text(tr('Zahlungseinstellungen speichern')),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            tr('Einzelpreise pro Cocktail und Größe stellst du im Menü „Cocktailpreise“ ein.'),
            style: TextStyle(color: widget.store.appColors.textSecondaryColor),
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
  bool checkingPayment = false;
  bool paymentConfirmed = false;
  bool paymentUsed = false;

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
        const Duration(seconds: 2),
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
    if (order == null || preparing || checkingPayment || paymentConfirmed || paymentUsed) {
      return;
    }

    checkingPayment = true;
    try {
      final status = await widget.store.paymentStatus(order!.orderId);
      if (!mounted) return;

      if (status.used) {
        timer?.cancel();
        setState(() {
          paymentUsed = true;
          message = tr('Diese Zahlung wurde bereits verwendet');
        });
        return;
      }

      if (status.paid) {
        timer?.cancel();
        setState(() {
          paymentConfirmed = true;
          message = tr('Zahlung bestätigt – Cocktail kann zubereitet werden');
        });
        return;
      }

      setState(() {
        message = '${tr('Warte auf Zahlung')} (${status.status})';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => message = '${tr('Zahlungsstatus konnte nicht geprüft werden')}: $error');
    } finally {
      checkingPayment = false;
    }
  }

  Future<void> _continueToPreparation() async {
    if (order == null || !paymentConfirmed || preparing) return;
    setState(() => preparing = true);

    try {
      await widget.store.markPaymentUsed(order!.orderId);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        preparing = false;
        message = '${tr('Zahlung konnte nicht freigegeben werden')}: $error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final price = widget.store.priceForRecipe(
      widget.recipe,
      targetVolumeMl: widget.targetVolumeMl,
    );
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
                  else if (order == null || paymentUsed)
                    Icon(
                      Icons.error_outline,
                      color: widget.store.appColors.errorColor,
                      size: 52,
                    )
                  else if (paymentConfirmed)
                    Column(
                      children: [
                        Icon(
                          Icons.check_circle,
                          color: widget.store.appColors.successColor,
                          size: 74,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          tr('Bezahlung erfolgreich'),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 20,
                          ),
                        ),
                      ],
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
                          onPressed: order == null || preparing || paymentUsed
                              ? null
                              : paymentConfirmed
                                  ? _continueToPreparation
                                  : _checkPayment,
                          icon: preparing
                              ? const SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : Icon(
                                  paymentConfirmed
                                      ? Icons.play_arrow
                                      : Icons.refresh,
                                ),
                          label: Text(
                            preparing
                                ? tr('Wird freigegeben …')
                                : paymentConfirmed
                                    ? tr('Cocktail zubereiten')
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

class _PartyLearningNotice extends StatelessWidget {
  const _PartyLearningNotice({
    required this.store,
    required this.completedCount,
  });

  final MachineStore store;
  final int completedCount;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: store.appColors.warningColor.withOpacity(0.10),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.info_outline,
              color: store.appColors.warningColor,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr('Hinweis zur Lernphase'),
                    style: const TextStyle(fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    tr('Partyplaner und Einkaufsliste lernen aus abgeschlossenen Partys. Aussagekräftige Ergebnisse entstehen erst nach mehreren Partys mit derselben Partykarte. Bis dahin sind die Werte nur Schätzungen.'),
                  ),
                  if (completedCount > 0) ...[
                    const SizedBox(height: 6),
                    Text(
                      '$completedCount ${tr('abgeschlossene Partys mit dieser Partykarte')}',
                      style: TextStyle(
                        color: store.appColors.textSecondaryColor,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
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

    return PageFrame(
      title: tr('Partyplaner'),
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _PartyLearningNotice(
            store: widget.store,
            completedCount: completed.length,
          ),
          const SizedBox(height: 18),
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

class ShoppingListPage extends StatefulWidget {
  const ShoppingListPage({super.key, required this.store});
  final MachineStore store;

  @override
  State<ShoppingListPage> createState() => _ShoppingListPageState();
}

class _ShoppingListPageState extends State<ShoppingListPage> {
  late final guestController = TextEditingController(
    text: widget.store.partyPlannerGuestCount.toString(),
  );
  late final reserveController = TextEditingController(
    text: widget.store.partyPlannerReservePercent.toString(),
  );
  final Map<String, TextEditingController> inventoryControllers = {};

  @override
  void dispose() {
    guestController.dispose();
    reserveController.dispose();
    for (final controller in inventoryControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  int _readInt(TextEditingController controller, int fallback) {
    return int.tryParse(controller.text.trim()) ?? fallback;
  }

  TextEditingController _inventoryController(String ingredientId) {
    return inventoryControllers.putIfAbsent(ingredientId, () {
      final stored = widget.store.shoppingInventoryFor(ingredientId);
      final text = stored == null
          ? ''
          : stored % 1 == 0
              ? stored.toStringAsFixed(0)
              : stored.toStringAsFixed(1);
      return TextEditingController(text: text);
    });
  }

  double? _inventoryValue(String ingredientId) {
    final text = _inventoryController(ingredientId)
        .text
        .trim()
        .replaceAll(',', '.');
    if (text.isEmpty) return null;
    final parsed = double.tryParse(text);
    if (parsed == null) return null;
    return math.max(0.0, parsed);
  }

  Future<void> _savePlanningSettings(String cardId) async {
    await widget.store.setPartyPlannerSettings(
      guestCount: _readInt(guestController, 30),
      reservePercent: _readInt(reserveController, 10),
      partyCardId: cardId,
    );
  }

  Future<void> _saveInventory(Iterable<String> ingredientIds) async {
    final values = <String, double?>{};
    for (final ingredientId in ingredientIds) {
      final raw = _inventoryController(ingredientId).text.trim();
      values[ingredientId] = raw.isEmpty ? null : _inventoryValue(ingredientId);
    }
    await widget.store.saveShoppingInventory(values);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(tr('Bestand gespeichert'))),
    );
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final cards = widget.store.partyCards;
    final selectedCard = widget.store.partyCardById(
          widget.store.activePartyCardId,
        ) ??
        cards.firstOrNull;
    final completed = selectedCard == null
        ? <PartySession>[]
        : widget.store.completedPartySessionsForCard(selectedCard.id);
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
    final usage = widget.store.plannedIngredientUsageMl(stats);

    final rows = usage.entries.map((entry) {
      final stockMl = _inventoryValue(entry.key);
      final purchaseMl = math.max(0.0, entry.value - (stockMl ?? 0));
      return (
        id: entry.key,
        requiredMl: entry.value,
        stockMl: stockMl,
        purchaseMl: purchaseMl,
      );
    }).toList()
      ..sort((a, b) {
        final byPurchase = b.purchaseMl.compareTo(a.purchaseMl);
        if (byPurchase != 0) return byPurchase;
        return widget.store
            .displayIngredientNameById(a.id)
            .compareTo(widget.store.displayIngredientNameById(b.id));
      });

    final totalPurchaseMl = rows.fold<double>(
      0,
      (sum, row) => sum + row.purchaseMl,
    );

    return PageFrame(
      title: tr('Einkaufsliste'),
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _PartyLearningNotice(
            store: widget.store,
            completedCount: completed.length,
          ),
          const SizedBox(height: 18),
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
                      tr('Einkaufsliste'),
                      style: const TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 18,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      tr('Zutatenbedarf und fehlende Mengen planen'),
                      style: TextStyle(
                        color: widget.store.appColors.textSecondaryColor,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: guestController,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              labelText: tr('Gästezahl'),
                            ),
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextField(
                            controller: reserveController,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              labelText: tr('Reserve in Prozent'),
                            ),
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                      ],
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
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        _PlannerMetric(
                          label: tr('Geplant'),
                          value:
                              '${stats.fold<int>(0, (sum, e) => sum + e.plannedCount)}',
                        ),
                        _PlannerMetric(
                          label: tr('Einkaufen'),
                          value:
                              '${(totalPurchaseMl / 1000).toStringAsFixed(2)} L',
                        ),
                      ],
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
                      tr('Bestand für Einkaufsliste'),
                      style: const TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 18,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      tr('Trage deinen aktuellen Bestand einmal ein. Nach jeder erfolgreichen Zubereitung werden die verwendeten Zutaten automatisch abgezogen. Leere Felder bleiben unbekannt; dann wird der komplette geplante Bedarf als Einkaufsmenge angezeigt.'),
                      style: TextStyle(
                        color: widget.store.appColors.textSecondaryColor,
                      ),
                    ),
                    const SizedBox(height: 14),
                    if (rows.isEmpty)
                      Text(tr('Keine Zutaten berechnet'))
                    else ...[
                      ...rows.map((row) {
                        final ingredientName =
                            widget.store.displayIngredientNameById(row.id);
                        final stockKnown = row.stockMl != null;
                        final enough = stockKnown && row.purchaseMl <= 0.01;
                        return Card(
                          margin: const EdgeInsets.only(bottom: 10),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 12,
                            ),
                            child: LayoutBuilder(
                              builder: (context, constraints) {
                                final info = Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      ingredientName,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w900,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      '${tr('Bedarf')}: ${(row.requiredMl / 1000).toStringAsFixed(2)} L · '
                                      '${tr('Einkaufen')}: ${(row.purchaseMl / 1000).toStringAsFixed(2)} L',
                                      style: TextStyle(
                                        color: widget.store
                                            .appColors.textSecondaryColor,
                                      ),
                                    ),
                                    if (!stockKnown) ...[
                                      const SizedBox(height: 3),
                                      Text(
                                        tr('nicht eingetragen'),
                                        style: TextStyle(
                                          color: widget.store
                                              .appColors.warningColor,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ],
                                  ],
                                );

                                final input = SizedBox(
                                  width: 165,
                                  child: TextField(
                                    controller: _inventoryController(row.id),
                                    keyboardType:
                                        const TextInputType.numberWithOptions(
                                      decimal: true,
                                    ),
                                    decoration: InputDecoration(
                                      labelText: tr('Bestand (ml)'),
                                      prefixIcon: Icon(
                                        enough
                                            ? Icons.check_circle_outline
                                            : Icons.inventory_2_outlined,
                                        color: enough
                                            ? widget.store.appColors.successColor
                                            : widget.store.appColors.accentColor,
                                      ),
                                    ),
                                    onChanged: (_) => setState(() {}),
                                  ),
                                );

                                if (constraints.maxWidth < 620) {
                                  return Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      info,
                                      const SizedBox(height: 10),
                                      Align(
                                        alignment: Alignment.centerLeft,
                                        child: input,
                                      ),
                                    ],
                                  );
                                }

                                return Row(
                                  children: [
                                    Icon(
                                      enough
                                          ? Icons.check_circle_outline
                                          : Icons.shopping_cart_checkout_outlined,
                                      color: enough
                                          ? widget.store.appColors.successColor
                                          : widget.store.appColors.warningColor,
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(child: info),
                                    const SizedBox(width: 12),
                                    input,
                                  ],
                                );
                              },
                            ),
                          ),
                        );
                      }),
                      const SizedBox(height: 6),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: () => _saveInventory(
                            rows.map((row) => row.id),
                          ),
                          icon: const Icon(Icons.save_outlined),
                          label: Text(tr('Bestand speichern')),
                        ),
                      ),
                    ],
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
                  color: widget.store.appColors.accentColor,
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


class UsbImageChoice {
  const UsbImageChoice({
    required this.id,
    required this.name,
    required this.source,
    required this.sizeBytes,
  });

  final String id;
  final String name;
  final String source;
  final int sizeBytes;

  factory UsbImageChoice.fromJson(Map<String, dynamic> json) => UsbImageChoice(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        source: json['source']?.toString() ?? 'USB',
        sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
      );
}

class UsbImagePickerDialog extends StatefulWidget {
  const UsbImagePickerDialog({super.key, required this.store});

  final MachineStore store;

  @override
  State<UsbImagePickerDialog> createState() => _UsbImagePickerDialogState();
}

class _UsbImagePickerDialogState extends State<UsbImagePickerDialog> {
  late Future<List<UsbImageChoice>> _future;
  bool _hasUsbRoot = true;

  @override
  void initState() {
    super.initState();
    _future = _loadImages();
  }

  Future<List<UsbImageChoice>> _loadImages() async {
    final response = await http
        .get(widget.store._apiUri('/api/images/usb'))
        .timeout(const Duration(seconds: 8));
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) throw Exception('Ungültige Serverantwort');
    final data = Map<String, dynamic>.from(decoded);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(data['error']?.toString() ?? 'USB-Bilder nicht verfügbar');
    }
    final roots = data['roots'];
    _hasUsbRoot = roots is List && roots.isNotEmpty;
    final raw = data['images'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((item) => UsbImageChoice.fromJson(Map<String, dynamic>.from(item)))
        .where((item) => item.id.isNotEmpty)
        .toList();
  }

  void _reload() {
    setState(() {
      _future = _loadImages();
    });
  }

  Uri _imageUri(UsbImageChoice image, {bool thumbnail = false}) =>
      widget.store._apiUri('/api/images/usb/file').replace(
        queryParameters: {
          'id': image.id,
          if (thumbnail) 'thumb': '1',
        },
      );

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
      titlePadding: const EdgeInsets.fromLTRB(22, 16, 12, 8),
      contentPadding: const EdgeInsets.fromLTRB(18, 4, 18, 10),
      title: Row(
        children: [
          const Icon(Icons.usb_rounded),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              tr('USB-Bilder'),
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
          IconButton(
            tooltip: tr('Neu laden'),
            onPressed: _reload,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      content: SizedBox(
        width: 880,
        height: 410,
        child: FutureBuilder<List<UsbImageChoice>>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.usb_off_rounded, size: 54),
                    const SizedBox(height: 12),
                    Text(
                      '${tr('Bild konnte nicht geladen werden')}: ${snapshot.error}',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 14),
                    FilledButton.tonalIcon(
                      onPressed: _reload,
                      icon: const Icon(Icons.refresh_rounded),
                      label: Text(tr('Neu laden')),
                    ),
                  ],
                ),
              );
            }

            final images = snapshot.data ?? const <UsbImageChoice>[];
            if (images.isEmpty) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _hasUsbRoot ? Icons.image_not_supported_outlined : Icons.usb_off_rounded,
                      size: 58,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _hasUsbRoot
                          ? tr('Keine Bilder auf dem USB-Stick gefunden.')
                          : tr('USB-Stick einstecken und neu laden.'),
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      tr('Unterstützt werden JPG, PNG und WebP.'),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 14),
                    FilledButton.tonalIcon(
                      onPressed: _reload,
                      icon: const Icon(Icons.refresh_rounded),
                      label: Text(tr('Neu laden')),
                    ),
                  ],
                ),
              );
            }

            return GridView.builder(
              itemCount: images.length,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
                childAspectRatio: 1.16,
              ),
              itemBuilder: (context, index) {
                final image = images[index];
                return Material(
                  color: Theme.of(context).colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(14),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => Navigator.pop(context, image),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: Image.network(
                            _imageUri(image, thumbnail: true).toString(),
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => const Center(
                              child: Icon(Icons.broken_image_outlined, size: 40),
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(9, 7, 9, 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                image.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontWeight: FontWeight.w700),
                              ),
                              Text(
                                image.source,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr('Abbrechen')),
        ),
      ],
    );
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
  late final TextEditingController preparationNotes;
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
    preparationNotes = TextEditingController(
      text: (recipe?.manualNotes ?? const <String>[]).join('\n'),
    );
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
    preparationNotes.dispose();
    super.dispose();
  }

  Future<void> _pickImageFromFileBrowser() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.image,
        allowMultiple: false,
        withData: true,
        dialogTitle: tr('Bild auswählen'),
      );
      if (result == null || result.files.isEmpty || !mounted) return;

      final file = result.files.single;
      final bytes = file.bytes ?? await file.xFile.readAsBytes();
      if (bytes.isEmpty) {
        throw Exception(tr('Bild konnte nicht geladen werden'));
      }
      if (bytes.length > 25 * 1024 * 1024) {
        throw Exception('Bild ist größer als 25 MB');
      }

      // Browser-Dateien haben aus Sicherheitsgründen keinen direkt nutzbaren
      // Linux-Pfad. Deshalb werden die Bytes an den lokalen Raspberry-Dienst
      // geschickt, dort mit Pillow gedreht/verkleinert und als JPEG
      // zurückgegeben.
      final response = await http
          .post(
            widget.store._apiUri('/api/images/optimize'),
            headers: {
              'Content-Type': 'application/octet-stream',
              'X-File-Name': Uri.encodeComponent(file.name),
            },
            body: bytes,
          )
          .timeout(const Duration(seconds: 20));

      if (response.statusCode < 200 || response.statusCode >= 300) {
        var message = 'HTTP ${response.statusCode}';
        try {
          final decoded = jsonDecode(response.body);
          if (decoded is Map && decoded['error'] != null) {
            message = decoded['error'].toString();
          }
        } catch (_) {}
        throw Exception(message);
      }

      if (!mounted) return;
      setState(() {
        imagePath = 'data:image/jpeg;base64,${base64Encode(response.bodyBytes)}';
      });
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${tr('Bild konnte nicht geladen werden')}: $error')),
      );
    }
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
          TextField(
            controller: preparationNotes,
            minLines: 3,
            maxLines: 6,
            decoration: InputDecoration(
              labelText: tr('Hinweise für die Zubereitung'),
              helperText: tr(
                'Ein Hinweis pro Zeile. Zum Beispiel: Frische Minze hinzufügen oder Limettenstücke ins Glas geben.',
              ),
              alignLabelWithHint: true,
            ),
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
            onPressed: _pickImageFromFileBrowser,
            icon: const Icon(Icons.folder_open_rounded),
            label: Text(
              imagePath == null
                  ? tr('Bild im Dateibrowser auswählen')
                  : tr('Bild ausgewählt'),
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
            ],
          ),
          const SizedBox(height: 8),
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
    final parsedNotes = preparationNotes.text
        .split('\n')
        .map((note) => note.trim())
        .where((note) => note.isNotEmpty)
        .toList();

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
      recipe.manualNotes = List<String>.from(parsedNotes);
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
          manualNotes: List<String>.from(parsedNotes),
        ),
      );
    }
    widget.store.save();
    Navigator.pop(context);
  }
}

