/// Single source of truth for where the Jarvis backend lives.
///
/// Every API route is derived from [jarvisApiBaseUrl]. The token endpoint, the
/// device-pairing routes and the challenge route therefore always share one
/// origin. There is no runtime entry for this: a URL is either the built-in
/// default or an explicit `--dart-define=JARVIS_API_BASE_URL=...` at build time.
/// No credential, access code or secret belongs in this configuration.
library;

/// Permanent production backend. Plain origin: the API paths are added below.
const String defaultJarvisApiBaseUrl = 'https://jarvis-ai-beta-teal.vercel.app';

/// Compile-time environment override. `String.fromEnvironment` is a const, so
/// it is resolved when the app is built and cannot be changed at runtime.
const String _jarvisApiBaseUrlOverride = String.fromEnvironment('JARVIS_API_BASE_URL');

const String _tokenPath = '/api/token';

/// Resolves [override] to a normalized `scheme://host[:port]` origin.
///
/// This is a pure function so tests can cover the default and the supported
/// override without recompiling the app. Blank, malformed or credential-bearing
/// values fall back to [defaultJarvisApiBaseUrl]. Any path supplied in the
/// override (for example a full `/api/token` URL) is dropped, so the derived
/// routes always come from one base.
Uri resolveJarvisApiBaseUrl(String? override) {
  final raw = (override == null || override.trim().isEmpty) ? defaultJarvisApiBaseUrl : override.trim();

  Uri? uri;
  try {
    uri = Uri.tryParse(raw);
  } on FormatException {
    uri = null;
  }

  if (uri == null ||
      !uri.hasScheme ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      (uri.scheme != 'https' && uri.scheme != 'http')) {
    return Uri.parse(defaultJarvisApiBaseUrl);
  }

  // Normalize to the origin only: no path, query, fragment or credentials.
  return Uri(scheme: uri.scheme, host: uri.host, port: uri.port, path: '');
}

/// The one backend origin used by every Jarvis API client.
Uri get jarvisApiBaseUrl => resolveJarvisApiBaseUrl(_jarvisApiBaseUrlOverride);

/// Origin as a string, for clients that accept a base URL (the device client).
String get jarvisApiBaseUrlString => jarvisApiBaseUrl.toString();

/// Token endpoint derived from the same base as the device routes.
Uri get jarvisTokenEndpoint => jarvisApiBaseUrl.resolve(_tokenPath);
