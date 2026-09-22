# Codex Plugin 0.2.1

This compatible patch fixes two managed-runtime lifecycle cases:

- Cancelling an in-flight App Server request retires its owned generation before
  returning cancellation. A subsequent request can start a fresh generation.
- Shutdown uses an independent grace-period timer, so process-launch and polling
  overhead cannot accumulate into an unbounded cleanup wait. Early exits reap
  the timer and supervisor promptly.

The manifest is the plugin version authority. Generated runtime metadata,
packaging checks and the version policy reject drift. The SDK remains on the
existing public 0.2.2 dependency; no new SDK release is required for these fixes.

Regression coverage includes cancellation ownership, parent death, long-grace
early exit, trailing oversized frames, reconnect, and isolated standard-MCP
native approval/turn/release flows. Final host compatibility is recorded against
the exact candidate archive during coordinated Computer MCP acceptance.
