// Privacy Policy / Terms acceptance.
//
// Two records are kept:
//  * SharedPreferences — the fast local copy the app reads on every launch.
//  * Download/ReelTunes/consent.json, written through MediaStore by the native
//    ConsentBridge — survives "Clear data" and an uninstall, so a reinstall can
//    show the previous acceptance and ask the user to confirm again.
//
// The audios folder is deliberately not used: the user may delete or re-pick
// it, and consent is not media.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'legal.dart';

const _channel = MethodChannel('com.buildwithanshul.reeltunes/consent');

/// Bump whenever the Privacy Policy or Terms change in a way that needs a new
/// agreement. A mismatch makes every install show the dialog again.
const String currentPolicyVersion = '2026-11-15';

class ConsentService {
  ConsentService._();
  static final ConsentService I = ConsentService._();

  static const _kVersion = 'consentPolicyVersion';
  static const _kAt = 'consentAcceptedAtMs';
  static const _kFirst = 'consentFirstAcceptedAtMs';

  bool _loaded = false;

  /// A local acceptance for [currentPolicyVersion] exists.
  bool agreed = false;

  /// Last acceptance on this install.
  DateTime? acceptedAt;

  /// First acceptance ever recorded for this phone (the durable file keeps it
  /// across reinstalls).
  DateTime? firstAcceptedAt;

  /// The version string that was accepted locally, if any.
  String? acceptedVersion;

  /// The durable file exists and holds an acceptance for the current version,
  /// but this install has no local record: reinstall or cleared data.
  bool reinstalled = false;

  /// True when Download/ReelTunes/consent.json is readable.
  bool durable = false;

  /// Every acceptance timestamp the durable file knows about, newest first.
  List<DateTime> history = const [];

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;

    final prefs = await SharedPreferences.getInstance();
    final localVersion = prefs.getString(_kVersion);
    final localAt = prefs.getInt(_kAt);
    acceptedVersion = localVersion;
    acceptedAt =
        localAt == null ? null : DateTime.fromMillisecondsSinceEpoch(localAt);
    final firstLocal = prefs.getInt(_kFirst);
    firstAcceptedAt = firstLocal == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(firstLocal);
    final localOk = localVersion == currentPolicyVersion && localAt != null;
    agreed = localOk;

    Map<Object?, Object?> remote = const {};
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>('read');
      remote = raw ?? const {};
    } catch (e) {
      debugPrint('consent: native read unavailable $e');
    }

    durable = remote['durable'] == true;
    final remoteAgreed = remote['agreed'] == true &&
        remote['policyVersion'] == currentPolicyVersion;
    final remoteAt = (remote['acceptedAtMs'] as num?)?.toInt() ?? 0;
    final remoteFirst = (remote['firstAcceptedAtMs'] as num?)?.toInt() ?? 0;
    if (remoteFirst > 0) {
      firstAcceptedAt = DateTime.fromMillisecondsSinceEpoch(remoteFirst);
    }
    final stamps = remote['acceptances'];
    if (stamps is List) {
      history = [
        for (final value in stamps)
          if (value is num && value.toInt() > 0)
            DateTime.fromMillisecondsSinceEpoch(value.toInt()),
      ];
    }

    if (remoteAgreed && remoteAt > 0) {
      reinstalled = !localOk;
      agreed = localOk;
    } else if (!localOk) {
      agreed = false;
    }

    // Local acceptance but no durable copy (older install, MediaStore refusal):
    // try once in the background so the next reinstall has something to read.
    if (localOk && !durable) {
      unawaited(_writeDurable(localAt));
    }
  }

  bool get needsAgreement => !agreed;

  /// Records the acceptance. Returns false when only the local copy could be
  /// written (the app still works; the durable record is retried next launch).
  Future<bool> accept() async {
    final now = DateTime.now();
    final prefs = await SharedPreferences.getInstance();
    final first = prefs.getInt(_kFirst) ??
        firstAcceptedAt?.millisecondsSinceEpoch ??
        now.millisecondsSinceEpoch;
    await prefs.setString(_kVersion, currentPolicyVersion);
    await prefs.setInt(_kAt, now.millisecondsSinceEpoch);
    await prefs.setInt(_kFirst, first);

    agreed = true;
    acceptedVersion = currentPolicyVersion;
    acceptedAt = now;
    firstAcceptedAt = DateTime.fromMillisecondsSinceEpoch(first);
    reinstalled = false;
    final ok = await _writeDurable(now.millisecondsSinceEpoch);
    durable = ok;
    return ok;
  }

  Future<bool> _writeDurable(int acceptedAtMs) async {
    try {
      final ok = await _channel.invokeMethod<bool>('write', {
        'acceptedAtMs': acceptedAtMs,
        'policyVersion': currentPolicyVersion,
      });
      return ok ?? false;
    } catch (e) {
      debugPrint('consent: durable write failed $e');
      return false;
    }
  }
}

