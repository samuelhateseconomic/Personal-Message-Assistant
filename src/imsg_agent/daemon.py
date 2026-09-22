"""Background Daemon — Long-running process for scheduled message delivery.

Runs the tick scheduler in a background thread and writes a heartbeat
to SQLite every 5 minutes for health monitoring.

Lifecycle:
1. Load config + open SQLite store
2. Start tick scheduler (60s polling loop)
3. Write heartbeat every 5 minutes
4. Handle SIGTERM/SIGINT for graceful shutdown
5. Clean up timers and flush logs on exit

Managed by launchd for auto-start on login and crash recovery.
Does NOT require Ollama — only the CLI chat mode needs the AI model.
"""
from __future__ import annotations

# TODO: Implement Daemon class
# TODO: Implement run(foreground=False) — main loop with signal handling
# TODO: Implement heartbeat writing (PID, pending count, next fire time)
# TODO: Implement _handle_signal() for graceful shutdown
