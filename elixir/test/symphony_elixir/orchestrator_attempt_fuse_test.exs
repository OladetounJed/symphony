defmodule SymphonyElixir.OrchestratorAttemptFuseTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.AttemptLedger

  @attempt_marker "<!-- iwe-symphony-attempt:v1 -->\n"
  @exhaustion_marker "<!-- iwe-symphony-exhaustion:v1 -->\n"

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
    def reserve(issue, max_attempts, _attempt_fuse) do
      send(Application.fetch_env!(:symphony_elixir, :attempt_fuse_test_pid), {
        :attempt_reserve_called,
        issue.id,
        max_attempts
      })

      {:error, :reservation_confirmation_failed}
    end

    def deactivate(issue, evidence, _attempt_fuse) do
      send(Application.fetch_env!(:symphony_elixir, :attempt_fuse_test_pid), {
        :attempt_deactivate_called,
        issue.id,
        evidence
      })

      {:ok, %{deactivated: true}}
    end
  end

  defmodule RecordingAttemptLedger do
    alias SymphonyElixir.GitHub.AttemptLedger

    def reserve(issue, max_attempts, attempt_fuse) do
      result =
        AttemptLedger.reserve_for_test(
          issue,
          max_attempts,
          attempt_fuse.tracker_settings,
          request_fun(),
          workspace_root: attempt_fuse.workspace_root
        )

      case result do
        {:ok, evidence} -> notify({:attempt_reserved, evidence.used})
        other -> notify({:attempt_reservation_result, other})
      end

      result
    end

    def deactivate(issue, evidence, attempt_fuse) do
      result =
        AttemptLedger.deactivate_for_test(
          issue,
          evidence,
          attempt_fuse.tracker_settings,
          request_fun(),
          workspace_root: attempt_fuse.workspace_root
        )

      notify({:attempt_deactivated, result})
      result
    end

    defp request_fun do
      remote = Application.fetch_env!(:symphony_elixir, :attempt_fuse_remote)

      fn method, path, params, body, _settings ->
        Agent.get_and_update(remote, fn state ->
          state = %{state | calls: state.calls ++ [{method, path, params, body}]}
          handle_request(method, path, params, body, state)
        end)
      end
    end

    defp handle_request("GET", "/repos/octo/repo/issues/42/comments", params, _body, state) do
      page = params["page"] || 1
      comments = Enum.slice(state.comments, (page - 1) * 100, 100)
      {{:ok, %{status: 200, body: comments}}, state}
    end

    defp handle_request("POST", "/repos/octo/repo/issues/42/comments", _params, body, state) do
      comment = trusted_comment(state.next_id, body["body"])
      updated = %{state | comments: state.comments ++ [comment], next_id: state.next_id + 1}
      {{:ok, %{status: 201, body: comment}}, updated}
    end

    defp handle_request(
           "DELETE",
           "/repos/octo/repo/issues/42/labels/pilot%3Asymphony",
           _params,
           _body,
           state
         ) do
      {{:ok, %{status: 204, body: nil}}, %{state | labels: state.labels -- ["pilot:symphony"]}}
    end

    defp handle_request("GET", "/repos/octo/repo/issues/42", _params, _body, state) do
      labels = Enum.map(state.labels, &%{"name" => &1})
      {{:ok, %{status: 200, body: %{"labels" => labels}}}, state}
    end

    defp handle_request(method, path, _params, _body, state) do
      {{:error, {:unexpected_request, method, path}}, state}
    end

    defp trusted_comment(id, body) do
      %{
        "id" => id,
        "html_url" => "https://github.test/octo/repo/issues/42#issuecomment-#{id}",
        "body" => body,
        "created_at" => "2026-01-01T00:00:00Z",
        "updated_at" => "2026-01-01T00:00:00Z",
        "user" => %{"id" => 88, "type" => "Bot"},
        "performed_via_github_app" => %{"id" => 99}
      }
    end

    defp notify(message) do
      send(Application.fetch_env!(:symphony_elixir, :attempt_fuse_test_pid), message)
    end
  end

  defmodule ScriptedRunner do
    def run(_issue, _recipient, opts) do
      attempt = Keyword.fetch!(opts, :attempt)
      send(Application.fetch_env!(:symphony_elixir, :attempt_fuse_test_pid), {:worker_started, attempt})
      Process.sleep(50)

      if attempt == 2, do: exit(:scripted_worker_failure), else: :ok
    end
  end

  defmodule FailingTaskStarter do
    def start_child(_supervisor, _fun), do: {:error, :scripted_spawn_failure}
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
    refute Map.has_key?(attempt_usage, issue.id)

    assert Supervisor.which_children(task_supervisor_name) == []
  end

  test "real supervised runtime starts exactly five workers across restart and never reaches Codex" do
    suffix = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "symphony-attempt-rehearsal-#{suffix}")
    lock_port = available_port()
    workflow_path = Workflow.workflow_file_path()
    runtime_name = Module.concat(__MODULE__, "RehearsalRuntime#{suffix}")
    worker_runtime_name = Module.concat(__MODULE__, "RehearsalWorkers#{suffix}")
    task_supervisor_name = Module.concat(__MODULE__, "RehearsalTasks#{suffix}")
    orchestrator_name = Module.concat(__MODULE__, "RehearsalOrchestrator#{suffix}")
    instance_lock_name = Module.concat(__MODULE__, "RehearsalLock#{suffix}")
    issue = %{issue(suffix) | id: "42", identifier: "GH-42", native_ref: Map.merge(issue(suffix).native_ref, %{"number" => 42, "id" => 4_242, "node_id" => "I_42"})}
    {:ok, remote} = Agent.start_link(fn -> remote_state() end)

    stop_default_runtime!()
    Application.put_env(:symphony_elixir, :github_client_module, FakeGitHubClient)
    Application.put_env(:symphony_elixir, :github_attempt_ledger_module, RecordingAttemptLedger)
    Application.put_env(:symphony_elixir, :agent_runner_module, ScriptedRunner)
    Application.put_env(:symphony_elixir, :attempt_fuse_test_issue, issue)
    Application.put_env(:symphony_elixir, :attempt_fuse_test_pid, self())
    Application.put_env(:symphony_elixir, :attempt_fuse_remote, remote)

    on_exit(fn ->
      if pid = Process.whereis(runtime_name), do: GenServer.stop(pid)
      if Process.alive?(remote), do: Agent.stop(remote)

      for key <- [
            :github_client_module,
            :github_attempt_ledger_module,
            :agent_runner_module,
            :attempt_fuse_test_issue,
            :attempt_fuse_test_pid,
            :attempt_fuse_remote
          ] do
        Application.delete_env(:symphony_elixir, key)
      end

      write_workflow_file!(workflow_path, tracker_kind: "memory")
      restart_default_runtime!()
      File.rm_rf(root)
    end)

    write_github_attempt_workflow!(workflow_path, root, lock_port)
    assert :ok = WorkflowStore.force_reload()

    runtime_opts = [
      name: runtime_name,
      worker_runtime_name: worker_runtime_name,
      task_supervisor_name: task_supervisor_name,
      orchestrator_name: orchestrator_name,
      instance_lock_name: instance_lock_name
    ]

    assert {:ok, first_runtime} = SymphonyElixir.AgentRuntimeSupervisor.start_link(runtime_opts)
    Process.unlink(first_runtime)

    for attempt <- 1..2 do
      assert_receive {:attempt_reserved, ^attempt}, 3_000
      assert_receive {:worker_started, ^attempt}, 3_000
    end

    GenServer.stop(first_runtime)
    assert is_nil(Process.whereis(orchestrator_name))

    assert {:ok, second_runtime} = SymphonyElixir.AgentRuntimeSupervisor.start_link(runtime_opts)
    Process.unlink(second_runtime)

    for attempt <- 3..5 do
      assert_receive {:attempt_reserved, ^attempt}, 3_000
      assert_receive {:worker_started, ^attempt}, 3_000
    end

    assert_receive {:attempt_deactivated, {:ok, %{deactivated: true}}}, 3_000
    refute_receive {:attempt_reserved, 6}, 1_200
    refute_receive {:worker_started, 6}, 0

    assert %{running: [], retrying: [], blocked: [%{attempt_usage: %{used: 5, exhausted: true}}]} =
             Orchestrator.snapshot(orchestrator_name, 1_000)

    snapshot = Agent.get(remote, & &1)
    assert Enum.count(snapshot.comments, &String.starts_with?(&1["body"], @attempt_marker)) == 5
    assert Enum.count(snapshot.comments, &String.starts_with?(&1["body"], @exhaustion_marker)) == 1
    refute "pilot:symphony" in snapshot.labels
    assert snapshot.codex_calls == 0
  end

  test "a consumed reservation remains visible when task spawning fails" do
    suffix = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "symphony-attempt-spawn-failure-#{suffix}")
    lock_port = available_port()
    workflow_path = Workflow.workflow_file_path()
    runtime_name = Module.concat(__MODULE__, "SpawnRuntime#{suffix}")
    task_supervisor_name = Module.concat(__MODULE__, "SpawnTasks#{suffix}")
    orchestrator_name = Module.concat(__MODULE__, "SpawnOrchestrator#{suffix}")
    instance_lock_name = Module.concat(__MODULE__, "SpawnLock#{suffix}")
    issue = %{issue(suffix) | id: "42", identifier: "GH-42", native_ref: Map.merge(issue(suffix).native_ref, %{"number" => 42, "id" => 4_242, "node_id" => "I_42"})}
    {:ok, remote} = Agent.start_link(fn -> remote_state() end)

    stop_default_runtime!()
    Application.put_env(:symphony_elixir, :github_client_module, FakeGitHubClient)
    Application.put_env(:symphony_elixir, :github_attempt_ledger_module, RecordingAttemptLedger)
    Application.put_env(:symphony_elixir, :task_starter_module, FailingTaskStarter)
    Application.put_env(:symphony_elixir, :attempt_fuse_test_issue, issue)
    Application.put_env(:symphony_elixir, :attempt_fuse_test_pid, self())
    Application.put_env(:symphony_elixir, :attempt_fuse_remote, remote)

    on_exit(fn ->
      if pid = Process.whereis(runtime_name), do: GenServer.stop(pid)
      if Process.alive?(remote), do: Agent.stop(remote)

      for key <- [
            :github_client_module,
            :github_attempt_ledger_module,
            :task_starter_module,
            :attempt_fuse_test_issue,
            :attempt_fuse_test_pid,
            :attempt_fuse_remote
          ] do
        Application.delete_env(:symphony_elixir, key)
      end

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
               orchestrator_name: orchestrator_name,
               instance_lock_name: instance_lock_name
             )

    Process.unlink(runtime_pid)
    assert_receive {:attempt_reserved, 1}, 3_000

    assert %{running: [], retrying: [%{attempt_usage: %{used: 1}, error: error}]} =
             eventually_value(fn ->
               case Orchestrator.snapshot(orchestrator_name, 1_000) do
                 %{retrying: [_ | _]} = snapshot -> snapshot
                 _ -> nil
               end
             end)

    assert error =~ "scripted_spawn_failure"
  end

  test "a queued retry fails closed when any frozen fuse setting reloads" do
    suffix = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "symphony-attempt-reload-#{suffix}")
    lock_port = available_port()
    workflow_path = Workflow.workflow_file_path()
    runtime_name = Module.concat(__MODULE__, "ReloadRuntime#{suffix}")
    orchestrator_name = Module.concat(__MODULE__, "ReloadOrchestrator#{suffix}")
    issue = %{issue(suffix) | id: "42", identifier: "GH-42", native_ref: Map.merge(issue(suffix).native_ref, %{"number" => 42, "id" => 4_242, "node_id" => "I_42"})}
    {:ok, remote} = Agent.start_link(fn -> remote_state() end)

    stop_default_runtime!()
    Application.put_env(:symphony_elixir, :github_client_module, FakeGitHubClient)
    Application.put_env(:symphony_elixir, :github_attempt_ledger_module, RecordingAttemptLedger)
    Application.put_env(:symphony_elixir, :agent_runner_module, ScriptedRunner)
    Application.put_env(:symphony_elixir, :attempt_fuse_test_issue, issue)
    Application.put_env(:symphony_elixir, :attempt_fuse_test_pid, self())
    Application.put_env(:symphony_elixir, :attempt_fuse_remote, remote)

    on_exit(fn ->
      if pid = Process.whereis(runtime_name), do: GenServer.stop(pid)
      if Process.alive?(remote), do: Agent.stop(remote)

      for key <- [
            :github_client_module,
            :github_attempt_ledger_module,
            :agent_runner_module,
            :attempt_fuse_test_issue,
            :attempt_fuse_test_pid,
            :attempt_fuse_remote
          ] do
        Application.delete_env(:symphony_elixir, key)
      end

      write_workflow_file!(workflow_path, tracker_kind: "memory")
      restart_default_runtime!()
      File.rm_rf(root)
    end)

    write_github_attempt_workflow!(workflow_path, root, lock_port)
    assert :ok = WorkflowStore.force_reload()

    assert {:ok, runtime_pid} =
             SymphonyElixir.AgentRuntimeSupervisor.start_link(
               name: runtime_name,
               orchestrator_name: orchestrator_name,
               task_supervisor_name: Module.concat(__MODULE__, "ReloadTasks#{suffix}"),
               instance_lock_name: Module.concat(__MODULE__, "ReloadLock#{suffix}")
             )

    Process.unlink(runtime_pid)
    assert_receive {:attempt_reserved, 1}, 3_000
    assert_receive {:worker_started, 1}, 3_000

    write_github_attempt_workflow!(workflow_path, root, lock_port, source_revision: String.duplicate("b", 40))

    assert :ok = WorkflowStore.force_reload()
    assert_receive {:attempt_deactivated, _result}, 3_000
    refute_receive {:attempt_reserved, 2}, 1_200

    assert %{running: [], retrying: [], blocked: [_]} =
             Orchestrator.snapshot(orchestrator_name, 1_000)
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

  defp write_github_attempt_workflow!(path, root, lock_port, opts \\ []) do
    source_revision = Keyword.get(opts, :source_revision, String.duplicate("a", 40))

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
            source_revision: "#{source_revision}"
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

  defp remote_state do
    %{
      comments: [],
      labels: ["agent-ready", "pilot:symphony"],
      next_id: 1_000,
      calls: [],
      codex_calls: 0
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

  defp eventually_value(fun, attempts \\ 50)

  defp eventually_value(fun, attempts) when attempts > 0 do
    case fun.() do
      nil ->
        Process.sleep(20)
        eventually_value(fun, attempts - 1)

      value ->
        value
    end
  end

  defp eventually_value(_fun, 0), do: nil
end
