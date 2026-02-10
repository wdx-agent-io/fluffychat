// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:file_picker/file_picker.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/localized_exception_extension.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:matrix/encryption.dart';
import 'package:matrix/matrix.dart';

import 'bootstrap_state.dart';

class BootstrapViewModel extends ValueNotifier<BootstrapViewModelState> {
  final Client client;

  final TextEditingController enterPassphraseOrRecovController =
      TextEditingController();
  final TextEditingController newPassphraseController = TextEditingController();
  final TextEditingController repeatPassphraseController =
      TextEditingController();

  BootstrapViewModel({required this.client})
    : super(BootstrapViewModelState()) {
    _init();
  }

  @override
  void dispose() {
    _cancelKeyVerification();
    super.dispose();
  }

  void _checkCanCreatePassphrase([_]) {
    final passphrase = newPassphraseController.text;
    value.newPassphraseEqualsRepeatPassphrase =
        passphrase.isNotEmpty && passphrase == repeatPassphraseController.text;
    value.newPassphraseLongEnough = passphrase.length >= 12;
    value.newPassphraseUpperAndLowerCase =
        passphrase.contains(RegExp(r'[A-Z]')) &&
        passphrase.contains(RegExp(r'[a-z]'));
    value.newPassphraseSpecialCharacters = passphrase.contains(
      RegExp(r'[!@#$%^&*(),.?":{}|<>]'),
    );
    value.newPassphraseNumbers = passphrase.contains(RegExp(r'\d'));
    notifyListeners();
  }

  void saveAsFile() => FilePicker.saveFile(
    fileName: 'FluffyChat-Recovery-Key-${DateTime.now().toIso8601String()}.txt',
    bytes: Uint8List.fromList(value.recoveryKey!.codeUnits),
  );

  Future<void> retryKeyVerification() async {
    value.noSecretsreceived = false;
    value.keyVerification = await client.userDeviceKeys[client.userID!]!
        .startVerification();
    value.keyVerification?.onUpdate = _onKeyVerificationUpdate;
    notifyListeners();
  }

  Future<void> _init() async {
    final state = value.cryptoIdentityState = await client
        .getCryptoIdentityState();
    newPassphraseController.addListener(_checkCanCreatePassphrase);
    repeatPassphraseController.addListener(_checkCanCreatePassphrase);
    if (state.initialized) {
      if (state.connected) return notifyListeners();

      await client.updateUserDeviceKeys();

      final devices = value.connectedDevices =
          client.userDeviceKeys[client.userID!]?.deviceKeys.values
              .where(
                (device) => device.hasValidSignatureChain(
                  verifiedByTheirMasterKey: true,
                ),
              )
              .toList() ??
          [];
      if (devices.isNotEmpty) {
        value.keyVerification = await client.userDeviceKeys[client.userID!]!
            .startVerification();
        value.keyVerification?.onUpdate = _onKeyVerificationUpdate;
      }
    }
    notifyListeners();
  }

  Future<void> _onKeyVerificationUpdate() async {
    if (value.keyVerification?.state == KeyVerificationState.done) {
      value.waitingForSecrets = true;
      value.noSecretsreceived = false;
      notifyListeners();
      value.cryptoIdentityState = await client.getCryptoIdentityState();
      var tries = 0;
      const max = 10;
      while (value.cryptoIdentityState?.connected != true) {
        Logs().d('Waiting for secrets... [$tries/$max]');
        if (tries >= max) return;
        await Future.delayed(const Duration(seconds: 1));
        value.cryptoIdentityState = await client.getCryptoIdentityState();
        tries++;
      }

      if (value.cryptoIdentityState?.connected != true) {
        value.waitingForSecrets = false;
        value.noSecretsreceived = true;
      }
    }
    notifyListeners();
  }

  Future<void> setOrSkipPassphrase(String? passphrase) async {
    value.isLoading = true;
    notifyListeners();

    value.recoveryKey = await client.initCryptoIdentity(passphrase: passphrase);
    notifyListeners();
  }

  void _cancelKeyVerification() {
    final keyVerification = value.keyVerification;
    if (keyVerification != null &&
        keyVerification.state != KeyVerificationState.done &&
        keyVerification.state != KeyVerificationState.error) {
      keyVerification.cancel();
    }
  }

  Future<void> unlock(BuildContext context) async {
    final key = enterPassphraseOrRecovController.text.trim();
    if (key.isEmpty) return;

    _cancelKeyVerification();

    value.unlockWithError = null;
    value.isLoading = true;
    notifyListeners();
    try {
      await client.restoreCryptoIdentity(key);
      value.isLoading = false;
      value.cryptoIdentityState = await client.getCryptoIdentityState();
      notifyListeners();
      return;
    } catch (e, s) {
      Logs().d('Unable to unlock', e, s);
      value.isLoading = false;
      value.unlockWithError = e;
      notifyListeners();
      return;
    }
  }

  void goToRoomsPageAfterSuccess(BuildContext context) {
    for (final room in client.rooms) {
      final lastEvent = room.lastEvent;
      if (lastEvent == null ||
          lastEvent.messageType != MessageTypes.BadEncrypted ||
          lastEvent.content['can_request_session'] != true) {
        continue;
      }
      final sessionId = lastEvent.content.tryGet<String>('session_id');
      final senderKey = lastEvent.content.tryGet<String>('sender_key');
      if (sessionId != null && senderKey != null) {
        client.encryption?.keyManager.maybeAutoRequest(
          room.id,
          sessionId,
          senderKey,
        );
      }
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: Duration(seconds: 3),
        showCloseIcon: true,
        backgroundColor: Colors.green.shade700,
        content: Text(
          L10n.of(context).allDone,
          style: TextStyle(color: Colors.white),
        ),
      ),
    );
    context.go('/rooms');
  }

  void setRecoveryKeyStored() {
    value.recoveryKeyStored = true;
    notifyListeners();
  }

  void toggleObscureText() {
    value.obscureText = !value.obscureText;
    notifyListeners();
  }

  void startResetAccount() {
    value.reset = true;
    notifyListeners();
  }

  Future<void> openRecoveryKeyFile(BuildContext context) async {
    final result = await FilePicker.pickFiles(
      allowMultiple: false,
      allowedExtensions: ['txt'],
      type: FileType.custom,
    );
    final file = result?.xFiles.singleOrNull;
    if (file == null) return;
    try {
      final key = await file.readAsString();
      enterPassphraseOrRecovController.text = key;
    } catch (e, s) {
      Logs().d('Unable to read recovery key file', e, s);
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toLocalizedString(context))));
      }
    }
    if (context.mounted) await unlock(context);
  }
}
