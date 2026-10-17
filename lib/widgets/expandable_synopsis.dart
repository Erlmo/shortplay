import 'package:flutter/material.dart';

import 'tv_tap.dart';

/// 简介就地展开/收起，切换到另一季时恢复页面配置的默认状态。
class ExpandableSynopsis extends StatefulWidget {
  const ExpandableSynopsis(
      {super.key,
      required this.text,
      this.showHeading = true,
      this.initiallyExpanded = false});

  final String text;
  final bool showHeading;
  final bool initiallyExpanded;

  @override
  State<ExpandableSynopsis> createState() => _ExpandableSynopsisState();
}

class _ExpandableSynopsisState extends State<ExpandableSynopsis> {
  late bool _expanded;

  @override
  void initState() {
    super.initState();
    _expanded = widget.initiallyExpanded;
  }

  @override
  void didUpdateWidget(ExpandableSynopsis oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text ||
        oldWidget.initiallyExpanded != widget.initiallyExpanded) {
      _expanded = widget.initiallyExpanded;
    }
  }

  @override
  Widget build(BuildContext context) {
    const style =
        TextStyle(fontSize: 13, height: 1.7, color: Color(0xFF7C8190));
    return LayoutBuilder(builder: (context, constraints) {
      final painter = TextPainter(
          text: TextSpan(text: widget.text, style: style),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          maxLines: 2)
        ..layout(maxWidth: constraints.maxWidth);
      final canExpand = painter.didExceedMaxLines;
      painter.dispose();
      final toggle = TvTap(
        key: const ValueKey('synopsis-toggle'),
        focusScale: 1,
        borderRadius: 8,
        onTap: () => setState(() => _expanded = !_expanded),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(_expanded ? '收起' : '展开',
                style: const TextStyle(fontSize: 12, color: Color(0xFF7D8290))),
            const SizedBox(width: 2),
            Icon(
                _expanded
                    ? Icons.keyboard_arrow_up_rounded
                    : Icons.keyboard_arrow_down_rounded,
                size: 16,
                color: const Color(0xFF7D8290)),
          ]),
        ),
      );
      final body = AnimatedSize(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        alignment: Alignment.topLeft,
        child: Text(widget.text,
            key: const ValueKey('synopsis-text'),
            maxLines: _expanded ? null : 2,
            overflow: _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
            style: style),
      );
      if (!widget.showHeading) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            body,
            if (canExpand)
              Align(alignment: Alignment.centerRight, child: toggle),
          ],
        );
      }
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('剧情简介',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF484D5B))),
          const Spacer(),
          if (canExpand) toggle,
        ]),
        const SizedBox(height: 5),
        body,
      ]);
    });
  }
}
