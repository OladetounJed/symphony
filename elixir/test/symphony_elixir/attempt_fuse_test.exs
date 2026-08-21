defmodule SymphonyElixir.AttemptFuseTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{AttemptFuse, Codex.DynamicTool}

  setup do
    previous_token = System.get_env("FROZEN_TRACKER_TOKEN")
    System.put_env("FROZEN_TRACKER_TOKEN", "test-tracker-token")
    on_exit(fn -> restore_env("FROZEN_TRACKER_TOKEN", previous_token) end)
    :ok
  end

  test "the complete enabled fuse profile is immutable" do
    root = Path.join(System.tmp_dir!(), "symphony-fuse-profile-#{System.unique_integer([:positive])}")
    workflow_path = Workflow.workflow_file_path()
    port = available_port()

    write_attempt_workflow!(workflow_path, root, port)
    assert :ok = WorkflowStore.force_reload()
    frozen = AttemptFuse.current_snapshot()
    assert :ok = AttemptFuse.validate_current(frozen)

    mutations = [
      %{frozen | max_attempts: 6},
      %{frozen | instance_lock_port: port + 1},
      %{frozen | workspace_root: frozen.workspace_root <> "-changed"},
      put_in(frozen, [:execution_settings, Access.key(:agent), Access.key(:max_turns)], 240),
      put_in(
        frozen,
        [:execution_settings, Access.key(:agent), Access.key(:max_concurrent_agents)],
        6
      ),
      put_in(
        frozen,
        [:execution_settings, Access.key(:codex), Access.key(:thread_sandbox)],
        "danger-full-access"
      ),
      put_in(
        frozen,
        [:execution_settings, Access.key(:codex), Access.key(:approval_policy)],
        "never"
      ),
      put_in(frozen, [:tracker_settings, Access.key(:provider), "repo"], "octo/other"),
      put_in(frozen, [:tracker_settings, Access.key(:provider), "token"], "other-token"),
      put_in(frozen, [:tracker_settings, Access.key(:provider), "agent_tools_enabled"], true),
      put_in(
        frozen,
        [:tracker_settings, Access.key(:provider), "attempt_ledger", "repository_id"],
        78
      ),
      put_in(
        frozen,
        [:tracker_settings, Access.key(:provider), "attempt_ledger", "actor_id"],
        89
      ),
      put_in(
        frozen,
        [:tracker_settings, Access.key(:provider), "attempt_ledger", "app_id"],
        100
      ),
      put_in(
        frozen,
        [:tracker_settings, Access.key(:provider), "attempt_ledger", "activation_label"],
        "pilot:other"
      ),
      put_in(
        frozen,
        [:tracker_settings, Access.key(:provider), "attempt_ledger", "source_revision"],
        String.duplicate("b", 40)
      ),
      put_in(
        frozen,
        [:tracker_settings, Access.key(:provider), "attempt_ledger", "high_water_root"],
        Path.join(root, "other-state")
      ),
      put_in(
        frozen,
        [:tracker_settings, Access.key(:provider), "attempt_ledger", "enabled"],
        false
      )
    ]

    assert Enum.all?(mutations, fn changed ->
             AttemptFuse.validate_current(changed) == {:error, :attempt_fuse_config_drift}
           end)

    File.rm_rf(root)
  end

  test "enabling a fuse requires a full runtime restart" do
    disabled = AttemptFuse.current_snapshot()
    refute disabled.enabled

    root = Path.join(System.tmp_dir!(), "symphony-fuse-enable-#{System.unique_integer([:positive])}")
    write_attempt_workflow!(Workflow.workflow_file_path(), root, available_port())
    assert :ok = WorkflowStore.force_reload()

    assert {:error, :attempt_fuse_config_drift} = AttemptFuse.validate_current(disabled)
    File.rm_rf(root)
  end

  test "a disabled fuse binds worker tools from the current reloaded tracker" do
    disabled = AttemptFuse.current_snapshot()
    refute disabled.enabled

    assert Orchestrator.worker_tool_binding_for_test(disabled).tool_specs != []

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    assert :ok = WorkflowStore.force_reload()

    assert Orchestrator.worker_tool_binding_for_test(disabled).tool_specs == []
  end

  test "relative workspace roots are frozen against the selected workflow directory" do
    first_root =
      Path.join(System.tmp_dir!(), "symphony-fuse-relative-a-#{System.unique_integer([:positive])}")

    second_root =
      Path.join(System.tmp_dir!(), "symphony-fuse-relative-b-#{System.unique_integer([:positive])}")

    first_workflow = Path.join([first_root, "config", "WORKFLOW.md"])
    second_workflow = Path.join([second_root, "config", "WORKFLOW.md"])
    File.mkdir_p!(Path.dirname(first_workflow))
    File.mkdir_p!(Path.dirname(second_workflow))

    write_attempt_workflow!(first_workflow, first_root, available_port(), "../issue-workspaces")
    Workflow.set_workflow_file_path(first_workflow)
    assert :ok = WorkflowStore.force_reload()

    frozen = AttemptFuse.current_snapshot()
    assert frozen.workspace_root == Path.join(first_root, "issue-workspaces")
    assert frozen.workspace_root == Config.local_workspace_root()

    write_attempt_workflow!(second_workflow, second_root, frozen.instance_lock_port, "../issue-workspaces")
    Workflow.set_workflow_file_path(second_workflow)
    assert :ok = WorkflowStore.force_reload()

    assert {:error, :attempt_fuse_config_drift} = AttemptFuse.validate_current(frozen)

    File.rm_rf(first_root)
    File.rm_rf(second_root)
  end

  test "a frozen disabled tool binding survives hook-time workflow drift and blocks session start" do
    root = Path.join(System.tmp_dir!(), "symphony-fuse-tool-boundary-#{System.unique_integer([:positive])}")
    workflow_path = Workflow.workflow_file_path()
    write_attempt_workflow!(workflow_path, root, available_port())
    assert :ok = WorkflowStore.force_reload()

    frozen = AttemptFuse.current_snapshot()
    binding = Tracker.bind_agent_tools(frozen.tracker_settings)

    assert binding.tool_specs == []
    assert "FROZEN_TRACKER_TOKEN" in binding.secret_environment_names

    assert %{"success" => false} = DynamicTool.execute("github_api", %{}, binding)

    assert {:error, :attempt_fuse_tool_binding_missing} =
             AppServer.start_session(Path.join(frozen.workspace_root, "GH-42"),
               attempt_fuse: frozen
             )

    changed =
      workflow_path
      |> File.read!()
      |> String.replace(String.duplicate("a", 40), String.duplicate("b", 40))

    File.write!(workflow_path, changed)
    assert :ok = WorkflowStore.force_reload()

    assert {:error, :attempt_fuse_config_drift} =
             AppServer.start_session(
               Path.join(frozen.workspace_root, "GH-42"),
               attempt_fuse: frozen,
               dynamic_tool_binding: binding
             )

    File.rm_rf(root)
  end

  test "production Workspace and App Server boundaries retain the frozen root across a broader live reload" do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-fuse-root-validation-#{System.unique_integer([:positive])}"
      )

    frozen_root = Path.join(root, "frozen-workspaces")
    outside = Path.join(root, "outside")
    identifier = "GH-42"
    symlink_workspace = Path.join(frozen_root, Workspace.workspace_key(identifier))
    workflow_path = Workflow.workflow_file_path()
    port = available_port()

    File.mkdir_p!(frozen_root)
    File.mkdir_p!(outside)
    File.ln_s!(outside, symlink_workspace)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :workspace_boundary_observer)
      Application.delete_env(:symphony_elixir, :app_server_workspace_boundary_observer)
      File.rm_rf(root)
    end)

    write_attempt_workflow!(workflow_path, root, port, frozen_root)
    assert :ok = WorkflowStore.force_reload()
    frozen = AttemptFuse.current_snapshot()
    binding = Tracker.bind_agent_tools(frozen.tracker_settings)

    Application.put_env(
      :symphony_elixir,
      :workspace_boundary_observer,
      fn
        :before_path, _safe_id, nil ->
          Application.delete_env(:symphony_elixir, :workspace_boundary_observer)
          write_attempt_workflow!(workflow_path, root, port, root)
          WorkflowStore.force_reload()

        _stage, _value, _worker_host ->
          :ok
      end
    )

    assert {:error, {:workspace_outside_root, _canonical_workspace, _canonical_root}} =
             Workspace.create_for_issue(identifier, nil, frozen)

    write_attempt_workflow!(workflow_path, root, port, frozen_root)
    assert :ok = WorkflowStore.force_reload()
    assert :ok = AttemptFuse.validate_current(frozen)

    Application.put_env(
      :symphony_elixir,
      :app_server_workspace_boundary_observer,
      fn ^symlink_workspace, nil ->
        Application.delete_env(:symphony_elixir, :app_server_workspace_boundary_observer)
        write_attempt_workflow!(workflow_path, root, port, root)
        WorkflowStore.force_reload()
      end
    )

    assert {:error, {:invalid_workspace_cwd, :symlink_escape, ^symlink_workspace, _canonical_root}} =
             AppServer.start_session(symlink_workspace,
               attempt_fuse: frozen,
               dynamic_tool_binding: binding
             )
  end

  test "post-create fuse drift removes a new local workspace so after_create retries" do
    root = Path.join(System.tmp_dir!(), "symphony-fuse-local-cleanup-#{System.unique_integer([:positive])}")
    workflow_path = Workflow.workflow_file_path()
    port = available_port()
    hook = "printf ready > READY"
    identifier = "GH-LOCAL-CLEANUP"

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :workspace_boundary_observer)
      File.rm_rf(root)
    end)

    write_attempt_workflow!(workflow_path, root, port, nil, hook_after_create: hook)
    assert :ok = WorkflowStore.force_reload()
    frozen = AttemptFuse.current_snapshot()

    {:ok, workspace} =
      SymphonyElixir.PathSafety.canonicalize(Path.join(frozen.workspace_root, Workspace.workspace_key(identifier)))

    Application.put_env(
      :symphony_elixir,
      :workspace_boundary_observer,
      fn
        :prepared, _prepared_workspace, nil ->
          Application.delete_env(:symphony_elixir, :workspace_boundary_observer)

          write_attempt_workflow!(workflow_path, root, port, nil,
            hook_after_create: hook,
            source_revision: String.duplicate("b", 40)
          )

          WorkflowStore.force_reload()

        _stage, _value, _worker_host ->
          :ok
      end
    )

    assert {:error, :attempt_fuse_config_drift} =
             Workspace.create_for_issue(identifier, nil, frozen)

    refute File.exists?(workspace)

    write_attempt_workflow!(workflow_path, root, port, nil, hook_after_create: hook)
    assert :ok = WorkflowStore.force_reload()
    assert {:ok, ^workspace} = Workspace.create_for_issue(identifier, nil, frozen)
    assert File.read!(Path.join(workspace, "READY")) == "ready"
  end

  test "post-create fuse drift removes a new remote workspace so after_create retries" do
    root = Path.join(System.tmp_dir!(), "symphony-fuse-remote-cleanup-#{System.unique_integer([:positive])}")
    workflow_path = Workflow.workflow_file_path()
    port = available_port()
    trace = Path.join(root, "ssh.trace")
    fake_ssh = Path.join(root, "ssh")
    remote_root = "/remote/workspaces"
    remote_workspace = Path.join(remote_root, "GH-REMOTE-CLEANUP")
    hook = "echo remote-after-create"
    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :workspace_boundary_observer)
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
      File.rm_rf(root)
    end)

    File.mkdir_p!(root)
    System.put_env("SYMP_TEST_SSH_TRACE", trace)
    System.put_env("PATH", root <> ":" <> (previous_path || ""))

    File.write!(fake_ssh, """
    #!/bin/sh
    printf 'ARGV:%s\\n' "$*" >> "$SYMP_TEST_SSH_TRACE"
    case "$*" in
      *"__SYMPHONY_WORKSPACE__"*)
        printf '%s\\t%s\\t%s\\t%s\\n' '__SYMPHONY_WORKSPACE__' '1' '#{remote_root}' '#{remote_workspace}'
        ;;
      *"__SYMPHONY_REMOTE_WORKSPACE_VALID__"*)
        printf '%s\\t%s\\t%s\\n' '__SYMPHONY_REMOTE_WORKSPACE_VALID__' '#{remote_root}' '#{remote_workspace}'
        ;;
    esac
    exit 0
    """)

    File.chmod!(fake_ssh, 0o755)

    write_attempt_workflow!(workflow_path, root, port, remote_root, hook_after_create: hook)

    assert :ok = WorkflowStore.force_reload()
    frozen = AttemptFuse.current_snapshot()

    Application.put_env(
      :symphony_elixir,
      :workspace_boundary_observer,
      fn
        :prepared, ^remote_workspace, "worker-01" ->
          Application.delete_env(:symphony_elixir, :workspace_boundary_observer)

          write_attempt_workflow!(workflow_path, root, port, remote_root,
            hook_after_create: hook,
            source_revision: String.duplicate("b", 40)
          )

          WorkflowStore.force_reload()

        _stage, _value, _worker_host ->
          :ok
      end
    )

    assert {:error, :attempt_fuse_config_drift} =
             Workspace.create_for_issue("GH-REMOTE-CLEANUP", "worker-01", frozen)

    first_trace = File.read!(trace)
    assert first_trace =~ "rm -rf"
    refute first_trace =~ hook

    write_attempt_workflow!(workflow_path, root, port, remote_root, hook_after_create: hook)

    assert :ok = WorkflowStore.force_reload()

    assert {:ok, ^remote_workspace} =
             Workspace.create_for_issue("GH-REMOTE-CLEANUP", "worker-01", frozen)

    assert File.read!(trace) =~ hook
  end

  test "remote workspace preparation rejects a canonical symlink escape" do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-fuse-remote-symlink-#{System.unique_integer([:positive])}"
      )

    workflow_path = Workflow.workflow_file_path()
    port = available_port()
    trace = Path.join(root, "ssh.trace")
    fake_ssh = Path.join(root, "ssh")
    remote_root = "/remote/workspaces"
    remote_workspace = Path.join(remote_root, "GH-REMOTE-SYMLINK")
    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
      File.rm_rf(root)
    end)

    File.mkdir_p!(root)
    System.put_env("SYMP_TEST_SSH_TRACE", trace)
    System.put_env("PATH", root <> ":" <> (previous_path || ""))

    File.write!(fake_ssh, """
    #!/bin/sh
    printf 'ARGV:%s\\n' "$*" >> "$SYMP_TEST_SSH_TRACE"
    case "$*" in
      *"__SYMPHONY_WORKSPACE__"*)
        printf '%s\\t%s\\t%s\\t%s\\n' '__SYMPHONY_WORKSPACE__' '0' '#{remote_root}' '/home/worker'
        ;;
    esac
    exit 0
    """)

    File.chmod!(fake_ssh, 0o755)
    write_attempt_workflow!(workflow_path, root, port, remote_root)
    assert :ok = WorkflowStore.force_reload()
    frozen = AttemptFuse.current_snapshot()

    assert {:error, {:remote_workspace_validation_failed, :outside_root, ^remote_root, "/home/worker"}} =
             Workspace.create_for_issue("GH-REMOTE-SYMLINK", "worker-01", frozen)

    trace_output = File.read!(trace)
    assert trace_output =~ remote_workspace
    refute trace_output =~ "codex app-server"
  end

  test "post-hook remote workspace retarget fails closed and recorded cleanup never removes it" do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-fuse-remote-retarget-#{System.unique_integer([:positive])}"
      )

    workflow_path = Workflow.workflow_file_path()
    port = available_port()
    trace = Path.join(root, "ssh.trace")
    fake_ssh = Path.join(root, "ssh")
    remote_root = "/remote/workspaces"
    remote_workspace = Path.join(remote_root, "GH-REMOTE-RETARGET")
    hook = "echo after-create-retarget"
    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
      File.rm_rf(root)
    end)

    File.mkdir_p!(root)
    System.put_env("SYMP_TEST_SSH_TRACE", trace)
    System.put_env("PATH", root <> ":" <> (previous_path || ""))

    File.write!(fake_ssh, """
    #!/bin/sh
    printf 'ARGV:%s\\n' "$*" >> "$SYMP_TEST_SSH_TRACE"
    case "$*" in
      *"__SYMPHONY_WORKSPACE__"*)
        printf '%s\\t%s\\t%s\\t%s\\n' '__SYMPHONY_WORKSPACE__' '1' '#{remote_root}' '#{remote_workspace}'
        ;;
      *"__SYMPHONY_REMOTE_WORKSPACE_VALID__"*)
        printf '%s\\t%s\\t%s\\n' '__SYMPHONY_REMOTE_WORKSPACE_VALID__' '#{remote_root}' '/home/worker'
        ;;
    esac
    exit 0
    """)

    File.chmod!(fake_ssh, 0o755)
    write_attempt_workflow!(workflow_path, root, port, remote_root, hook_after_create: hook)
    assert :ok = WorkflowStore.force_reload()
    frozen = AttemptFuse.current_snapshot()

    assert {:error, {:remote_workspace_validation_failed, :outside_root, ^remote_root, "/home/worker"}} =
             Workspace.create_for_issue("GH-REMOTE-RETARGET", "worker-01", frozen)

    trace_after_create = File.read!(trace)
    assert trace_after_create =~ hook

    assert {:error, {:remote_workspace_validation_failed, :outside_root, ^remote_root, "/home/worker"}, ""} =
             Workspace.remove_recorded(
               remote_workspace,
               "worker-01",
               remote_root,
               frozen.execution_settings.hooks
             )

    cleanup_trace = File.read!(trace) |> String.replace(trace_after_create, "")
    refute cleanup_trace =~ "rm -rf"
  end

  test "recorded remote cleanup rechecks containment in the deletion shell" do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-fuse-remote-delete-retarget-#{System.unique_integer([:positive])}"
      )

    workflow_path = Workflow.workflow_file_path()
    port = available_port()
    remote_root = Path.join(root, "remote-workspaces")
    remote_workspace = Path.join(remote_root, "GH-REMOTE-DELETE")
    outside = Path.join(root, "outside")
    outside_marker = Path.join(outside, "keep")
    fake_ssh = Path.join(root, "ssh")
    validation_count = Path.join(root, "validation-count")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(root)
    end)

    File.mkdir_p!(remote_workspace)
    File.mkdir_p!(outside)
    File.write!(outside_marker, "keep")
    System.put_env("PATH", root <> ":" <> (previous_path || ""))

    File.write!(fake_ssh, """
    #!/bin/sh
    last=''
    for argument in "$@"; do last="$argument"; done
    case "$last" in
      *"__SYMPHONY_REMOTE_WORKSPACE_VALID__"*)
        eval "$last"
        status=$?
        count=0
        if [ -f '#{validation_count}' ]; then count=$(cat '#{validation_count}'); fi
        count=$((count + 1))
        printf '%s' "$count" > '#{validation_count}'
        if [ "$count" -eq 2 ]; then
          rm -rf '#{remote_workspace}'
          ln -s '#{outside}' '#{remote_workspace}'
        fi
        exit "$status"
        ;;
      *)
        eval "$last"
        ;;
    esac
    """)

    File.chmod!(fake_ssh, 0o755)
    write_attempt_workflow!(workflow_path, root, port, remote_root)
    assert :ok = WorkflowStore.force_reload()
    hooks = Config.settings!().hooks

    assert {:error, {:workspace_remove_failed, "worker-01", 74, _output}, ""} =
             Workspace.remove_recorded(remote_workspace, "worker-01", remote_root, hooks)

    assert File.read!(outside_marker) == "keep"
    assert {:ok, %File.Stat{type: :symlink}} = File.lstat(remote_workspace)
  end

  defp write_attempt_workflow!(path, root, port, workspace_root \\ nil, opts \\ []) do
    workspace_root = workspace_root || Path.join(root, "workspaces")
    source_revision = Keyword.get(opts, :source_revision, String.duplicate("a", 40))
    after_create = Jason.encode!(Keyword.get(opts, :hook_after_create))

    File.write!(
      path,
      """
      ---
      tracker:
        kind: github
        provider:
          repo: "octo/repo"
          token: "$FROZEN_TRACKER_TOKEN"
          agent_tools_enabled: false
          attempt_ledger:
            enabled: true
            repository_id: 77
            actor_id: 88
            app_id: 99
            activation_label: "pilot:symphony"
            source_revision: "#{source_revision}"
            high_water_root: "#{Path.join(root, "host-state")}"
        required_labels: ["agent-ready", "pilot:symphony"]
        active_states: ["open"]
        terminal_states: ["closed"]
      polling:
        interval_ms: 10000
      workspace:
        root: "#{workspace_root}"
      hooks:
        after_create: #{after_create}
        timeout_ms: 60000
      agent:
        max_concurrent_agents: 1
        max_turns: 24
        max_retry_backoff_ms: 60000
        max_attempts: 5
        instance_lock_port: #{port}
      codex:
        command: "codex app-server"
        approval_policy:
          reject:
            sandbox_approval: true
            rules: true
            mcp_elicitations: true
        thread_sandbox: "workspace-write"
      ---

      Immutable fuse profile test.
      """
    )
  end

  defp available_port do
    {:ok, socket} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: false])

    {:ok, {_address, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
