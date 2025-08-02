import 'package:flutter/material.dart';
import 'package:animeshin/feature/edit/edit_view.dart';
import 'package:animeshin/feature/media/media_models.dart';
import 'package:animeshin/widget/sheets.dart';

class MediaEditButton extends StatefulWidget {
  const MediaEditButton(this.media);

  final Media media;

  @override
  State<MediaEditButton> createState() => _MediaEditButtonState();
}

class _MediaEditButtonState extends State<MediaEditButton> {
  @override
  Widget build(BuildContext context) {
    final media = widget.media;
    return FloatingActionButton(
      tooltip: media.entryEdit.listStatus == null ? 'Add' : 'Edit',
      child: media.entryEdit.listStatus == null
          ? const Icon(Icons.add)
          : const Icon(Icons.edit_outlined),
      onPressed: () => showSheet(
        context,
        EditView(
          (id: media.info.id, setComplete: false),
          callback: (entryEdit) => setState(() => media.entryEdit = entryEdit),
        ),
      ),
    );
  }
}
