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
        child: ListView.builder(
          padding: EdgeInsets.zero,
          shrinkWrap: true,
          itemCount: options.length,
          itemBuilder: (context, i) {
            final o = options.elementAt(i);
            // Keyboard (Up/Down) se jo option highlighted hai, Enter wahi chunta hai.
            final highlighted = AutocompleteHighlightedOption.of(context) == i;
            if (highlighted) {
              SchedulerBinding.instance.addPostFrameCallback((_) {
                if (context.mounted) Scrollable.ensureVisible(context, alignment: 0.5);
              });
            }
            return ListTile(
              dense: true,
              selected: highlighted,
              tileColor: highlighted ? Theme.of(context).colorScheme.primary.withOpacity(0.12) : null,
              title: Text(label(o)),
              onTap: () => onSelected(o),
            );
          },
        ),
      ),
    ),
  );
}
