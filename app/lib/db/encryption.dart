import 'dart:io';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:sqlcipher_flutter_libs/sqlcipher_flutter_libs.dart';

/// SQLCipher support: the local SQLite file is encrypted at rest with a
/// random 256-bit key held in the device keystore/keychain
/// (flutter_secure_storage). Existing plaintext databases are migrated
/// in-place on first launch after this upgrade.
const _passphraseKey = 'db_passphrase_v1';

final FlutterSecureStorage _storage = const FlutterSecureStorage(
  aOptions: AndroidOptions(encryptedSharedPreferences: true),
);

/// Loads the SQLCipher native library (Android/iOS only; desktop builds of
/// sqlcipher aren't wired — those platforms keep plain sqlite for now).
Future<void> loadSqlCipherLibrary() async {
  if (Platform.isAndroid) {
    open.overrideFor(OperatingSystem.android, openCipherOnAndroid);
  }
  // iOS: sqlcipher_flutter_libs ships the framework automatically.
}

/// Returns the database passphrase, creating it on first use.
Future<String> getOrCreateDbPassphrase() async {
  var pass = await _storage.read(key: _passphraseKey);
  if (pass != null && pass.isNotEmpty) return pass;
  final rnd = Random.secure();
    pass = List.generate(32, (_) => rnd.nextInt(256))
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  await _storage.write(key: _passphraseKey, value: pass);
  return pass;
}

/// Detects an unencrypted legacy database and re-writes it as an encrypted
/// copy using SQLCipher's sqlcipher_export. Safe to call on every startup:
/// already-encrypted files are left untouched.
Future<void> migratePlaintextDatabaseIfNeeded(
    File dbFile, String passphrase) async {
  if (!await dbFile.exists()) return;

  final raf = await dbFile.open(mode: FileMode.read);
  final header = await raf.read(16);
  await raf.close();

  // Plain SQLite files begin with "SQLite format 3\0"; SQLCipher files start
  // with random bytes, so anything else is already encrypted.
  const magic = 'SQLite format 3\u0000';
  if (String.fromCharCodes(header) != magic) return;

  final tmpPath = '${dbFile.path}.enc';
  final tmp = File(tmpPath);
  if (await tmp.exists()) await tmp.delete();

  final raw = sqlite3.open(dbFile.path);
  try {
    raw.execute("ATTACH DATABASE '$tmpPath' AS enc KEY '$passphrase'");
    raw.execute("SELECT sqlcipher_export('enc')");
    raw.execute('DETACH DATABASE enc');
  } finally {
    raw.dispose();
  }

  // Swap files only if the encrypted copy looks valid.
  final encRaf = await tmp.open(mode: FileMode.read);
  final encHeader = await encRaf.read(16);
  await encRaf.close();
  if (String.fromCharCodes(encHeader) == magic) {
    throw StateError('encryption migration produced a plaintext file');
  }
  await dbFile.delete();
  await tmp.rename(dbFile.path);
}
