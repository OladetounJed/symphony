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

  defp write_attempt_workflow!(path, root, port, workspace_root \\ nil) do
    workspace_root = workspace_root || Path.join(root, "workspaces")

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
            source_revision: "#{String.duplicate("a", 40)}"
            high_water_root: "#{Path.join(root, "host-state")}"
        required_labels: ["agent-ready", "pilot:symphony"]
        active_states: ["open"]
        terminal_states: ["closed"]
      polling:
        interval_ms: 10000
      workspace:
        root: "#{workspace_root}"
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
