import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Shared dropdown list for `RawAutocomplete` (item / customer pickers).
/// We use RawAutocomplete with OUR OWN controller + focus node so the text
/// can be set from code (recall a held bill, clear after add) without the
/// "copy controller text on every build" hack, which also leaked a new
/// listener on every rebuild.
Widget autocompleteOptionsView<T extends Object>(
  BuildContext context,
  AutocompleteOnSelected<T> onSelected,
  Iterable<T> options,
  String Function(T) label, {
  double maxWidth = 512,
  double maxHeight = 240,
}) {
  return Align(
    alignment: Alignment.topLeft,
    child: Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(12),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight, maxWidth: maxWidth),
        child: _OptionsList<T>(onSelected: onSelected, options: options, label: label),
      ),
    ),
  );
}

/// FIX (list haath se scroll nahi hoti thi): pehle highlighted item (default index 0) har rebuild par
/// `Scrollable.ensureVisible` se list ko wapas upar kheench leta tha, is liye ungli se scroll karte hi
/// list jhat se upar aa jati thi. Ab ensureVisible SIRF tab chalta hai jab highlighted option badle
/// (keyboard Up/Down), touch scroll par nahi.
class _OptionsList<T extends Object> extends StatefulWidget {
  const _OptionsList({required this.onSelected, required this.options, required this.label});
  final AutocompleteOnSelected<T> onSelected;
  final Iterable<T> options;
  final String Function(T) label;

  @override
  State<_OptionsList<T>> createState() => _OptionsListState<T>();
}

class _OptionsListState<T extends Object> extends State<_OptionsList<T>> {
  int _lastHighlight = -1;
  // build() set karta hai jab highlighted option badle; itemBuilder (scroll par bhi chalta hai) use sirf EK baar kharch karta hai.
  bool _pendingEnsure = false;
  // Apna alag controller: list kisi PrimaryScrollController (page ke scroll) se na jure, sirf ungli se hile.
  final ScrollController _sc = ScrollController();

  @override
  void dispose() {
    _sc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final highlightedIndex = AutocompleteHighlightedOption.of(context);
    if (highlightedIndex != _lastHighlight) _pendingEnsure = true;
    _lastHighlight = highlightedIndex;
    return Scrollbar(
      controller: _sc,
      thumbVisibility: widget.options.length > 4, // zyada naam hon to scroll-patti nazar aaye
      child: ListView.builder(
      controller: _sc,
      primary: false,
      padding: EdgeInsets.zero,
      shrinkWrap: true,
      physics: const AlwaysScrollableScrollPhysics(parent: ClampingScrollPhysics()),
      itemCount: widget.options.length,
      itemBuilder: (context, i) {
        final o = widget.options.elementAt(i);
        final highlighted = highlightedIndex == i;
        if (highlighted && _pendingEnsure) {
          _pendingEnsure = false;
          SchedulerBinding.instance.addPostFrameCallback((_) {
            if (context.mounted) Scrollable.ensureVisible(context, alignment: 0.5);
          });
        }
        return ListTile(
          dense: true,
          selected: highlighted,
          tileColor: highlighted ? Theme.of(context).colorScheme.primary.withOpacity(0.12) : null,
          title: Text(widget.label(o)),
          onTap: () => widget.onSelected(o),
        );
      },
      ),
    );
  }
}
