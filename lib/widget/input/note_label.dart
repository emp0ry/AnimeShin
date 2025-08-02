import 'package:flutter/material.dart';
import 'package:ionicons/ionicons.dart';
import 'package:animeshin/util/theming.dart';
import 'package:animeshin/widget/dialogs.dart';

class NotesLabel extends StatelessWidget {
  const NotesLabel(this.notes);

  final String notes;

  @override
  Widget build(BuildContext context) {
    if (notes.isEmpty) return const SizedBox();

    return SizedBox(
      height: 35,
      child: Tooltip(
        message: 'Comment',
        child: InkResponse(
          radius: Theming.radiusSmall.x,
          child: const Icon(Ionicons.chatbox, size: Theming.iconSmall),
          onTap: () => showDialog(
            context: context,
            builder: (context) => TextDialog(
              title: 'Comment',
              text: notes,
            ),
          ),
        ),
      ),
    );
  }
}
