import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/party_photo_store.dart';
import '../utils/loc.dart';

/// Party ki gol tasveer; na ho to naam ka pehla harf. [onTap] null ho to sirf dikhata hai.
class PartyAvatar extends StatefulWidget {
  final bool isCustomer;
  final int? partyId;
  final String name;
  final double radius;
  final VoidCallback? onTap;
  const PartyAvatar({
    super.key,
    required this.isCustomer,
    required this.partyId,
    required this.name,
    this.radius = 22,
    this.onTap,
  });

  @override
  State<PartyAvatar> createState() => _PartyAvatarState();
}

class _PartyAvatarState extends State<PartyAvatar> {
  final _store = PartyPhotoStore.instance;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _store.ensureLoaded().then((_) {
      if (mounted) setState(() => _ready = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final avatar = ValueListenableBuilder<int>(
      valueListenable: _store.changes,
      builder: (_, __, ___) {
        final id = widget.partyId;
        final path = (_ready && id != null) ? _store.pathFor(widget.isCustomer, id) : null;
        final initial = widget.name.trim().isEmpty ? '?' : widget.name.trim().characters.first.toUpperCase();
        final bg = Theme.of(context).colorScheme.primary.withOpacity(0.12);
        return CircleAvatar(
          radius: widget.radius,
          backgroundColor: bg,
          backgroundImage: path == null ? null : ResizeImage(FileImage(File(path)), width: (widget.radius * 4).round()),
          child: path == null
              ? Text(initial, style: TextStyle(fontSize: widget.radius * 0.9, fontWeight: FontWeight.w600))
              : null,
        );
      },
    );
    if (widget.onTap == null) return avatar;
    return InkWell(customBorder: const CircleBorder(), onTap: widget.onTap, child: avatar);
  }
}

/// Camera / Gallery / Hata dein — party ki tasveer badalne ka bottom sheet.
Future<void> showPartyPhotoSheet(BuildContext context, {required bool isCustomer, required int partyId}) async {
  final store = PartyPhotoStore.instance;
  await store.ensureLoaded();
  if (!context.mounted) return;
  final has = store.pathFor(isCustomer, partyId) != null;
  final messenger = ScaffoldMessenger.of(context);
  final choice = await showModalBottomSheet<String>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(
          leading: const Icon(Icons.photo_camera),
          title: Text(Loc.t('Take photo', 'کیمرے سے تصویر')),
          onTap: () => Navigator.pop(ctx, 'camera'),
        ),
        ListTile(
          leading: const Icon(Icons.photo_library),
          title: Text(Loc.t('Choose from gallery', 'گیلری سے چنیں')),
          onTap: () => Navigator.pop(ctx, 'gallery'),
        ),
        if (has)
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: Text(Loc.t('Remove photo', 'تصویر ہٹائیں')),
            onTap: () => Navigator.pop(ctx, 'remove'),
          ),
      ]),
    ),
  );
  if (choice == null) return;
  try {
    if (choice == 'remove') {
      await store.remove(customer: isCustomer, id: partyId);
    } else {
      await store.pick(choice == 'camera' ? ImageSource.camera : ImageSource.gallery, customer: isCustomer, id: partyId);
    }
  } catch (_) {
    messenger.showSnackBar(SnackBar(content: Text(Loc.t('Photo could not be saved (check camera/photos permission)', 'تصویر محفوظ نہ ہو سکی (کیمرہ/فوٹو اجازت دیکھیں)'))));
  }
}
