import 'package:flutter/material.dart';

/// TextField’lı dialog: controller dialog State’inde yaşar (dispose crash önler).
Future<String?> showSafeNameDialog({
  required BuildContext context,
  required String title,
  required String initialName,
  String label = 'Ad',
  String confirmLabel = 'Kaydet',
}) {
  return showDialog<String>(
    context: context,
    builder: (ctx) => _SafeNameDialog(
      title: title,
      initialName: initialName,
      label: label,
      confirmLabel: confirmLabel,
    ),
  );
}

class _SafeNameDialog extends StatefulWidget {
  final String title;
  final String initialName;
  final String label;
  final String confirmLabel;

  const _SafeNameDialog({
    required this.title,
    required this.initialName,
    required this.label,
    required this.confirmLabel,
  });

  @override
  State<_SafeNameDialog> createState() => _SafeNameDialogState();
}

class _SafeNameDialogState extends State<_SafeNameDialog> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialName);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _ctrl.text.trim();
    if (name.isEmpty) return;
    Navigator.pop(context, name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        textInputAction: TextInputAction.done,
        decoration: InputDecoration(
          labelText: widget.label,
          border: const OutlineInputBorder(),
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('İptal'),
        ),
        ElevatedButton(
          onPressed: _submit,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
