// Pure, side-effect-free helpers behind the content-addressed media cache
// (W02 / W09 -- see player-remediation-handover/02-detailed-audit.md).
// Kept dependency-free (no Flutter, no path_provider) specifically so this
// logic is unit-testable without a platform channel or a widget test
// harness -- mqtt_view_model.dart's _cacheFilePathFor is a thin wrapper
// that just joins cacheFilenameFor()'s result onto the actual cache
// directory.
import 'dart:convert';

import 'package:crypto/crypto.dart';

// A small set of Windows-reserved device names that can't be used as a
// filename regardless of extension (CON.mp4 is exactly as reserved as
// CON). Case-insensitive by construction -- callers must lowercase before
// checking membership.
const Set<String> kReservedWindowsNames = {
  'con', 'prn', 'aux', 'nul',
  'com1', 'com2', 'com3', 'com4', 'com5', 'com6', 'com7', 'com8', 'com9',
  'lpt1', 'lpt2', 'lpt3', 'lpt4', 'lpt5', 'lpt6', 'lpt7', 'lpt8', 'lpt9',
};

/// Extracts a safe file extension for [url]: only ever 1-8 lowercase ASCII
/// letters/digits, taken from the URL's last path segment when it looks
/// like a plausible extension, or a small mediaType-based fallback.
/// Never returns anything decoded from the URL verbatim -- a path
/// separator, ".." segment, or any other unexpected character hidden in
/// the source URL can never reach the returned value.
String safeExtensionFor(String url, {String? mediaType}) {
  String candidate = '';
  try {
    // Uri.parse + pathSegments (not a manual decode-then-split-on-'/')
    // deliberately: pathSegments is derived from the URI's *path*
    // component alone, before the query string is even considered, and
    // each segment comes back individually percent-decoded. Decoding the
    // whole URL first and then splitting on '/' -- the earlier approach --
    // is a real bug: a percent-encoded slash inside the *query string*
    // (e.g. "?token=a%2Fb", the exact W11 signed-query-param shape) decodes
    // to a literal '/' before the split ever runs, so `.split('/').last`
    // picks up a trailing piece of the decoded query value instead of the
    // actual last path segment.
    final pathSegments = Uri.parse(url).pathSegments;
    if (pathSegments.isNotEmpty) {
      final lastSegment = pathSegments.last;
      final dot = lastSegment.lastIndexOf('.');
      if (dot > 0 && dot < lastSegment.length - 1) {
        candidate = lastSegment.substring(dot + 1);
      }
    }
  } catch (_) {
    // Malformed URL / invalid percent-encoding -- fall through to the
    // mediaType-based fallback below instead of trusting the raw string.
  }
  if (RegExp(r'^[A-Za-z0-9]{1,8}$').hasMatch(candidate)) {
    return candidate.toLowerCase();
  }
  switch (mediaType) {
    case 'audio/mpeg':
      return 'mp3';
    case 'audio/mp4':
      return 'm4a';
    case 'video/mp4':
      return 'mp4';
    case 'image/jpeg':
    case 'image/png':
    case 'image/gif':
      return 'jpg';
    default:
      return url.contains('images') ? 'jpg' : 'bin';
  }
}

/// The safe, content-addressed cache *filename* (not a full path) for
/// [url] -- a hash of the whole URL plus a validated extension. Different
/// URLs that happen to share a final path segment can never collide
/// (W09), and the result can never contain a path separator or ".."
/// segment regardless of what the source URL contained (W02), since it's
/// built entirely from a hex digest and a regex-validated extension, never
/// from the URL's raw basename.
String cacheFilenameFor(String url, {String? mediaType}) {
  final digest = sha256.convert(utf8.encode(url)).toString();
  final ext = safeExtensionFor(url, mediaType: mediaType);
  var name = '$digest.$ext';
  if (kReservedWindowsNames.contains(digest.toLowerCase())) {
    name = '_$name'; // structurally unreachable (hex digest can never
    // equal a reserved name), kept as an explicit, checked invariant
    // rather than an assumption that stays true forever.
  }
  if (name.contains('/') || name.contains('\\') || name.contains('..')) {
    throw StateError('Unsafe cache filename computed for $url: $name');
  }
  return name;
}
