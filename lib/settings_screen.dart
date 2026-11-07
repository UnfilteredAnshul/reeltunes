// Settings: appearance (system/light/dark), storage location,
// account/premium entry. Full pro unlocked while we build; gating later.

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'ad_config.dart';
import 'ads.dart';
import 'billing.dart';
import 'code_admin.dart';
import 'coins.dart';
import 'entitlements.dart';
import 'library_sync.dart';
import 'models.dart';
import 'promo.dart';
import 'redeem_sheet.dart';
import 'shop_sheet.dart';
import 'sheets.dart';
import 'top_toast.dart';
import 'receipt_email.dart';
import 'notification_service.dart';

/// Where bug reports and suggestions go (mail app handoff, no server).
const feedbackEmail = 'contact.unfiltered.anshul@gmail.com';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListenableBuilder(
        listenable: AppStore.I,
        builder: (context, _) {
          final store = AppStore.I;
          return ListView(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Card(
                  margin: EdgeInsets.zero,
                  color: Theme.of(context).colorScheme.primaryContainer,
                  child: ListTile(
                    leading: const Icon(Icons.menu_book_outlined),
                    title: const Text('How ReelTunes works',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: const Text('Short guide. Plain words.'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => showGuideSheet(context),
                  ),
                ),
              ),
              const _Section('Appearance'),
              RadioGroup<AppThemeMode>(
                groupValue: store.themeMode,
                onChanged: (v) => store.setThemeMode(v!),
                child: const Column(
                  children: [
                    _ThemeRadio(AppThemeMode.system, 'System default',
                        'Follow the device setting'),
                    _ThemeRadio(AppThemeMode.light, 'Light', ''),
                    _ThemeRadio(AppThemeMode.dark, 'Dark', ''),
                  ],
                ),
              ),
              const _Section('Storage'),
              ListTile(
                title: const Text('Audios folder'),
                subtitle: Text(store.audiosLinked
                    ? '${store.audiosName} · saved audios, playlists and any '
                        'file you drop in live here'
                    : 'Not linked yet — choose the folder where audios are '
                        'saved. It survives uninstall and reinstalls.'),
                trailing: Icon(store.audiosLinked
                    ? Icons.folder_rounded
                    : Icons.folder_copy_outlined),
                onTap: () => _linkFolder(context, store),
              ),
              if (store.audiosLinked)
                ListTile(
                  leading: const Icon(Icons.sync),
                  title: const Text('Re-scan folder now'),
                  subtitle: const Text(
                      'Adds files you dropped in with a file manager'),
                  onTap: () async {
                    final n = await LibrarySync.sync();
                    if (!context.mounted) return;
                    showTopToast(
                        context,
                        n == 0
                            ? 'Folder checked — nothing new'
                            : 'Added $n new audio${n == 1 ? '' : 's'}');
                  },
                ),
              ListTile(
                title: const Text('Uninstall and your library'),
                subtitle: Text(store.audiosLinked
                    ? 'Your audio files and a copy of your playlists stay in '
                        'that folder. Reinstall, link the same folder, and '
                        'everything comes back.'
                    : 'Audio files stay where they are. Link the folder after '
                        'reinstalling to get your playlists back.'),
              ),
              const _Section('Playback'),
              SwitchListTile(
                title: const Text('Confirm before delete'),
                subtitle: const Text(
                    'Ask before an audio (and its file) is deleted. '
                    'Off = deletes instantly (you can always turn this back on).'),
                value: store.confirmDelete,
                onChanged: (v) => store.setConfirmDelete(v),
              ),
              SwitchListTile(
                title: const Text('Confirm before removing'),
                subtitle: const Text(
                    'Ask before an audio leaves your library (the file stays '
                    'on your phone). Covers the track menu and playlist edits.'),
                value: store.confirmRemove,
                onChanged: (v) => store.setConfirmRemove(v),
              ),
              SwitchListTile(
                title: const Text('Keep playing during calls'),
                subtitle: const Text(
                    'Audio keeps playing in the background even when a call '
                    'comes in. Off = playback pauses on every call.'),
                value: store.playDuringCalls,
                onChanged: (v) => store.setPlayDuringCalls(v),
              ),
              const _Section('Privacy'),
              const _AdPrivacyTile(),
              const _Section('Notifications'),
              _NotificationSettingsTile(),
              const _Section('Support'),
              ListTile(
                leading: const Icon(Icons.bug_report_outlined),
                title: const Text('Report a bug / Send a suggestion'),
                subtitle: const Text(
                    'Opens your mail app, addressed to $feedbackEmail'),
                trailing: const Icon(Icons.open_in_new, size: 18),
                onTap: () => _sendFeedback(context),
              ),
              const _Section('Account'),
              ListenableBuilder(
                listenable: Entitlements.I,
                builder: (context, _) {
                  final e = Entitlements.I;
                  return Column(children: [
                    ListTile(
                      leading: Icon(e.isPro
                          ? Icons.verified
                          : Icons.workspace_premium_outlined),
                      title: const Text('ReelTunes Pro'),
                      subtitle: Text(
                        e.isPro
                            ? '${e.statusLabel} · no ads, unlimited audios'
                            : '${e.statusLabel} · then 25 audios, 2 playlists, ads',
                      ),
                      trailing: e.isPro
                          ? null
                          : FilledButton(
                              onPressed: () =>
                                  showPaywallSheet(context, reason: e.capped
                                      ? 'Free tier limits'
                                      : 'Keep everything after the trial'),
                              child: const Text('Get Pro'),
                            ),
                      onTap: () => showPaywallSheet(context),
                    ),
                    ListTile(
                      leading: const Icon(Icons.confirmation_number_outlined),
                      title: const Text('Redeem a code'),
                      subtitle: const Text(
                          'Adds Pro time · never changes the Play price'),
                      onTap: () async {
                        final result = await showRedeemSheet(context);
                        if (result == null || !context.mounted) return;
                        showTopToast(context, result.message);
                      },
                    ),
                    if (kDebugMode || PromoEngine.I.adminUnlocked)
                      ListTile(
                        leading:
                            const Icon(Icons.dashboard_customize_outlined),
                        title: const Text('Code dashboard'),
                        subtitle: const Text(
                            'Create, revoke and inspect codes on this device'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const CodeDashboardScreen()),
                        ),
                      ),
                    // Only meaningful once the store is live and nothing is
                    // active: reinstalls and new phones land here.
                    if (!e.isPro && Billing.I.configured)
                      ListTile(
                        leading: const Icon(Icons.restore),
                        title: const Text('Restore purchases'),
                        subtitle: const Text(
                            'Bring back Pro bought with this Google account'),
                        onTap: () async {
                          final report = await Billing.I.restore();
                          if (!context.mounted) return;
                          showTopToast(
                            context,
                            report.ok
                                ? 'Pro restored'
                                : report.message ?? 'Nothing to restore',
                            error: !report.ok,
                          );
                        },
                      ),
                  ]);
                },
              ),
              if (kDebugMode) _DebugTierSection(),
            ],
          );
        },
      ),
    );
  }

  Future<void> _linkFolder(BuildContext context, AppStore store) async {
    // The folder is locked once chosen: changing it is deliberate, never a
    // stray tap. So a linked folder opens a small sheet instead of a picker.
    if (store.audiosLinked) {
      final action = await showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        builder: (sheetCtx) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(
              leading: const Icon(Icons.folder_rounded),
              title: Text(store.audiosName.isEmpty
                  ? defaultSaveFolderName
                  : store.audiosName),
              subtitle: const Text('Locked audios folder'),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.sync),
              title: const Text('Re-scan now'),
              subtitle: const Text('Picks up files you dropped in'),
              onTap: () => Navigator.pop(sheetCtx, 'scan'),
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_move_outline),
              title: const Text('Change folder'),
              subtitle: const Text(
                  'Only affects new saves — existing files stay where they are'),
              onTap: () => Navigator.pop(sheetCtx, 'change'),
            ),
          ]),
        ),
      );
      if (!context.mounted) return;
      if (action == 'scan') {
        final n = await LibrarySync.sync();
        if (!context.mounted) return;
        showTopToast(
            context,
            n == 0
                ? 'Folder checked — nothing new'
                : 'Added $n new audio${n == 1 ? '' : 's'}');
        return;
      }
      if (action != 'change') return;
      final ok = await showModalBottomSheet<bool>(
        context: context,
        showDragHandle: true,
        builder: (sheetCtx) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text('Change the audios folder?',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 18)),
              const SizedBox(height: 8),
              const Text('New downloads go to the new folder. Your existing '
                  'audio files and playlists are not moved.'),
              const SizedBox(height: 16),
              Row(children: [
                TextButton(
                    onPressed: () => Navigator.pop(sheetCtx, false),
                    child: const Text('Keep current')),
                const Spacer(),
                FilledButton(
                    onPressed: () => Navigator.pop(sheetCtx, true),
                    child: const Text('Choose new folder')),
              ]),
            ]),
          ),
        ),
      );
      if (ok != true || !context.mounted) return;
    }

    final picked = await LibrarySync.link();
    if (!context.mounted) return;
    if (picked == null) return;
    store.completeFirstRun(picked.name ?? defaultSaveFolderName);
    showTopToast(context,
        'Folder linked — ${picked.name ?? defaultSaveFolderName}');
  }

  /// Bug reports / suggestions open the device's mail app pre-addressed to
  /// the developer — no form, no backend, nothing leaves the phone unless
  /// the user sends it.
  Future<void> _sendFeedback(BuildContext context) async {
    final uri = Uri(
      scheme: 'mailto',
      path: feedbackEmail,
      query:
          'subject=${Uri.encodeComponent('ReelTunes — bug report / suggestion')}',
    );
    var opened = false;
    try {
      opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      opened = false;
    }
    if (!opened && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('No mail app found — write to $feedbackEmail'),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }
}

