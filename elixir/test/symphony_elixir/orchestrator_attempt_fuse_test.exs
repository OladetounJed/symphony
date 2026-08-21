defmodule SymphonyElixir.OrchestratorAttemptFuseTest do
  use SymphonyElixir.TestSupport

  defmodule FakeGitHubClient do
    def fetch_issues_by_states(states) do
      issue = Application.fetch_env!(:symphony_elixir, :attempt_fuse_test_issue)

      if "open" in Enum.map(states, &String.downcase/1) do
        {:ok, [issue]}
      else
        {:ok, []}
      end
    end

    def fetch_issues_by_ids(_ids) do
      {:ok, [Application.fetch_env!(:symphony_elixir, :attempt_fuse_test_issue)]}
    end
  end

  defmodule RejectingAttemptLedger do
    def reserve(issue, max_attempts) do
      send(Application.fetch_env!(:symphony_elixir, :attempt_fuse_test_pid), {
        :attempt_reserve_called,
        issue.id,
        max_attempts
      })

      {:error, :reservation_confirmation_failed}
    end

    def deactivate(issue, evidence) do
      send(Application.fetch_env!(:symphony_elixir, :attempt_fuse_test_pid), {
        :attempt_deactivate_called,
        issue.id,
        evidence
      })

      {:ok, %{deactivated: true}}
    end
  end

  test "reservation failure blocks and deactivates before any worker process starts" do
    suffix = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "symphony-attempt-orchestrator-#{suffix}")
    lock_port = available_port()
    workflow_path = Workflow.workflow_file_path()
    runtime_name = Module.concat(__MODULE__, "Runtime#{suffix}")
    task_supervisor_name = Module.concat(__MODULE__, "Tasks#{suffix}")
    orchestrator_name = Module.concat(__MODULE__, "Orchestrator#{suffix}")
    issue = issue(suffix)
    issue_id = issue.id

    stop_default_runtime!()
    Application.put_env(:symphony_elixir, :github_client_module, FakeGitHubClient)
    Application.put_env(:symphony_elixir, :github_attempt_ledger_module, RejectingAttemptLedger)
    Application.put_env(:symphony_elixir, :attempt_fuse_test_issue, issue)
    Application.put_env(:symphony_elixir, :attempt_fuse_test_pid, self())

    on_exit(fn ->
      if pid = Process.whereis(runtime_name), do: GenServer.stop(pid)

      Application.delete_env(:symphony_elixir, :github_client_module)
      Application.delete_env(:symphony_elixir, :github_attempt_ledger_module)
      Application.delete_env(:symphony_elixir, :attempt_fuse_test_issue)
      Application.delete_env(:symphony_elixir, :attempt_fuse_test_pid)
      write_workflow_file!(workflow_path, tracker_kind: "memory")
      restart_default_runtime!()
      File.rm_rf(root)
    end)

    write_github_attempt_workflow!(workflow_path, root, lock_port)
    assert :ok = WorkflowStore.force_reload()

    assert {:ok, runtime_pid} =
             SymphonyElixir.AgentRuntimeSupervisor.start_link(
               name: runtime_name,
               task_supervisor_name: task_supervisor_name,
               orchestrator_name: orchestrator_name
             )

    Process.unlink(runtime_pid)

    assert_receive {:attempt_reserve_called, ^issue_id, 5}, 2_000
    assert_receive {:attempt_deactivate_called, ^issue_id, evidence}, 2_000
    assert evidence.max == 5
    assert evidence.reason =~ "reservation_confirmation_failed"

    assert %{running: [], blocked: [%{issue_id: blocked_issue_id}], attempt_usage: attempt_usage} =
             Orchestrator.snapshot(orchestrator_name, 1_000)

    assert blocked_issue_id == issue.id
    assert Map.has_key?(attempt_usage, issue.id)

    assert Supervisor.which_children(task_supervisor_name) == []
  end

  defp stop_default_runtime! do
    if Process.whereis(SymphonyElixir.AgentRuntimeSupervisor) do
      :ok =
        Supervisor.terminate_child(
          SymphonyElixir.Supervisor,
          SymphonyElixir.AgentRuntimeSupervisor
        )
    end
  end

  defp restart_default_runtime! do
    if is_nil(Process.whereis(SymphonyElixir.AgentRuntimeSupervisor)) do
      case Supervisor.restart_child(
             SymphonyElixir.Supervisor,
             SymphonyElixir.AgentRuntimeSupervisor
           ) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end
  end

  defp write_github_attempt_workflow!(path, root, lock_port) do
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
        interval_ms: 10
      workspace:
        root: "#{Path.join(root, "workspaces")}"
      agent:
        max_concurrent_agents: 1
        max_turns: 24
        max_retry_backoff_ms: 60000
        max_attempts: 5
        instance_lock_port: #{lock_port}
      codex:
        command: "codex app-server"
      ---

      Disposable attempt-fuse rehearsal.
      """
    )
  end

  defp issue(suffix) do
    number = 10_000 + suffix

    %Issue{
      id: Integer.to_string(number),
      identifier: "GH-#{number}",
      title: "Attempt reservation must fail closed",
      state: "open",
      url: "https://github.test/octo/repo/issues/#{number}",
      labels: ["agent-ready", "pilot:symphony"],
      dispatchable: true,
      native_ref: %{
        "repo" => "octo/repo",
        "number" => number,
        "id" => 50_000 + suffix,
        "node_id" => "I_#{number}"
      }
    }
  end

  defp available_port do
    {:ok, socket} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        ip: {127, 0, 0, 1},
        reuseaddr: false
      ])

    {:ok, {_address, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
