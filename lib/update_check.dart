import 'dart:io';

import 'package:flutter/material.dart';
import 'package:in_app_update/in_app_update.dart';
import 'package:url_launcher/url_launcher.dart';

import 'top_toast.dart';

/// Play in-app update: asks the Play API whether a higher versionCode is live
/// on the track this install came from, and lets the user install it without
/// leaving the app.
///
/// Play-only by design. A sideloaded APK (adb install), a debug run or a
/// device without Play Services makes `checkForUpdate` fail; that is not an
/// error worth showing, so every failure is swallowed.
bool _checked = false;

Future<void> checkForPlayUpdate(BuildContext context) async {
  if (_checked || !Platform.isAndroid) return;
  _checked = true;

  AppUpdateInfo info;
  try {
    info = await InAppUpdate.checkForUpdate();
  } catch (_) {
    return; // not installed from Play, or the API is unavailable
  }
  if (info.updateAvailability != UpdateAvailability.updateAvailable) return;
  if (!context.mounted) return;

  final go = await showDialog<bool>(
    context: context,
    builder: (dialogCtx) => AlertDialog(
      title: const Text('Update available'),
      content: Text(
        'A newer version of ReelTunes is ready'
        '${info.availableVersionCode == null ? '' : ' (build ${info.availableVersionCode})'}. '
        'Install it now? Play downloads it and the app restarts when it is done.',
        style: const TextStyle(fontSize: 13.5, height: 1.45),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogCtx, false),
          child: const Text('Later'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogCtx, true),
          child: const Text('Update'),
        ),
      ],
    ),
  );
  if (go != true || !context.mounted) return;

  try {
    if (info.immediateUpdateAllowed) {
      // Full-screen Play flow; Android restarts the app when it is installed.
      await InAppUpdate.performImmediateUpdate();
      return;
    }
    if (info.flexibleUpdateAllowed) {
      await InAppUpdate.startFlexibleUpdate();
      if (context.mounted) {
        showTopToast(context, 'Update downloaded. Restarting to install.');
      }
      await InAppUpdate.completeFlexibleUpdate();
      return;
    }
  } catch (_) {
    // Fall through to the store listing below.
  }

  // Play refused the in-app flow (stale cache, oversized update, missing
  // permission): send the user to the store page instead of a dead button.
  final uri = Uri.parse(
      'https://play.google.com/store/apps/details?id=com.buildwithanshul.reeltunes');
  try {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {}
}
