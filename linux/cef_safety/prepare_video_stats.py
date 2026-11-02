#!/usr/bin/env python3
"""Opt-in frame timing for the pinned fvp plugin, without screen readbacks."""
import hashlib
from pathlib import Path
import sys

source, output = map(Path, sys.argv[1:])
data = (source / "fvp_plugin.cc").read_bytes()
if hashlib.sha256(data).hexdigest() != "30a83d8af0046f7ec9dcefffedfb5d66c51a0ffabe143045dfa675edb6cf7e23":
    raise SystemExit("Review video timing overrides for this fvp version")
text = data.decode()

def replace_once(old, new):
    global text
    if text.count(old) != 1:
        raise SystemExit(f"Video timing patch anchor changed: {old[:70]}")
    text = text.replace(old, new, 1)

replace_once("  CleanupTask* cleanup;", """  CleanupTask* cleanup;
  gboolean timing_enabled;
  gint64 timing_start, previous_render, worst_gap;
  guint frames, late_frames;
  double previous_pts;""")
replace_once("  self->cleanup = nullptr;", """  self->cleanup = nullptr;
  self->timing_enabled = g_strcmp0(g_getenv("SIGNAGEX_VIDEO_STATS"), "1") == 0;
  self->timing_start = self->previous_render = self->worst_gap = 0;
  self->frames = self->late_frames = 0;
  self->previous_pts = -1.0;""")
replace_once("  self->player->renderVideo();", """  const double pts = self->player->renderVideo();
  if (self->timing_enabled && pts >= 0 && pts != self->previous_pts) {
    const gint64 now = g_get_monotonic_time();
    if (self->timing_start == 0) self->timing_start = now;
    if (self->previous_render != 0) {
      const gint64 gap = now - self->previous_render;
      self->worst_gap = std::max(self->worst_gap, gap);
      if (gap > 50000) ++self->late_frames;
    }
    self->previous_render = now;
    self->previous_pts = pts;
    ++self->frames;
    const double seconds = (now - self->timing_start) / 1000000.0;
    if (seconds >= 3.0) {
      g_printerr("[VIDEO_STATS] fps=%.2f max_gap_ms=%.2f gaps_over_50ms=%u pts=%.3f\\n",
          self->frames / seconds, self->worst_gap / 1000.0, self->late_frames, pts);
      self->timing_start = now;
      self->frames = self->late_frames = 0;
      self->worst_gap = 0;
    }
  }""")
output.mkdir(parents=True, exist_ok=True)
(output / "fvp_plugin.cc").write_text(text)
