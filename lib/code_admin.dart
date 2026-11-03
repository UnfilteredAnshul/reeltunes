// The code dashboard, inside the app.
//
// This is the same screen the Cloudflare dashboard will have (docs/promo-codes.md
// §8), scoped down to what a phone can do: see codes, create one, revoke one,
// read the redemption log. It runs against PromoEngine's local registry today,
// so it is fully usable before the Worker exists.
//
// Entry: Settings → Code dashboard. Visible in debug builds, and in release
// only after a master code unlocked the device.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'entitlements.dart';
import 'promo.dart';
import 'top_toast.dart';

class CodeDashboardScreen extends StatelessWidget {
  const CodeDashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Code dashboard'),
        actions: [
          IconButton(
            tooltip: 'New code',
            icon: const Icon(Icons.add),
            onPressed: () => _openCreate(context),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([PromoEngine.I, Entitlements.I]),
        builder: (context, _) {
          final promo = PromoEngine.I;
          final e = Entitlements.I;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              Card(
                color: scheme.surfaceContainerHighest,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'This device',
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        e.statusLabel,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      if (e.codeGrantActive) ...[
                        const SizedBox(height: 2),
                        Text(
                          e.codeGrantLifetime
                              ? 'Granted by ${e.codeGrantCode} · never expires'
                              : 'Granted by ${e.codeGrantCode} · ends '
                                    '${_date(e.codeGrantUntil)}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 18,
                        runSpacing: 8,
                        children: [
                          _Stat(
                            label: 'Live codes',
                            value: '${promo.liveCodeCount}',
                          ),
                          _Stat(
                            label: 'All codes',
                            value: '${promo.codeCount}',
                          ),
                          _Stat(
                            label: 'Redemptions',
                            value: '${promo.redemptionCount}',
                          ),
                          _Stat(label: 'Device', value: promo.deviceShort),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              _SectionHeader(
                title: 'Built-in',
                subtitle: 'Compiled in. Debug builds only.',
              ),
              for (final c in promo.builtIns) _BuiltInTile(code: c),
              const SizedBox(height: 20),
              _SectionHeader(
                title: 'Codes',
                subtitle:
                    'One redemption per device. Codes grant time, never '
                    'a price.',
                trailing: TextButton.icon(
                  onPressed: () => _openCreate(context),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('New'),
                ),
              ),
              if (promo.codes.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    'No codes yet. Create one to test the redeem flow — it works '
                    'immediately, no server needed.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                )
              else
                for (final c in promo.codes) _CodeTile(code: c),
              const SizedBox(height: 20),
              _SectionHeader(
                title: 'Redemptions',
                subtitle: 'Newest first. Device tag only.',
              ),
              if (promo.redemptions.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    'Nothing redeemed on this phone yet.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                )
              else
                for (final r in promo.redemptions.take(12))
                  _RedemptionTile(row: r),
              const SizedBox(height: 24),
              _SectionHeader(title: 'Danger zone'),
              Card(
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.block),
                      title: const Text('Revoke all codes'),
                      subtitle: const Text(
                        'Existing Pro time stays — only future redeems fail',
                      ),
                      onTap: () => _confirm(
                        context,
                        title: 'Revoke all codes?',
                        body:
                            'Every campaign code stops working immediately. '
                            'People who already redeemed keep their Pro time.',
                        action: 'Revoke all',
                        run: () => PromoEngine.I.revokeAll(),
                      ),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.delete_sweep_outlined),
                      title: const Text('Clear redemption log'),
                      subtitle: const Text(
                        'Test data only. On a real server this is audit history',
                      ),
                      onTap: () => _confirm(
                        context,
                        title: 'Clear the log?',
                        body:
                            'The device history is erased, so the same codes '
                            'can be redeemed again on this phone.',
                        action: 'Clear',
                        run: () => PromoEngine.I.clearLog(),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'When the Cloudflare Worker is live, this screen keeps its UI '
                'and PromoEngine.redeem() posts to /redeem instead. The local '
                'registry then only exists in debug builds.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _openCreate(BuildContext context) async {
    final created = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _CreateCodeSheet(),
    );
    if (created == null || !context.mounted) return;
    showTopToast(context, 'Code created: $created');
  }

  Future<void> _confirm(
    BuildContext context, {
    required String title,
    required String body,
    required String action,
    required Future<void> Function() run,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(action),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await run();
    if (!context.mounted) return;
    showTopToast(context, action == 'Clear' ? 'Log cleared' : 'Codes revoked');
  }
}

// ---- tiles ---------------------------------------------------------------

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  const _Stat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        value,
        style: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
      ),
      Text(label, style: Theme.of(context).textTheme.bodySmall),
    ],
  );
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;
  const _SectionHeader({required this.title, this.subtitle, this.trailing});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
              if (subtitle != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    subtitle!,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
            ],
          ),
        ),
        if (trailing != null) ?trailing,
      ],
    ),
  );
}

