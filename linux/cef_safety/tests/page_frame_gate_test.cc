#include "../page_frame_gate.h"
#include <cassert>
int main() {
  signagex::PageFrameGate gate;
  assert(!gate.Ready(1)); // No first-page white paint.
  gate.Begin(1);
  gate.Loaded(1, true);
  assert(gate.Ready(1));
  gate.Begin(1);
  assert(!gate.Ready(1)); // Preserve previous texture through navigation.
  gate.Loaded(1, false);
  assert(!gate.Ready(1)); // Failed documents never replace usable pixels.
  gate.Loaded(2, true);
  assert(gate.Ready(2) && !gate.Ready(1));
  gate.Loaded(1, true);
  assert(gate.Ready(1)); // Recovery resumes normal painting.
  gate.Close(1);
  assert(!gate.Ready(1) && gate.Ready(2));
}
