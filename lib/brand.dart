/// Which brand this build carries. Set at build time (brands/<flavor>.json via
/// --dart-define-from-file); the defaults are WOCOM HUB. Colours live in theme.dart, read from
/// the same file, so one code base ships as WOCOM HUB or as a client's own app.
class Brand {
  static const key = String.fromEnvironment('BRAND_KEY', defaultValue: 'wocom');
  static const name = String.fromEnvironment('BRAND_NAME', defaultValue: 'WOCOM HUB');
  /// The company that provides this app to its users (shown on the About screen).
  static const company = String.fromEnvironment('BRAND_COMPANY', defaultValue: 'WOCOM Limited');
  /// iPhone: Firebase (chat/missed-call alerts) is registered per bundle id.
  static const iosBundleId = String.fromEnvironment('IOS_BUNDLE_ID', defaultValue: 'com.wocom.app');
  static const firebaseIosAppId = String.fromEnvironment('FIREBASE_IOS_APP_ID', defaultValue: '1:935090189192:ios:183bf6ff7a2b4e1f47c03d');
  static const logo = String.fromEnvironment('BRAND_LOGO', defaultValue: 'assets/wocom-logo.png');
  static const logoWhite = String.fromEnvironment('BRAND_LOGO_WHITE', defaultValue: 'assets/wocom-logo-white.png');
  static const mark = String.fromEnvironment('BRAND_MARK', defaultValue: 'assets/wocom-mark.png');
  static const website = String.fromEnvironment('BRAND_WEBSITE', defaultValue: 'https://wocomja.com');
  static const websiteLabel = String.fromEnvironment('BRAND_WEBSITE_LABEL', defaultValue: 'wocomja.com');
  static const updateUrl = String.fromEnvironment('BRAND_UPDATE_URL', defaultValue: 'https://push.wocomenterprise.com/downloads/version.json');
  /// The native ring screen takes hex strings.
  static const darkHex = String.fromEnvironment('BRAND_DARK_HEX', defaultValue: '#3B0764');
  /// Google Play build: no self-updater (Play delivers updates), no battery-exemption request.
  static const playStore = bool.fromEnvironment('PLAY_STORE');
  static const isWocom = name == 'WOCOM HUB';
  /// WOCOM Employee App: staff build with the Tech Hub tab, talking straight to TechHub's public
  /// mobile API (never through the WOCOM Hub platform).
  static const isEmployee = key == 'employee';
  static const techhubUrl = String.fromEnvironment('BRAND_TECHHUB_URL', defaultValue: 'https://techhub.wocomenterprise.com/api/mobile/v1');
}