class _BuiltInTile extends StatelessWidget {
  final PromoCode code;
  const _BuiltInTile({required this.code});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(
          code.type == 'master' ? Icons.workspace_premium : Icons.restart_alt,
          color: scheme.primary,
        ),
        title: Text(
          code.code,
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            letterSpacing: 1.2,
          ),
        ),
        subtitle: Text('${code.grantLabel} · ${code.notes}'),
        trailing: IconButton(
          tooltip: 'Copy',
          icon: const Icon(Icons.copy, size: 18),
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: code.code));
            if (context.mounted) showTopToast(context, 'Copied ${code.code}');
          },
        ),
      ),
    );
  }
}

class _CodeTile extends StatelessWidget {
  final PromoCode code;
  const _CodeTile({required this.code});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final expired = code.expired || code.exhausted || code.revoked;
    final subtitle = [
      code.grantLabel,
      code.usesLabel,
      if (code.expired) 'expired',
      if (code.revoked) 'revoked',
      if (code.campaign.isNotEmpty) code.campaign,
    ].join(' · ');
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(
          code.usable ? Icons.qr_code_2 : Icons.qr_code_2_outlined,
          color: code.usable ? scheme.primary : scheme.outline,
        ),
        title: Text(
          code.code,
          style: TextStyle(
            fontWeight: FontWeight.w700,
            letterSpacing: 1.2,
            color: expired ? scheme.outline : null,
          ),
        ),
        subtitle: Text(subtitle),
        onTap: () async {
          await Clipboard.setData(ClipboardData(text: code.code));
          if (context.mounted) showTopToast(context, 'Copied ${code.code}');
        },
        trailing: PopupMenuButton<String>(
          onSelected: (v) async {
            switch (v) {
              case 'revoke':
                await PromoEngine.I.setRevoked(code.code, !code.revoked);
                if (context.mounted) {
                  showTopToast(
                    context,
                    code.revoked ? 'Code switched on' : 'Code revoked',
                  );
                }
                break;
              case 'delete':
                await PromoEngine.I.deleteCode(code.code);
                if (context.mounted) showTopToast(context, 'Code deleted');
                break;
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(
              value: 'revoke',
              child: Text(code.revoked ? 'Switch back on' : 'Revoke'),
            ),
            const PopupMenuItem(value: 'delete', child: Text('Delete')),
          ],
        ),
      ),
    );
  }
}

class _RedemptionTile extends StatelessWidget {
  final Map<String, dynamic> row;
  const _RedemptionTile({required this.row});

  @override
  Widget build(BuildContext context) {
    final code = row['code']?.toString() ?? '';
    final device = row['device']?.toString() ?? '';
    final at = (row['atMs'] as num?)?.toInt() ?? 0;
    final untilMs = (row['untilMs'] as num?)?.toInt();
    final lifetime = row['lifetime'] == true;
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: const Icon(Icons.check_circle_outline, size: 18),
      title: Text(code, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(
        '${device.length >= 6 ? device.substring(0, 6) : device} · ${_ago(at)}'
        '${lifetime
            ? ' · lifetime'
            : untilMs == null
            ? ''
            : ' · until ${_date(DateTime.fromMillisecondsSinceEpoch(untilMs))}'}',
      ),
    );
  }
}

