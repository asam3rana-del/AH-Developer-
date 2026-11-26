/// App / developer ki public maloomat — About screen, privacy link, store listing ek hi jagah se.
class AppInfo {
  AppInfo._();

  static const appName = 'Hanna POS';
  static const developer = 'Asam Hameed';
  static const business = 'Hanna Solutions';
  static const appId = 'com.hannasolutions.pos';
  static const version = '1.0';
  static const tagline = 'Premium Shop POS';
  static const address = 'Ibtisaam Traders, Bhikhi';
  static const supportEmail = 'hannasolutions1@gmail.com';
  static const supportPhone = '03006296815';
  static const supportWhatsAppIntl = '923006296815';

  /// Firebase Hosting (tools/deploy_privacy_site.sh).
  static const privacyPolicyUrl = 'https://my-grocery-pos-8a444.web.app/privacy.html';

  /// App ke andar update check (lib/services/app_update.dart, docs/UPDATES.md). Public GitHub repo `hanna-updates`
  /// ki `hanna-pos.json` (Hanna Installment ki `update.json` alag — dono ek repo mein). Khali = check band.
  static const updateUrl = 'https://raw.githubusercontent.com/asam3rana-del/hanna-updates/main/hanna-pos.json';

  /// CI: `--dart-define=APP_BUILD=<run number>`; local / purani build par khali.
  static const build = String.fromEnvironment('APP_BUILD');
}
