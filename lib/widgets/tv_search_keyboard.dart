import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'tv_tap.dart';

/// 电视首字母键盘。方向键移动焦点，确认键输入，不弹出系统输入法。
class TvSearchKeyboard extends StatefulWidget {
  const TvSearchKeyboard({
    super.key,
    required this.onInput,
    required this.onDelete,
    required this.onClear,
    required this.onSearch,
    required this.onFocusResults,
    required this.onFocusBack,
  });

  final ValueChanged<String> onInput;
  final VoidCallback onDelete;
  final VoidCallback onClear;
  final VoidCallback onSearch;
  final VoidCallback onFocusResults;
  final VoidCallback onFocusBack;

  @override
  State<TvSearchKeyboard> createState() => TvSearchKeyboardState();
}

class TvSearchKeyboardState extends State<TvSearchKeyboard> {
  static const _characters = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  final _keys = List.generate(36, (i) => FocusNode(debugLabel: 'tv-key-$i'));
  final _actions =
      List.generate(3, (i) => FocusNode(debugLabel: 'tv-action-$i'));
  int _lastKey = 0;
  int? _focusedEntry;

  void requestKeyboardFocus() => _keys[_lastKey].requestFocus();

  @override
  void initState() {
    super.initState();
    for (var i = 0; i < _keys.length; i++) {
      final index = i;
      _keys[i].addListener(() => _syncFocus(index, _keys[index].hasFocus));
      _keys[i].onKeyEvent = (_, event) => _moveKey(index, event);
    }
    for (var i = 0; i < _actions.length; i++) {
      final index = i;
      _actions[i]
          .addListener(() => _syncFocus(36 + index, _actions[index].hasFocus));
      _actions[i].onKeyEvent = (_, event) => _moveAction(index, event);
    }
  }

  void _syncFocus(int index, bool focused) {
    if (!mounted) return;
    if (focused) {
      if (index < 36) _lastKey = index;
      setState(() => _focusedEntry = index);
    } else if (_focusedEntry == index) {
      setState(() => _focusedEntry = null);
    }
  }

  @override
  void dispose() {
    for (final node in [..._keys, ..._actions]) {
      node.dispose();
    }
    super.dispose();
  }

  KeyEventResult _moveKey(int index, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    _lastKey = index;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowRight:
        if (index % 6 == 5) {
          widget.onFocusResults();
        } else {
          _keys[index + 1].requestFocus();
        }
      case LogicalKeyboardKey.arrowLeft:
        if (index % 6 > 0) _keys[index - 1].requestFocus();
      case LogicalKeyboardKey.arrowDown:
        if (index + 6 < _keys.length) {
          _keys[index + 6].requestFocus();
        } else {
          _actions[(index % 6) ~/ 2].requestFocus();
        }
      case LogicalKeyboardKey.arrowUp:
        if (index >= 6) {
          _keys[index - 6].requestFocus();
        } else {
          widget.onFocusBack();
        }
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  KeyEventResult _moveAction(int index, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowUp:
        _keys[30 + index * 2].requestFocus();
      case LogicalKeyboardKey.arrowRight:
        if (index == 2) {
          widget.onFocusResults();
        } else {
          _actions[index + 1].requestFocus();
        }
      case LogicalKeyboardKey.arrowLeft:
        if (index > 0) _actions[index - 1].requestFocus();
      case LogicalKeyboardKey.arrowDown:
        break;
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var row = 0; row < 6; row++)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  for (var col = 0; col < 6; col++) ...[
                    if (col > 0) const SizedBox(width: 8),
                    Expanded(child: _key(row * 6 + col)),
                  ],
                ],
              ),
            ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                  child: _action(
                      0, '删除', Icons.backspace_outlined, widget.onDelete)),
              const SizedBox(width: 8),
              Expanded(
                  child: _action(
                      1, '清空', Icons.restart_alt_rounded, widget.onClear)),
              const SizedBox(width: 8),
              Expanded(
                  child:
                      _action(2, '搜索', Icons.search_rounded, widget.onSearch)),
            ],
          ),
        ],
      );

  Widget _key(int index) => TvTap(
        key: ValueKey('tv-key-${_characters[index]}'),
        focusNode: _keys[index],
        autofocus: index == 0,
        focusScale: 1,
        borderRadius: 10,
        onTap: () {
          _lastKey = index;
          widget.onInput(_characters[index]);
        },
        child: Container(
          height: 42,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _focusedEntry == index
                ? const Color(0xFFFFEEF1)
                : const Color(0xFFF2F3F6),
            border: _focusedEntry == index
                ? Border.all(
                    color: Theme.of(context).colorScheme.primary, width: 1.8)
                : null,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(_characters[index],
              style:
                  const TextStyle(fontSize: 19, fontWeight: FontWeight.w600)),
        ),
      );

  Widget _action(int index, String label, IconData icon, VoidCallback onTap) =>
      TvTap(
        key: ValueKey('tv-keyboard-$index'),
        focusNode: _actions[index],
        focusScale: 1,
        borderRadius: 10,
        onTap: onTap,
        child: Container(
          height: 44,
          decoration: BoxDecoration(
            color:
                index == 2 ? const Color(0xFFFFEEF1) : const Color(0xFFF2F3F6),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 17),
              const SizedBox(width: 5),
              Text(label, style: const TextStyle(fontSize: 13)),
            ],
          ),
        ),
      );
}
