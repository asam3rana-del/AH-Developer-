import 'package:flutter/material.dart';

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
            return ListTile(dense: true, title: Text(label(o)), onTap: () => onSelected(o));
          },
        ),
      ),
    ),
  );
}
