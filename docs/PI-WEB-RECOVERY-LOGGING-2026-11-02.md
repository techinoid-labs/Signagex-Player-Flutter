# Pi web recovery and production logging — 2026-11-02

## Changes

- CEF 0.2.2's JavaScript evaluation callback did not complete on this Pi's Chrome
  runtime. The old five-second page probe timed out repeatedly and could not
  establish page health.
- Patch the pinned dependency at Linux CMake configuration time to forward native
  main-frame load errors and HTTP failures through its existing load-event bridge.
  Cancelled navigation, child frames and status-zero error documents cannot mark
  the main document failed/recovered. A changed upstream handler fails the build.
- LinuxWebView consumes those native events and retries failed main pages using
  the existing bounded backoff. Healthy pages are not evaluated or refreshed.
- MQTT protocol tracing is disabled; inbound/outbound payload dumps, stored
  campaign payload dumps and encrypted remote-frame echoes are excluded. Command
  errors, connection transitions and recovery events remain visible.
- Routine campaign/restriction/layout traces are debug-only to prevent rebuilds
  during remote view from flooding production logs.

## Evidence

- Source commits: 46ad4fc, 598b443, 93f32e0.
- Initial hardware candidate: arm64-v21, source 598b443,
  CI run 41538218294; full native compilation, Flutter checks and 17 Python tests
  passed (one Python test skipped).
- Package checksum on both Mac and Pi:
  `f918325fb39f783d2b2846f1b583b94480dc26a54c15dc5e722e82dae454b930`.
- Pi booted v21 with zero automatic service restarts. Probe timeout, MQTT protocol
  trace and encrypted frame-payload log counts were zero in inspected windows.
- A temporary HTTPS rejection rule scoped to the player user triggered a native
  main-page failure. The rule was removed in a finally block; MQTT reconnected,
  and the departures widget was visually confirmed in CMS live remote view.
- The assigned 20-second campaign rotates browser instances, so this test did not
  observe the same-instance `page recovered` log. It establishes native failure
  detection and restored playback, not a standalone same-instance recovery test.
- Original GNOME proxy settings were restored after a separate proxy experiment;
  that experiment did not trigger a main-frame failure.
- First normal-playback comparison: 169,295 to 40,820 journal bytes per minute.
  Remote-view testing then exposed remaining rendering traces (126,015 bytes/min),
  addressed by the final debug-only trace change.

Final candidate: arm64-v23, source 93f32e0, CI run 41541716925.
Installed on the Pi as package `0.arm64-v23`; health reports `arm64-v23`,
service active, PID 31008, zero automatic restarts. Package checksum matched on
Mac and Pi:
`2bf7745a297d9c9d6627c5fbb31523fd4d4f6ce72107517a6241206e7d65bf7f`.

Final sampled 60-second journal: 90 lines / 6,704 bytes, zero probe timeouts,
zero MQTT protocol traces, zero encrypted frame dumps, and zero campaign-check
traces. This is about 96% fewer bytes than the initial normal-playback sample;
these are sampled operating windows, not a controlled throughput benchmark.

V21 live remote view visually showed the departures widget after the outage.
V23 changes only routine trace guards relative to that tested candidate. The Mac
was locked for the final V23 visual check; service, browser initialization,
MQTT subscription and health were verified through SSH instead.

The temporary HTTPS rejection rule was removed, and GNOME proxy mode is back to
its original `none`. Automatic-update preference was not changed.

Final production promotion workflow: 41544151406 succeeded. The production
ARM64 feed reports `0.arm64-v23` with the exact package checksum above.
