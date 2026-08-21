# ìwé downstream safety delta

This fork is maintained for the ìwé autonomous-engineering pilot. It is based on
OpenAI Symphony commit `8001b52e3062495a16e520e4ceaf8f9de868c4d0` and keeps
the upstream scheduler as the only dispatch and retry authority.

The downstream delta adds a fail-closed total worker-start budget for the
GitHub Issues adapter:

- `agent.max_attempts` counts top-level worker process starts. The initial
  start, normal continuations, failure retries, stall recovery, and spawn
  failures all consume the same budget. Codex turns and helper subagents within
  one worker do not consume another top-level attempt.
- `agent.instance_lock_port` holds a loopback TCP socket for the full lifetime
  of the one-for-all agent runtime. A second service on the same host fails
  before polling. Multi-host and high-availability operation are prohibited.
- A configured GitHub bot/App identity writes one canonical issue comment
  reservation before `Task.Supervisor.start_child/2` may run. The reservation
  is re-read and confirmed before launch.
- A host-local high-water file outside all issue workspaces can only veto a
  regressed GitHub history. It never authorizes a start by itself.
- At exhaustion or ledger failure, the issue is blocked locally and Symphony
  removes only the configured activation label after attempting to leave
  machine-readable evidence.
- GitHub's generic authenticated `github_api` dynamic tool is disabled for the
  ìwé workflow and unadvertised tool calls are rejected, so Codex and helper
  agents cannot use the tracker identity to forge or delete ledger evidence.

## Trust and availability boundary

GitHub issue comments are not an atomic compare-and-swap primitive and GitHub
Issues-write permission can edit or delete comments. The pilot therefore
requires exactly one host-local Symphony service, a dedicated immutable GitHub
bot/App identity, and trusted repository administrators who do not rewrite the
ledger. Deletion or mutation detected by the hash chain or host high-water
state fails closed. A full host-state loss combined with authorized deletion of
the entire remote tail remains an administrative trust violation, not a
supported recovery path.

The checked-in ìwé workflow keeps the ledger disabled until the real bot and
App IDs are provisioned in the separately reviewed live-pilot task. Disabled,
missing, stale, malformed, edited, conflicting, or exhausted evidence never
authorizes a worker or guarded-auto decision.

## Rollback

Remove the dispatch label, stop the service, restore the exact upstream commit
and tree in the ìwé lock, reacquire a clean checkout, and rerun the no-mutation
pin and workflow validators. No migration or product data rollback is needed.
