defmodule SymphonyElixir.AttemptFuseTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AttemptFuse

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

  defp write_attempt_workflow!(path, root, port) do
    File.write!(
      path,
      """
      ---
      tracker:
        kind: github
        provider:
          repo: "octo/repo"
          token: "test-token"
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
        root: "#{Path.join(root, "workspaces")}"
      agent:
        max_concurrent_agents: 1
        max_turns: 24
        max_retry_backoff_ms: 60000
        max_attempts: 5
        instance_lock_port: #{port}
      codex:
        command: "codex app-server"
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