// ---- create sheet --------------------------------------------------------

class _CreateCodeSheet extends StatefulWidget {
  const _CreateCodeSheet();

  @override
  State<_CreateCodeSheet> createState() => _CreateCodeSheetState();
}

class _CreateCodeSheetState extends State<_CreateCodeSheet> {
  final _custom = TextEditingController();
  final _days = TextEditingController(text: '30');
  final _maxUses = TextEditingController(text: '0');
  final _validFor = TextEditingController(text: '0');
  final _campaign = TextEditingController();
  final _notes = TextEditingController();
  String _type = 'pro_grant';
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_custom, _days, _maxUses, _validFor, _campaign, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _create() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await PromoEngine.I.createCode(
      type: _type,
      days: int.tryParse(_days.text.trim()) ?? 0,
      maxUses: int.tryParse(_maxUses.text.trim()) ?? 0,
      validForDays: int.tryParse(_validFor.text.trim()) ?? 0,
      campaign: _campaign.text,
      notes: _notes.text,
      custom: _custom.text,
    );
    if (!mounted) return;
    if (!result.ok) {
      setState(() {
        _busy = false;
        _error = result.message;
      });
      return;
    }
    Navigator.of(context).pop(result.message);
  }

  @override
  Widget build(BuildContext context) {
    final isMaster = _type == 'master';
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        20 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('New code', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              initialValue: _type,
              decoration: const InputDecoration(
                labelText: 'Type',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(
                  value: 'pro_grant',
                  child: Text('Pro grant (days)'),
                ),
                DropdownMenuItem(
                  value: 'pro_long',
                  child: Text('Long Pro grant (days)'),
                ),
                DropdownMenuItem(
                  value: 'master',
                  child: Text('Lifetime Pro (careful)'),
                ),
              ],
              onChanged: _busy
                  ? null
                  : (v) => setState(() => _type = v ?? 'pro_grant'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _custom,
              enabled: !_busy,
              textCapitalization: TextCapitalization.characters,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9\-_ ]')),
                LengthLimitingTextInputFormatter(24),
              ],
              decoration: const InputDecoration(
                labelText: 'Code (optional)',
                hintText: 'Leave empty to generate RTXXXXXXXX',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            if (!isMaster)
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _days,
                      enabled: !_busy,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(
                        labelText: 'Days of Pro',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _maxUses,
                      enabled: !_busy,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(
                        labelText: 'Max uses',
                        helperText: '0 = unlimited',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ],
              )
            else
              Text(
                'Lifetime codes never expire and never count down. Create them '
                'only for devices you control.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            const SizedBox(height: 12),
            TextField(
              controller: _validFor,
              enabled: !_busy,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                labelText: 'Code valid for (days)',
                helperText: '0 = never expires',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _campaign,
              enabled: !_busy,
              decoration: const InputDecoration(
                labelText: 'Campaign (optional)',
                hintText: 'launch-1000',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _notes,
              enabled: !_busy,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Notes (optional)',
                border: OutlineInputBorder(),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _busy ? null : _create,
                child: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Create code'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---- formatting ----------------------------------------------------------

String _date(DateTime? d) {
  if (d == null) return '—';
  return '${const ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][d.month - 1]} ${d.day}';
}

String _ago(int ms) {
  if (ms <= 0) return '—';
  final diff = DateTime.now().difference(
    DateTime.fromMillisecondsSinceEpoch(ms),
  );
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inHours < 1) return '${diff.inMinutes}m ago';
  if (diff.inDays < 1) return '${diff.inHours}h ago';
  if (diff.inDays < 7) return '${diff.inDays}d ago';
  return _date(DateTime.fromMillisecondsSinceEpoch(ms));
}