String? _importAudioPickFolderValue;
Future<String?> importAudioPickFolder() async {
  final p = await FilePicker.getDirectoryPath(
    dialogTitle: 'Choose where audios are saved',
  );
  return p ?? _importAudioPickFolderValue;
}

/// Opens Google's UMP consent / privacy options form. Always present in debug
/// so the flow is testable; in release AdMob tells us whether the row is
/// required (EEA/UK/CH users) and we render it when it is.
class _AdPrivacyTile extends StatelessWidget {
  const _AdPrivacyTile();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: Ads.I.privacyOptionsRequired(),
      builder: (context, snap) {
        final required = snap.data ?? false;
        if (!kDebugMode && !required) return const SizedBox.shrink();
        return ListTile(
          leading: const Icon(Icons.privacy_tip_outlined),
          title: const Text('Ad privacy choices'),
          subtitle: const Text(
              'Change how ads may use your data · Google AdMob'),
          onTap: () => Ads.I.showPrivacyOptions(),
        );
      },
    );
  }
}

class _Section extends StatelessWidget {
  final String text;
  const _Section(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 12, 4),
        child: Text(text,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
      );
}

class _NotificationSettingsTile extends StatefulWidget {
  const _NotificationSettingsTile();
  @override
  State<_NotificationSettingsTile> createState() => _NotificationSettingsTileState();
}

