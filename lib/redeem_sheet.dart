// Redeem a code — a bottom sheet, like every other dialog in the app.
//
// The sheet is deliberately dumb: it collects a string, hands it to
// PromoEngine, and shows whatever sentence comes back. All the rules (revoked,
// expired, already used, grant length) live in lib/promo.dart, so when the
// server takes over this file does not change.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'entitlements.dart';
import 'promo.dart';

Future<PromoResult?> showRedeemSheet(BuildContext context) {
  return showModalBottomSheet<PromoResult>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const _RedeemSheet(),
  );
}

class _RedeemSheet extends StatefulWidget {
  const _RedeemSheet();

  @override
  State<_RedeemSheet> createState() => _RedeemSheetState();
}

class _RedeemSheetState extends State<_RedeemSheet> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    final code = _controller.text.trim();
    if (code.isEmpty) {
      setState(() => _error = 'Enter a code');
      _focus.requestFocus();
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await PromoEngine.I.redeem(code);
    if (!mounted) return;
    if (result.ok) {
      Navigator.of(context).pop(result);
      return;
    }
    setState(() {
      _busy = false;
      _error = result.message;
    });
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final e = Entitlements.I;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        20 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.confirmation_number_outlined, color: scheme.primary),
              const SizedBox(width: 10),
              Text(
                'Redeem a code',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            e.isPro
                ? '${e.statusLabel} · a code adds more time'
                : e.statusLabel,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 18),
          TextField(
            controller: _controller,
            focusNode: _focus,
            autofocus: true,
            enabled: !_busy,
            textCapitalization: TextCapitalization.characters,
            textInputAction: TextInputAction.done,
            maxLength: 24,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9\-_ ]')),
              LengthLimitingTextInputFormatter(24),
            ],
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.5,
            ),
            decoration: InputDecoration(
              labelText: 'Code',
              hintText: 'RTXXXXXXXX',
              counterText: '',
              errorText: _error,
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Redeem'),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Codes add Pro time. They never change the price Google Play shows '
            'at checkout.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
