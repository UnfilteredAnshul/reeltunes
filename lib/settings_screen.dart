// Settings: appearance (system/light/dark), storage location,
// account/premium entry. Full pro unlocked while we build; gating later.

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'models.dart';

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
                subtitle: Text(store.saveFolder.isEmpty
                    ? 'Not chosen yet — set it now to decide '
                        'where extracted audio is saved.'
                    : store.saveFolder),
                trailing: const Icon(Icons.folder_copy_outlined),
                onTap: () => _pickFolder(context, store),
              ),
              const ListTile(
                title: Text('Delete on uninstall'),
                subtitle: Text(
                    'Everything ReelTune saves lives inside the app\'s own '
                    'storage. Uninstall and it is gone.'),
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
                title: const Text('Keep playing during calls'),
                subtitle: const Text(
                    'Audio keeps playing in the background even when a call '
                    'comes in. Off = playback pauses on every call.'),
                value: store.playDuringCalls,
                onChanged: (v) => store.setPlayDuringCalls(v),
              ),
              const _Section('Account'),
              const ListTile(
                title: Text('ReelTune Pro'),
                subtitle: Text('Everything unlocked while we build. '
                    'Trial pricing later: \$2.99/mo · \$19.99/yr.'),
                trailing: Icon(Icons.verified),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _pickFolder(BuildContext context, AppStore store) async {
    final t = await importAudioPickFolder();
    if (t != null) store.setSaveFolder(t);
  }
}

String? _importAudioPickFolderValue;
Future<String?> importAudioPickFolder() async {
  final p = await FilePicker.getDirectoryPath(
    dialogTitle: 'Choose where audios are saved',
  );
  return p ?? _importAudioPickFolderValue;
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