class _NotificationSettingsTileState extends State<_NotificationSettingsTile> {
  @override
  Widget build(BuildContext context) {
    final n = NotificationService.I;
    return Column(children: [
      SwitchListTile(
        title: const Text('Vibrate on alerts'),
        subtitle: const Text('Perk and Pro expiry notifications vibrate.'),
        value: n.vibrate,
        onChanged: (v) => n.setVibrate(v),
      ),
      ListTile(
        leading: const Icon(Icons.volume_up),
        title: const Text('Notification sound'),
        subtitle: Text(n.soundUri != null ? 'Custom sound set' : 'Default sound'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () async {
          // Open the system ringtone picker
          try {
            final picked = await showDialog<String>(
              context: context,
              builder: (ctx) => SimpleDialog(
                title: const Text('Choose notification sound'),
                children: [
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(ctx, 'default'),
                    child: const Text('Default'),
                  ),
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(ctx, 'system_1'),
                    child: const Text('System 1'),
                  ),
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(ctx, 'system_2'),
                    child: const Text('System 2'),
                  ),
                ],
              ),
            );
            if (picked != null && mounted) {
              await n.setSoundUri(picked == 'default' ? null : picked);
              setState(() {});
            }
          } catch (_) {
            // Ringtone picker may not be available on all devices — silently skip.
          }
        },
      ),
    ]);
  }
}

