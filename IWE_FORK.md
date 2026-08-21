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
- `agent.instance_lock_port` holds a loopback TCP socket in an outer supervisor.
  The frozen attempt-fuse profile survives inner orchestrator/task-supervisor
  restarts. A second service on the same host fails before polling. Multi-host
  and high-availability operation are prohibited.
- A configured GitHub bot/App identity writes one canonical issue comment
  reservation before `Task.Supervisor.start_child/2` may run. The reservation
  is re-read and confirmed before launch.
- A pre-provisioned, dedicated mode-0700 host-state root outside all issue
  workspaces stores high-water and quarantine records. Symphony never creates
  or repairs this authority root. The root is resolved against the selected
  workflow, insecure directories are rejected without mode mutation, and
  original-path symlink components/files or any canonical overlap with the
  workspace root fail closed. High-water state can only veto
  a regressed GitHub history; it never authorizes a start by itself.
- Every pre-launch local-state transition syncs file contents, atomically
  renames, and syncs the parent directory before worker authorization. A sync
  failure consumes no worker start.
- Before handling exhaustion or any ledger failure, Symphony durably
  quarantines the issue. It then records one canonical evidence comment,
  removes only the configured activation label, and confirms absence. The
  quarantine survives restart and is never cleared automatically. Local and
  remote barriers are attempted independently; if neither is established, the
  outer singleton trips and polling remains suspended until an operator reset
  and full service restart.
- The fifth reservation still starts worker five. When that worker exits, the
  orchestrator deactivates the issue without attempting a sixth reservation.
- The complete enabled worker execution profile (budget, lock, tracker identity,
  repository, source revision, host-state root, workspace root/hooks, worker
  hosts, agent limits, Codex command, approvals, sandbox, timeouts, and tool
  boundary) is immutable for the singleton lifetime and is passed into the
  worker. Any workflow reload drift blocks before dispatch and requires a full
  reviewed service restart.
- GitHub's generic authenticated `github_api` dynamic tool is disabled for the
  ìwé workflow and unadvertised tool calls are rejected, so Codex and helper
  agents cannot use the tracker identity to forge or delete ledger evidence.
  The frozen no-tools binding and tracker-secret scrub set are passed into the
  worker and revalidated before workspace creation and after hooks, so a hot
  reload cannot give an already-reserved session new tracker authority.

## Trust and availability boundary

GitHub issue comments are not an atomic compare-and-swap primitive and GitHub
Issues-write permission can edit or delete comments. The pilot therefore
requires exactly one host-local Symphony service, a dedicated immutable GitHub
bot/App identity, and trusted repository administrators who do not rewrite the
ledger. Deletion or mutation detected by the hash chain or host high-water
state fails closed. A full host-state loss combined with authorized deletion of
the entire remote tail remains an administrative trust violation, not a
supported recovery path.

The normal suite retains upstream's 100% included-module threshold. The focused
fuse profile re-includes the ledger, orchestrator, AgentRunner, AppServer, and
dynamic-tool boundary with documented per-module line-coverage floors plus
supervised no-network rehearsal coverage.

The checked-in ìwé workflow keeps the ledger disabled until the real bot and
App IDs are provisioned in the separately reviewed live-pilot task. Disabled,
missing, stale, malformed, edited, conflicting, or exhausted evidence never
authorizes a worker or guarded-auto decision.

## Rollback

Remove the dispatch label, stop the service, archive the host-state directory,
restore the exact upstream commit and tree in the ìwé lock, reacquire a clean
checkout, and rerun the no-mutation pin and workflow validators. A quarantine
may be removed only by an explicit reviewed operator reset while the service is
stopped; it is never an automatic retry mechanism. No product-data migration is
needed.
