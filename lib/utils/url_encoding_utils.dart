// W11 (see player-remediation-handover/02-detailed-audit.md): encodes only
// whitespace characters in a URL, leaving every other character -- crucially,
// any already-valid "%XX" percent-escape -- untouched. Uri.encodeFull on a
// whole URL re-encodes existing escapes too (confirmed: turns
// "video%20one.mp4?token=a%2Fb" into "video%2520one.mp4?token=a%252Fb"),
// silently corrupting a signed query parameter or any other pre-encoded
// component. The actual real-world problem this fixes is narrower: a
// literal unencoded space in a CMS asset path, invalid in an HTTP request
// line.
String encodeUrlWhitespaceOnly(String url) {
  return url.replaceAllMapped(
    RegExp(r'[ \t\r\n]'),
    (m) => Uri.encodeComponent(m[0]!),
  );
}