class _ThemeRadio extends StatelessWidget {
  final AppThemeMode value;
  final String title;
  final String subtitle;
  const _ThemeRadio(this.value, this.title, this.subtitle);
  @override
  Widget build(BuildContext context) {
    return RadioListTile<AppThemeMode>(
      value: value,
      title: Text(title),
      subtitle: subtitle.isEmpty ? null : Text(subtitle),
    );
  }
}

/// Debug-only tier controls so both plans are testable without waiting out the
/// 7-day trial or going through Play Billing. Stripped from release builds.
class _DebugTierSection extends StatefulWidget {
  const _DebugTierSection();

  @override
  State<_DebugTierSection> createState() => _DebugTierSectionState();
}

class _DebugTierSectionState extends State<_DebugTierSection> {
  final _coinCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();

  @override
  void dispose() {
    _coinCtrl.dispose();
    _emailCtrl.dispose();
    super.dispose();
  }

  static String _when(DateTime? d) {
    if (d == null) return 'never';
    final h = d.hour.toString().padLeft(2, '0');
    final m = d.minute.toString().padLeft(2, '0');
    return '${d.day}/${d.month} · $h:$m';
  }

  List<Widget> _activePerks(BuildContext context) {
    final coins = CoinWallet.I;
    final out = <Widget>[];
    for (final p in CoinWallet.perks) {
      if (!coins.isPerkActive(p.id)) continue;
      out.add(
        ListTile(
          leading: Icon(p.icon, color: coinGold, size: 20),
          title: Text(p.title),
          subtitle: Text('Active until ${_when(coins.perkUntil(p.id))}'),
          trailing: IconButton(
            icon: const Icon(Icons.delete_outline, size: 18),
            tooltip: 'Remove perk',
            onPressed: () async {
              await coins.removePerk(p.id);
              if (!mounted) return;
              showTopToast(context, '${p.title} removed');
            },
          ),
        ),
      );
    }
    return out;
  }

  Future<void> _setCustomCoins() async {
    final coins = CoinWallet.I;
    final v = int.tryParse(_coinCtrl.text.trim());
    if (v == null) {
      showTopToast(context, 'Enter a whole number', error: true);
      return;
    }
    await coins.setBalance(v);
    _coinCtrl.clear();
    if (!mounted) return;
    showTopToast(context, 'Coins set to $v');
  }

