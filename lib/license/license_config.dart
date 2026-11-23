/// Hanna POS license ki settings (Hanna Solutions bharte hain). Private key YAHAN NAHI — sirf public.
class LicenseConfig {
  LicenseConfig._();

  /// Ed25519 PUBLIC key (base64). Is ka private jora sirf Hanna Solutions ke paas (GitHub secret
  /// HANNA_LICENSE_PRIVATE_KEY). Badla to purani saari keys bekaar ho jati hain.
  static const String publicKeyB64 = 'BSQq1I5yF34ua1m2luBy0TN6x+qH3rNO9S/1df5tn/s=';

  /// Naye install par muft din.
  static const int trialDays = 7;

  /// Expire hone se itne din pehle har screen ke upar yaad-dihani.
  static const int warnDays = 7;

  /// License screen par "WhatsApp par Device ID bhejein" — Hanna Solutions ka number, 92 se shuru,
  /// sirf digits (jaise '923001234567'). Khali => WhatsApp khud contact poochta hai.
  static const String vendorWhatsApp = '';

  static const String vendorName = 'Hanna Solutions';

  /// Online check (band / key bhejna) — Hanna Solutions ka APNA Firebase project (dukaan wala nahi).
  /// Firestore: `licenses/<DEVICEID bina dash>` doc, fields: `blocked` (bool), `key` (string, optional).
  /// Khali => online check band, sirf offline key.
  static const String firebaseProjectId = '';
  static const String firebaseApiKey = '';

  /// Internet mile to online check itne ghante baad dobara.
  static const int onlineCheckHours = 6;
}