/// Required before the first import or the first-run setup. Not dismissible:
/// the only way forward is the checkbox plus the agree button. Back gestures
/// are swallowed so the dialog cannot be skipped.
Future<bool> showConsentDialog(BuildContext context) async {
  final accepted = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const ConsentDialog(),
  );
  // The dialog records the acceptance before popping, so a tap that closes it
  // can never leave the app running without a stored record.
  return accepted == true || ConsentService.I.agreed;
}

class ConsentDialog extends StatefulWidget {
  const ConsentDialog({super.key});

  @override
  State<ConsentDialog> createState() => _ConsentDialogState();
}

class _ConsentDialogState extends State<ConsentDialog> {
  bool _checked = false;
  bool _busy = false;

  Future<void> _open(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('consent: could not open $url ($e)');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final service = ConsentService.I;
    final previous = service.acceptedAt;
    final reinstalled = service.reinstalled;
    return PopScope(
      canPop: false,
      child: AlertDialog(
        icon: Icon(Icons.privacy_tip_outlined, color: kConsentBlue, size: 34),
        title: Text(
          reinstalled ? 'Confirm your agreement' : 'Before you start',
          textAlign: TextAlign.center,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                reinstalled && previous != null
                    ? 'You agreed to the Privacy Policy and Terms of Service on '
                        'this phone on ${_longDate(previous)}. That record is '
                        'kept outside the app, so it survived the reinstall. '
                        'Please confirm again.'
                    : 'ReelTunes needs your agreement before it can set up and '
                        'play your audios. Your audio files stay on this '
                        'phone; the policy explains what the app itself keeps.',
                style: TextStyle(
                    fontSize: 13.5, height: 1.45, color: scheme.onSurface),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  TextButton(
                    onPressed: () => _open(privacyPolicyUrl),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                    ),
                    child: const Text('Privacy Policy'),
                  ),
                  Text('·',
                      style: TextStyle(color: scheme.onSurfaceVariant)),
                  TextButton(
                    onPressed: () => _open(termsOfServiceUrl),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                    ),
                    child: const Text('Terms of Service'),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: _busy ? null : () => setState(() => _checked = !_checked),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Checkbox(
                        value: _checked,
                        onChanged: _busy
                            ? null
                            : (v) => setState(() => _checked = v ?? false),
                        visualDensity: VisualDensity.compact,
                      ),
                      const SizedBox(width: 4),
                      const Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(top: 11),
                          child: Text(
                            'I agree to the Privacy Policy and Terms of Service.',
                            style: TextStyle(fontSize: 13, height: 1.35),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'You can read both again any time in Settings.',
                style: TextStyle(
                    fontSize: 11.5, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: (!_checked || _busy)
                ? null
                : () async {
                    setState(() => _busy = true);
                    // Record locally + in the durable file, then close.
                    await ConsentService.I.accept();
                    if (context.mounted) Navigator.pop(context, true);
                  },
            child: const Text('Agree and continue'),
          ),
        ],
      ),
    );
  }
}

String _longDate(DateTime d) {
  const months = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
  return '${d.day} ${months[d.month - 1]} ${d.year}';
}

/// Same accent as the rest of the app; kept local so this file does not pull in
/// the whole theme just for one colour.
const Color kConsentBlue = Color(0xFF2C8BFF);