  Future<void> _setEmail() async {
    final email = _emailCtrl.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      showTopToast(context, 'Enter a valid email address', error: true);
      return;
    }
    ReceiptEmail.I.setEmail(email);
    _emailCtrl.clear();
    if (!mounted) return;
    showTopToast(context, 'Receipt email saved');
  }

  @override
  Widget build(BuildContext context) {
    final e = Entitlements.I;
    final coins = CoinWallet.I;
    final active = _activePerks(context);
    return ListenableBuilder(
      listenable: Listenable.merge([e, coins, Ads.I]),
      builder: (context, _) => Column(children: [
        const _Section('Debug · tiers'),
        SwitchListTile(
          title: const Text('Force Pro'),
          subtitle: Text(e.statusLabel),
          value: e.debugPro,
          onChanged: (v) => e.setDebugPro(v),
        ),
        SwitchListTile(
          title: const Text('Force Free'),
          subtitle: const Text(
              'Caps, ads flag and paywalls — wins over a purchase, code or live trial'),
          value: e.debugFree,
          onChanged: (v) => e.setDebugFree(v),
        ),
        ListTile(
          leading: const Icon(Icons.timer_outlined),
          title: const Text('Trial: jump to the last day'),
          subtitle: const Text('Triggers the 1-day reminder on next resume'),
          onTap: () async {
            await e.fastForwardTrialToLastDay();
            if (context.mounted) showTopToast(context, 'Trial ends tomorrow');
          },
        ),
        ListTile(
          leading: const Icon(Icons.timer_off_outlined),
          title: const Text('Trial: end it now'),
          subtitle: const Text('Free tier: 25 audios, 2 playlists, ads flag'),
          onTap: () async {
            await e.endTrialNow();
            if (context.mounted) showTopToast(context, 'Free tier active');
          },
        ),
        ListTile(
          leading: const Icon(Icons.restart_alt),
          title: const Text('Trial: reset'),
          onTap: () async {
            await e.resetTrial();
            if (context.mounted) showTopToast(context, 'Trial reset');
          },
        ),
        const Divider(height: 1),
        const _Section('Debug · coins'),
        ListTile(
          leading: const Icon(Icons.monetization_on_outlined),
          title: Text('Coins: ${coins.balance}'),
          subtitle: Text(coins.adFree
              ? 'No-ads window active until '
                  '${coins.adFreeUntil?.day}/${coins.adFreeUntil?.month} '
                  '${coins.adFreeUntil?.hour.toString().padLeft(2, '0')}:'
                  '${coins.adFreeUntil?.minute.toString().padLeft(2, '0')}'
              : 'Shop perks expire on their own'),
          isThreeLine: coins.adFree,
        ),
        Row(children: [
          Expanded(
            child: TextButton.icon(
              onPressed: () async {
                await coins.debugGrant();
                if (context.mounted) showTopToast(context, '+100 coins');
              },
              icon: const Icon(Icons.add_circle_outline),
              label: const Text('Give 100 coins'),
            ),
          ),
          Expanded(
            child: TextButton.icon(
              onPressed: () async {
                await coins.debugReset();
                if (context.mounted) {
                  showTopToast(context, 'Coins and perks cleared');
                }
              },
              icon: const Icon(Icons.delete_sweep_outlined),
              label: const Text('Reset coins'),
            ),
          ),
        ]),
        // Set a custom coin balance.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: TextField(
            controller: _coinCtrl,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Set coins to (debug)',
              border: OutlineInputBorder(),
              prefixText: '₹0 → ',
              helperText: 'Any whole number. Overwrites the current balance.',
            ),
            onSubmitted: (_) => _setCustomCoins(),
          ),
        ),
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: _setCustomCoins,
            icon: const Icon(Icons.done),
            label: const Text('Set'),
          ),
        ),
        const Divider(height: 1),
        // Email for receipt delivery (Resend-backed endpoint).
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: TextField(
            controller: _emailCtrl,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(
              labelText: 'Receipt email (debug)',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.email),
              helperText: 'Enter your email to receive the Pro purchase receipt.',
            ),
            onSubmitted: (_) => _setEmail(),
          ),
        ),
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: _setEmail,
            icon: const Icon(Icons.done),
            label: const Text('Save'),
          ),
        ),
        const Divider(height: 1),
        // Active perks: list each one with its expiry and a delete button.
        const _Section('Debug · active perks'),
        if (active.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Text('No perks active',
                style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic)),
          )
        else
          ...active,
        const Divider(height: 1),
        SwitchListTile(
          title: const Text('Use test ad units'),
          subtitle: const Text(
              'Google samples, safe to tap. Off = live AdMob units '
              '(never tap your own ad).'),
          value: Ads.I.useTestAds,
          onChanged: (v) => Ads.I.setUseTestAds(v),
        ),
        ListTile(
          leading: const Icon(Icons.campaign_outlined),
          title: const Text('Ads: unit in use'),
          subtitle: Text(AdConfig.modeLabel),
          isThreeLine: AdConfig.appIdMismatch,
        ),
        if (AdConfig.appIdMismatch)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              'The Dart banner unit is live but AndroidManifest.xml still has '
              "Google's sample app id. Paste the AdMob app id there before "
              'building a release.',
              style: TextStyle(fontSize: 12),
            ),
          ),
      ]),
    );
  }
}
