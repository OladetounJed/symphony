defmodule SymphonyElixir.OrchestratorAttemptFuseTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{AgentRunner, AttemptFuse, Config, GitHub.AttemptLedger, InstanceLock}

  @attempt_marker "<!-- iwe-symphony-attempt:v1 -->\n"
  @exhaustion_marker "<!-- iwe-symphony-exhaustion:v1 -->\n"

  defmodule FakeGitHubClient do
    def fetch_issues_by_states(states) do
      issues =
        Application.get_env(:symphony_elixir, :attempt_fuse_test_issues) ||
          [Application.fetch_env!(:symphony_elixir, :attempt_fuse_test_issue)]

      if "open" in Enum.map(states, &String.downcase/1) do
        {:ok, issues}
      else
        {:ok, []}
      end
    end

    def fetch_issues_by_ids(ids) do
      issues =
        Application.get_env(:symphony_elixir, :attempt_fuse_test_issues) ||
          [Application.fetch_env!(:symphony_elixir, :attempt_fuse_test_issue)]

      {:ok, Enum.filter(issues, &(&1.id in ids))}
    end
  end

  defmodule TripOnRefreshGitHubClient do
    def fetch_issues_by_states(states), do: FakeGitHubClient.fetch_issues_by_states(states)

    def fetch_issues_by_ids(ids) do
      lock_name = Application.fetch_env!(:symphony_elixir, :attempt_fuse_test_lock_name)
      :ok = SymphonyElixir.InstanceLock.trip(lock_name, :trip_during_dispatch_refresh)
      FakeGitHubClient.fetch_issues_by_ids(ids)
    end
  end

  defmodule FrozenSettingsGitHubClient do
    def fetch_issues_by_ids(ids, tracker_settings) do
      send(Application.fetch_env!(:symphony_elixir, :attempt_fuse_test_pid), {
        :frozen_issue_refresh,
        ids,
        tracker_settings
      })

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

  defmodule UnfencedAttemptLedger do
    def reserve(issue, max_attempts, _attempt_fuse) do
      send(Application.fetch_env!(:symphony_elixir, :attempt_fuse_test_pid), {
        :attempt_reserve_called,
        issue.id,
        max_attempts
      })

      {:error, :reservation_confirmation_failed}
    end

    def deactivate(_issue, _evidence, _attempt_fuse) do
      quarantine_reason = :local_quarantine_failed
      delete_reason = :remote_delete_failed
      confirmation_reason = :remote_confirmation_failed
      evidence_reason = {:error, :remote_evidence_failed}

      reason =
        {:attempt_deactivation_unfenced, quarantine_reason, delete_reason, confirmation_reason, evidence_reason}

      {:error, reason}
    end
  end

  defmodule TripAfterReservationAttemptLedger do
    def reserve(issue, max_attempts, _attempt_fuse) do
      lock_name = Application.fetch_env!(:symphony_elixir, :attempt_fuse_test_lock_name)
      :ok = SymphonyElixir.InstanceLock.trip(lock_name, :trip_after_reservation)

      evidence = %{used: 1, max: max_attempts, exhausted: false}

      send(Application.fetch_env!(:symphony_elixir, :attempt_fuse_test_pid), {
        :attempt_reserved_then_tripped,
        issue.id,
        evidence
      })

      {:ok, evidence}
    end

    def deactivate(issue, evidence, _attempt_fuse) do
      send(Application.fetch_env!(:symphony_elixir, :attempt_fuse_test_pid), {
        :attempt_deactivated_after_trip,
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
      issue_body = state.issue_body || %{"labels" => labels}
      {{:ok, %{status: 200, body: issue_body}}, state}
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

  defmodule ReservationErrorRealDeactivationLedger do
    def reserve(issue, max_attempts, _attempt_fuse) do
      send(Application.fetch_env!(:symphony_elixir, :attempt_fuse_test_pid), {
        :attempt_reserve_called,
        issue.id,
        max_attempts
      })

      {:error, :reservation_confirmation_failed}
    end

    def deactivate(issue, evidence, attempt_fuse) do
      RecordingAttemptLedger.deactivate(issue, evidence, attempt_fuse)
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

  defmodule FailOnceTaskStarter do
    def start_child(supervisor, fun) do
      state = Application.fetch_env!(:symphony_elixir, :attempt_fuse_task_starter_state)

      fail? =
        Agent.get_and_update(state, fn
          :fail -> {true, :delegate}
          :delegate -> {false, :delegate}
        end)

      if fail?, do: {:error, :scripted_spawn_failure}, else: Task.Supervisor.start_child(supervisor, fun)
    end
  end

  defmodule StallingRunner do
    def run(_issue, _recipient, opts) do
      attempt = Keyword.fetch!(opts, :attempt)
      send(Application.fetch_env!(:symphony_elixir, :attempt_fuse_test_pid), {:worker_started, attempt})

      if attempt == 1, do: Process.sleep(:infinity), else: :ok
    end
  end

  defmodule FifthBoundaryRunner do
    def run(issue, recipient, opts) do
      attempt = Keyword.fetch!(opts, :attempt)
      send(Application.fetch_env!(:symphony_elixir, :attempt_fuse_test_pid), {:worker_started, attempt})

      case {attempt, Application.fetch_env!(:symphony_elixir, :fifth_boundary_mode)} do
        {5, :silent_stall} ->
          Process.sleep(:infinity)

        {5, :input_stall} ->
          send(recipient, {
            :codex_worker_update,
            issue.id,
            %{event: :turn_input_required, timestamp: DateTime.utc_now()}
          })

          Process.sleep(:infinity)

        _ ->
          :ok
      end
    end
  end

  defmodule FailOnFifthTaskStarter do
    def start_child(supervisor, fun) do
      state = Application.fetch_env!(:symphony_elixir, :attempt_fuse_task_starter_state)
      count = Agent.get_and_update(state, fn count -> {count + 1, count + 1} end)

      if count == 5, do: {:error, :fifth_spawn_failed}, else: Task.Supervisor.start_child(supervisor, fun)
    end
  end

  defmodule ObservingWorkspace do
    def create_for_issue(_issue, worker_host, attempt_fuse) do
      notify({:workspace_create, worker_host, attempt_fuse.execution_settings})
      {:ok, "/tmp/frozen-agent-runner-workspace"}
    end

    def run_before_run_hook(workspace, _issue, worker_host, attempt_fuse) do
      notify({:workspace_before_run, workspace, worker_host, attempt_fuse.execution_settings})

      case Application.get_env(:symphony_elixir, :attempt_fuse_before_run_mutation) do
        fun when is_function(fun, 0) -> fun.()
        _ -> :ok
      end
    end

    def run_after_run_hook(workspace, _issue, worker_host, attempt_fuse) do
      notify({:workspace_after_run, workspace, worker_host, attempt_fuse.execution_settings})
      :ok
    end

    defp notify(message) do
      send(Application.fetch_env!(:symphony_elixir, :attempt_fuse_test_pid), message)
    end
  end

  defmodule ObservingAppServer do
    def start_session(workspace, opts) do
      send(Application.fetch_env!(:symphony_elixir, :attempt_fuse_test_pid), {
        :app_server_start,
        workspace,
        Keyword.fetch!(opts, :worker_host),
        Keyword.fetch!(opts, :execution_settings),
        Keyword.fetch!(opts, :dynamic_tool_binding)
      })

      {:ok, %{session_id: "frozen-session"}}
    end

    def run_turn(session, prompt, _issue, _opts) do
      send(Application.fetch_env!(:symphony_elixir, :attempt_fuse_test_pid), {
        :app_server_turn,
        prompt
      })

      {:ok, session}
    end

    def stop_session(_session) do
      send(Application.fetch_env!(:symphony_elixir, :attempt_fuse_test_pid), :app_server_stop)
      :ok
    end
  end

  test "the production AgentRunner passes one frozen execution profile through every worker boundary" do
    suffix = System.unique_integer([:positive])
    root = Path.join(canonical_tmp_dir(), "symphony-agent-runner-frozen-#{suffix}")
    workflow_path = Workflow.workflow_file_path()
    issue = issue(suffix)
    binding = %{tool_specs: [], secret_environment_names: ["FROZEN_TRACKER_TOKEN"]}

    stop_default_runtime!()
    Application.put_env(:symphony_elixir, :workspace_module, ObservingWorkspace)
    Application.put_env(:symphony_elixir, :codex_app_server_module, ObservingAppServer)
    Application.put_env(:symphony_elixir, :github_client_module, FrozenSettingsGitHubClient)
    Application.put_env(:symphony_elixir, :attempt_fuse_test_issue, issue)
    Application.put_env(:symphony_elixir, :attempt_fuse_test_pid, self())

    on_exit(fn ->
      for key <- [
            :workspace_module,
            :codex_app_server_module,
            :github_client_module,
            :attempt_fuse_test_issue,
            :attempt_fuse_test_pid,
            :attempt_fuse_before_run_mutation
          ] do
        Application.delete_env(:symphony_elixir, key)
      end

      write_workflow_file!(workflow_path, tracker_kind: "memory")
      restart_default_runtime!()
      File.rm_rf(root)
    end)

    write_github_attempt_workflow!(workflow_path, root, available_port(),
      max_turns: 2,
      worker_hosts: ["frozen-worker"]
    )

    assert :ok = WorkflowStore.force_reload()
    frozen = Config.settings!() |> AttemptFuse.snapshot()

    assert :ok =
             AgentRunner.run(issue, self(),
               attempt_fuse: frozen,
               dynamic_tool_binding: binding
             )

    assert_receive {:workspace_create, "frozen-worker", execution_settings}
    assert execution_settings == frozen.execution_settings
    assert_receive {:worker_runtime_info, _, %{worker_host: "frozen-worker"}}
    assert_receive {:workspace_before_run, _, "frozen-worker", ^execution_settings}

    assert_receive {:app_server_start, _, "frozen-worker", ^execution_settings, ^binding}
    assert_receive {:app_server_turn, first_prompt}
    assert first_prompt =~ "Disposable attempt-fuse rehearsal"
    assert_receive {:frozen_issue_refresh, [issue_id], tracker_settings}
    assert issue_id == issue.id
    assert tracker_settings == frozen.execution_settings.tracker
    assert_receive {:app_server_turn, second_prompt}
    assert second_prompt =~ "Continuation guidance"
    assert_receive {:frozen_issue_refresh, [^issue_id], ^tracker_settings}
    assert_receive :app_server_stop
    assert_receive {:workspace_after_run, _, "frozen-worker", ^execution_settings}
    refute_receive {:app_server_turn, _}, 0
  end

  test "the production AgentRunner rejects hook-time execution-profile drift before App Server launch" do
    suffix = System.unique_integer([:positive])
    root = Path.join(canonical_tmp_dir(), "symphony-agent-runner-drift-#{suffix}")
    workflow_path = Workflow.workflow_file_path()
    lock_port = available_port()
    issue = issue(suffix)

    stop_default_runtime!()
    Application.put_env(:symphony_elixir, :workspace_module, ObservingWorkspace)
    Application.put_env(:symphony_elixir, :codex_app_server_module, ObservingAppServer)
    Application.put_env(:symphony_elixir, :attempt_fuse_test_pid, self())

    on_exit(fn ->
      for key <- [
            :workspace_module,
            :codex_app_server_module,
            :attempt_fuse_test_pid,
            :attempt_fuse_before_run_mutation
          ] do
        Application.delete_env(:symphony_elixir, key)
      end

      write_workflow_file!(workflow_path, tracker_kind: "memory")
      restart_default_runtime!()
      File.rm_rf(root)
    end)

    write_github_attempt_workflow!(workflow_path, root, lock_port, max_turns: 2)
    assert :ok = WorkflowStore.force_reload()
    frozen = Config.settings!() |> AttemptFuse.snapshot()

    Application.put_env(:symphony_elixir, :attempt_fuse_before_run_mutation, fn ->
      write_github_attempt_workflow!(workflow_path, root, lock_port,
        max_turns: 99,
        stall_timeout_ms: 1,
        worker_hosts: ["expanded-worker"]
      )

      WorkflowStore.force_reload()
    end)

    assert_raise RuntimeError, ~r/attempt_fuse_config_drift/, fn ->
      AgentRunner.run(issue, self(),
        attempt_fuse: frozen,
        dynamic_tool_binding: %{tool_specs: [], secret_environment_names: []},
        issue_state_fetcher: fn [_id] -> {:ok, [issue]} end
      )
    end

    assert_receive {:workspace_create, nil, _}
    assert_receive {:workspace_before_run, _, nil, _}
    assert_receive {:workspace_after_run, _, nil, _}
    refute_receive {:app_server_start, _, _, _, _}, 0
  end

  test "reservation failure blocks and deactivates before any worker process starts" do
    suffix = System.unique_integer([:positive])
    root = Path.join(canonical_tmp_dir(), "symphony-attempt-orchestrator-#{suffix}")
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

  test "an unfenced deactivation trips the outer lock and survives inner runtime restart" do
    suffix = System.unique_integer([:positive])
    root = Path.join(canonical_tmp_dir(), "symphony-attempt-unfenced-#{suffix}")
    lock_port = available_port()
    workflow_path = Workflow.workflow_file_path()
    runtime_name = Module.concat(__MODULE__, "UnfencedRuntime#{suffix}")
    worker_runtime_name = Module.concat(__MODULE__, "UnfencedWorkers#{suffix}")
    orchestrator_name = Module.concat(__MODULE__, "UnfencedOrchestrator#{suffix}")
    lock_name = Module.concat(__MODULE__, "UnfencedLock#{suffix}")
    issue = issue(suffix)

    stop_default_runtime!()
    Application.put_env(:symphony_elixir, :github_client_module, FakeGitHubClient)
    Application.put_env(:symphony_elixir, :github_attempt_ledger_module, UnfencedAttemptLedger)
    Application.put_env(:symphony_elixir, :attempt_fuse_test_issue, issue)
    Application.put_env(:symphony_elixir, :attempt_fuse_test_pid, self())

    on_exit(fn ->
      if pid = Process.whereis(runtime_name), do: GenServer.stop(pid)

      for key <- [
            :github_client_module,
            :github_attempt_ledger_module,
            :attempt_fuse_test_issue,
            :attempt_fuse_test_pid
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
               worker_runtime_name: worker_runtime_name,
               orchestrator_name: orchestrator_name,
               task_supervisor_name: Module.concat(__MODULE__, "UnfencedTasks#{suffix}"),
               instance_lock_name: lock_name
             )

    Process.unlink(runtime_pid)
    assert_receive {:attempt_reserve_called, issue_id, 5}, 3_000
    assert issue_id == issue.id

    assert eventually_value(fn ->
             if InstanceLock.operational?(lock_name) == false, do: :tripped
           end) == :tripped

    first_orchestrator = Process.whereis(orchestrator_name)
    GenServer.stop(first_orchestrator)

    restarted_orchestrator =
      eventually_value(fn ->
        pid = Process.whereis(orchestrator_name)
        if is_pid(pid) and pid != first_orchestrator, do: pid
      end)

    assert is_pid(restarted_orchestrator)
    assert :sys.get_state(orchestrator_name).dispatch_suspended

    retry_token = make_ref()

    timer_ref =
      Process.send_after(
        orchestrator_name,
        {:retry_issue, issue.id, retry_token},
        60_000
      )

    :sys.replace_state(orchestrator_name, fn state ->
      retry = %{
        attempt: 2,
        timer_ref: timer_ref,
        retry_token: retry_token,
        due_at_ms: System.monotonic_time(:millisecond) + 60_000,
        identifier: issue.identifier,
        issue_url: issue.url,
        error: "stale retry after global trip",
        worker_host: nil,
        workspace_path: nil,
        attempt_usage: nil
      }

      %{state | retry_attempts: %{issue.id => retry}}
    end)

    send(orchestrator_name, {:retry_issue, issue.id, retry_token})

    assert eventually_value(fn ->
             state = :sys.get_state(orchestrator_name)
             if state.retry_attempts == %{}, do: :cleared
           end) == :cleared

    assert Process.read_timer(timer_ref) == false
    refute Orchestrator.should_dispatch_issue_for_test(issue, :sys.get_state(orchestrator_name))
    refute_receive {:attempt_reserve_called, _, _}, 100
  end

  test "a malformed GitHub label-confirmation payload trips the outer lock instead of crashing open" do
    workflow_path = Workflow.workflow_file_path()
    stop_default_runtime!()

    on_exit(fn ->
      for key <- [
            :github_client_module,
            :github_attempt_ledger_module,
            :attempt_fuse_test_issue,
            :attempt_fuse_test_pid,
            :attempt_fuse_remote
          ] do
        Application.delete_env(:symphony_elixir, key)
      end

      write_workflow_file!(workflow_path, tracker_kind: "memory")
      restart_default_runtime!()
    end)

    Enum.each(
      [
        %{},
        %{"labels" => 123},
        %{"labels" => [%{"name" => "agent-ready"}, %{"name" => 123}]}
      ],
      &run_malformed_confirmation_scenario(&1, workflow_path)
    )
  end

  test "an unfenced first issue halts the current dispatch batch before a second reservation" do
    suffix = System.unique_integer([:positive])
    root = Path.join(canonical_tmp_dir(), "symphony-attempt-batch-trip-#{suffix}")
    workflow_path = Workflow.workflow_file_path()
    runtime_name = Module.concat(__MODULE__, "BatchTripRuntime#{suffix}")
    orchestrator_name = Module.concat(__MODULE__, "BatchTripOrchestrator#{suffix}")
    lock_name = Module.concat(__MODULE__, "BatchTripLock#{suffix}")
    first = %{issue(suffix) | id: "1", identifier: "GH-1"}
    second = %{issue(suffix + 1) | id: "2", identifier: "GH-2"}

    stop_default_runtime!()
    Application.put_env(:symphony_elixir, :github_client_module, FakeGitHubClient)
    Application.put_env(:symphony_elixir, :github_attempt_ledger_module, UnfencedAttemptLedger)
    Application.put_env(:symphony_elixir, :attempt_fuse_test_issue, first)
    Application.put_env(:symphony_elixir, :attempt_fuse_test_issues, [first, second])
    Application.put_env(:symphony_elixir, :attempt_fuse_test_pid, self())

    on_exit(fn ->
      if pid = Process.whereis(runtime_name), do: GenServer.stop(pid)

      for key <- [
            :github_client_module,
            :github_attempt_ledger_module,
            :attempt_fuse_test_issue,
            :attempt_fuse_test_issues,
            :attempt_fuse_test_pid
          ] do
        Application.delete_env(:symphony_elixir, key)
      end

      write_workflow_file!(workflow_path, tracker_kind: "memory")
      restart_default_runtime!()
      File.rm_rf(root)
    end)

    write_github_attempt_workflow!(workflow_path, root, available_port())
    assert :ok = WorkflowStore.force_reload()

    assert {:ok, runtime_pid} =
             SymphonyElixir.AgentRuntimeSupervisor.start_link(
               name: runtime_name,
               orchestrator_name: orchestrator_name,
               task_supervisor_name: Module.concat(__MODULE__, "BatchTripTasks#{suffix}"),
               instance_lock_name: lock_name
             )

    Process.unlink(runtime_pid)
    assert_receive {:attempt_reserve_called, "1", 5}, 3_000

    assert eventually_value(fn ->
             if InstanceLock.operational?(lock_name) == false, do: :tripped
           end) == :tripped

    refute_receive {:attempt_reserve_called, "2", 5}, 200
    assert :sys.get_state(orchestrator_name).dispatch_suspended
  end

  test "the common dispatch gate blocks a reservation when refresh trips the singleton lock" do
    suffix = System.unique_integer([:positive])
    root = Path.join(canonical_tmp_dir(), "symphony-attempt-refresh-trip-#{suffix}")
    workflow_path = Workflow.workflow_file_path()
    runtime_name = Module.concat(__MODULE__, "RefreshTripRuntime#{suffix}")
    orchestrator_name = Module.concat(__MODULE__, "RefreshTripOrchestrator#{suffix}")
    lock_name = Module.concat(__MODULE__, "RefreshTripLock#{suffix}")
    issue = issue(suffix)

    stop_default_runtime!()
    Application.put_env(:symphony_elixir, :github_client_module, TripOnRefreshGitHubClient)
    Application.put_env(:symphony_elixir, :github_attempt_ledger_module, RejectingAttemptLedger)
    Application.put_env(:symphony_elixir, :attempt_fuse_test_issue, issue)
    Application.put_env(:symphony_elixir, :attempt_fuse_test_pid, self())
    Application.put_env(:symphony_elixir, :attempt_fuse_test_lock_name, lock_name)

    on_exit(fn ->
      if pid = Process.whereis(runtime_name), do: GenServer.stop(pid)

      for key <- [
            :github_client_module,
            :github_attempt_ledger_module,
            :attempt_fuse_test_issue,
            :attempt_fuse_test_pid,
            :attempt_fuse_test_lock_name
          ] do
        Application.delete_env(:symphony_elixir, key)
      end

      write_workflow_file!(workflow_path, tracker_kind: "memory")
      restart_default_runtime!()
      File.rm_rf(root)
    end)

    write_github_attempt_workflow!(workflow_path, root, available_port())
    assert :ok = WorkflowStore.force_reload()

    assert {:ok, runtime_pid} =
             SymphonyElixir.AgentRuntimeSupervisor.start_link(
               name: runtime_name,
               orchestrator_name: orchestrator_name,
               task_supervisor_name: Module.concat(__MODULE__, "RefreshTripTasks#{suffix}"),
               instance_lock_name: lock_name
             )

    Process.unlink(runtime_pid)

    assert eventually_value(fn ->
             if InstanceLock.operational?(lock_name) == false, do: :tripped
           end) == :tripped

    refute_receive {:attempt_reserve_called, _, _}, 200
    assert :sys.get_state(orchestrator_name).dispatch_suspended
  end

  test "a singleton trip during reservation consumes evidence but starts no worker" do
    suffix = System.unique_integer([:positive])
    root = Path.join(canonical_tmp_dir(), "symphony-attempt-reservation-trip-#{suffix}")
    workflow_path = Workflow.workflow_file_path()
    runtime_name = Module.concat(__MODULE__, "ReservationTripRuntime#{suffix}")
    orchestrator_name = Module.concat(__MODULE__, "ReservationTripOrchestrator#{suffix}")
    lock_name = Module.concat(__MODULE__, "ReservationTripLock#{suffix}")
    issue = issue(suffix)

    stop_default_runtime!()
    Application.put_env(:symphony_elixir, :github_client_module, FakeGitHubClient)

    Application.put_env(
      :symphony_elixir,
      :github_attempt_ledger_module,
      TripAfterReservationAttemptLedger
    )

    Application.put_env(:symphony_elixir, :agent_runner_module, ScriptedRunner)
    Application.put_env(:symphony_elixir, :attempt_fuse_test_issue, issue)
    Application.put_env(:symphony_elixir, :attempt_fuse_test_pid, self())
    Application.put_env(:symphony_elixir, :attempt_fuse_test_lock_name, lock_name)

    on_exit(fn ->
      if pid = Process.whereis(runtime_name), do: GenServer.stop(pid)

      for key <- [
            :github_client_module,
            :github_attempt_ledger_module,
            :agent_runner_module,
            :attempt_fuse_test_issue,
            :attempt_fuse_test_pid,
            :attempt_fuse_test_lock_name
          ] do
        Application.delete_env(:symphony_elixir, key)
      end

      write_workflow_file!(workflow_path, tracker_kind: "memory")
      restart_default_runtime!()
      File.rm_rf(root)
    end)

    write_github_attempt_workflow!(workflow_path, root, available_port())
    assert :ok = WorkflowStore.force_reload()

    assert {:ok, runtime_pid} =
             SymphonyElixir.AgentRuntimeSupervisor.start_link(
               name: runtime_name,
               orchestrator_name: orchestrator_name,
               task_supervisor_name: Module.concat(__MODULE__, "ReservationTripTasks#{suffix}"),
               instance_lock_name: lock_name
             )

    Process.unlink(runtime_pid)
    assert_receive {:attempt_reserved_then_tripped, issue_id, evidence}, 3_000
    assert issue_id == issue.id
    assert evidence.used == 1

    assert_receive {:attempt_deactivated_after_trip, ^issue_id, deactivation_evidence}, 3_000
    assert deactivation_evidence.used == 1
    assert deactivation_evidence.reason =~ "dispatch_suspended_after_reservation"

    refute_receive {:worker_started, _}, 200
    assert :sys.get_state(orchestrator_name).dispatch_suspended
    refute InstanceLock.operational?(lock_name)
  end

  test "real supervised runtime starts exactly five workers across restart and never reaches Codex" do
    suffix = System.unique_integer([:positive])
    root = Path.join(canonical_tmp_dir(), "symphony-attempt-rehearsal-#{suffix}")
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

    assert_next_event({:attempt_reserved, 1})
    assert_next_event({:worker_started, 1})
    assert_next_event({:attempt_reserved, 2})
    assert_next_event({:worker_started, 2})

    force_retry(orchestrator_name, issue.id)
    assert_next_event({:attempt_reserved, 3})
    assert_next_event({:worker_started, 3})

    GenServer.stop(first_runtime)
    assert is_nil(Process.whereis(orchestrator_name))

    assert {:ok, second_runtime} = SymphonyElixir.AgentRuntimeSupervisor.start_link(runtime_opts)
    Process.unlink(second_runtime)

    for attempt <- 4..5 do
      assert_next_event({:attempt_reserved, attempt})
      assert_next_event({:worker_started, attempt})
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
    root = Path.join(canonical_tmp_dir(), "symphony-attempt-spawn-failure-#{suffix}")
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
    {:ok, task_starter_state} = Agent.start_link(fn -> :fail end)
    Application.put_env(:symphony_elixir, :task_starter_module, FailOnceTaskStarter)
    Application.put_env(:symphony_elixir, :agent_runner_module, ScriptedRunner)
    Application.put_env(:symphony_elixir, :attempt_fuse_task_starter_state, task_starter_state)
    Application.put_env(:symphony_elixir, :attempt_fuse_test_issue, issue)
    Application.put_env(:symphony_elixir, :attempt_fuse_test_pid, self())
    Application.put_env(:symphony_elixir, :attempt_fuse_remote, remote)

    on_exit(fn ->
      if pid = Process.whereis(runtime_name), do: GenServer.stop(pid)
      if Process.alive?(remote), do: Agent.stop(remote)
      if Process.alive?(task_starter_state), do: Agent.stop(task_starter_state)

      for key <- [
            :github_client_module,
            :github_attempt_ledger_module,
            :task_starter_module,
            :agent_runner_module,
            :attempt_fuse_task_starter_state,
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

    force_retry(orchestrator_name, issue.id)
    assert_next_event({:attempt_reserved, 2})
    assert_next_event({:worker_started, 2})
  end

  test "stall recovery consumes and confirms another durable reservation before restart" do
    suffix = System.unique_integer([:positive])
    root = Path.join(canonical_tmp_dir(), "symphony-attempt-stall-#{suffix}")
    lock_port = available_port()
    workflow_path = Workflow.workflow_file_path()
    runtime_name = Module.concat(__MODULE__, "StallRuntime#{suffix}")
    orchestrator_name = Module.concat(__MODULE__, "StallOrchestrator#{suffix}")

    issue =
      %{issue(suffix) | id: "42", identifier: "GH-42", native_ref: Map.merge(issue(suffix).native_ref, %{"number" => 42, "id" => 4_242, "node_id" => "I_42"})}

    {:ok, remote} = Agent.start_link(fn -> remote_state() end)

    stop_default_runtime!()
    Application.put_env(:symphony_elixir, :github_client_module, FakeGitHubClient)
    Application.put_env(:symphony_elixir, :github_attempt_ledger_module, RecordingAttemptLedger)
    Application.put_env(:symphony_elixir, :agent_runner_module, StallingRunner)
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

    write_github_attempt_workflow!(workflow_path, root, lock_port, stall_timeout_ms: 1)
    assert :ok = WorkflowStore.force_reload()

    assert {:ok, runtime_pid} =
             SymphonyElixir.AgentRuntimeSupervisor.start_link(
               name: runtime_name,
               orchestrator_name: orchestrator_name,
               task_supervisor_name: Module.concat(__MODULE__, "StallTasks#{suffix}"),
               instance_lock_name: Module.concat(__MODULE__, "StallLock#{suffix}")
             )

    Process.unlink(runtime_pid)
    assert_next_event({:attempt_reserved, 1})
    assert_next_event({:worker_started, 1})

    force_retry(orchestrator_name, issue.id)
    assert_next_event({:attempt_reserved, 2})
    assert_next_event({:worker_started, 2})
  end

  test "an in-flight worker keeps the frozen stall watchdog after a workflow hot reload" do
    suffix = System.unique_integer([:positive])
    root = Path.join(canonical_tmp_dir(), "symphony-frozen-stall-#{suffix}")
    workflow_path = Workflow.workflow_file_path()
    lock_port = available_port()
    runtime_name = Module.concat(__MODULE__, "FrozenStallRuntime#{suffix}")
    orchestrator_name = Module.concat(__MODULE__, "FrozenStallOrchestrator#{suffix}")

    issue =
      %{issue(suffix) | id: "42", identifier: "GH-42", native_ref: Map.merge(issue(suffix).native_ref, %{"number" => 42, "id" => 4_242, "node_id" => "I_42"})}

    {:ok, remote} = Agent.start_link(fn -> remote_state() end)

    stop_default_runtime!()
    Application.put_env(:symphony_elixir, :github_client_module, FakeGitHubClient)
    Application.put_env(:symphony_elixir, :github_attempt_ledger_module, RecordingAttemptLedger)
    Application.put_env(:symphony_elixir, :agent_runner_module, StallingRunner)
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

    write_github_attempt_workflow!(workflow_path, root, lock_port, stall_timeout_ms: 300_000)
    assert :ok = WorkflowStore.force_reload()

    assert {:ok, runtime_pid} =
             SymphonyElixir.AgentRuntimeSupervisor.start_link(
               name: runtime_name,
               orchestrator_name: orchestrator_name,
               task_supervisor_name: Module.concat(__MODULE__, "FrozenStallTasks#{suffix}"),
               instance_lock_name: Module.concat(__MODULE__, "FrozenStallLock#{suffix}")
             )

    Process.unlink(runtime_pid)
    assert_next_event({:attempt_reserved, 1})
    assert_next_event({:worker_started, 1})

    write_github_attempt_workflow!(workflow_path, root, lock_port, stall_timeout_ms: 1)
    assert :ok = WorkflowStore.force_reload()
    Process.sleep(100)

    assert %{running: [%{issue_id: "42"}], retrying: [], blocked: []} =
             Orchestrator.snapshot(orchestrator_name, 1_000)

    refute_receive {:attempt_reserved, 2}, 100
    refute_receive {:attempt_deactivated, _}, 0
  end

  test "a silent fifth-worker stall deactivates without a sixth reservation" do
    run_fifth_boundary_scenario(:silent_stall)
  end

  test "an input-required fifth-worker stall deactivates without an in-memory-only block" do
    run_fifth_boundary_scenario(:input_stall)
  end

  test "a fifth task-spawn failure deactivates immediately without retrying" do
    run_fifth_boundary_scenario(:spawn_failure)
  end

  test "a queued retry fails closed when any frozen fuse setting reloads" do
    suffix = System.unique_integer([:positive])
    root = Path.join(canonical_tmp_dir(), "symphony-attempt-reload-#{suffix}")
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
    stall_timeout_ms = Keyword.get(opts, :stall_timeout_ms, 300_000)
    max_turns = Keyword.get(opts, :max_turns, 24)
    worker_hosts = Keyword.get(opts, :worker_hosts, [])
    high_water_root = Path.join(root, "host-state")
    File.mkdir_p!(high_water_root)
    File.chmod!(high_water_root, 0o700)

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
            high_water_root: "#{high_water_root}"
        required_labels: ["agent-ready", "pilot:symphony"]
        active_states: ["open"]
        terminal_states: ["closed"]
      polling:
        interval_ms: 10
      workspace:
        root: "#{Path.join(root, "workspaces")}"
      worker:
        ssh_hosts: #{inspect(worker_hosts)}
        max_concurrent_agents_per_host: 1
      agent:
        max_concurrent_agents: 1
        max_turns: #{max_turns}
        max_retry_backoff_ms: 60000
        max_attempts: 5
        instance_lock_port: #{lock_port}
      codex:
        command: "codex app-server"
        stall_timeout_ms: #{stall_timeout_ms}
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
      issue_body: nil,
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

  defp canonical_tmp_dir do
    {:ok, path} = SymphonyElixir.PathSafety.canonicalize(System.tmp_dir!())
    path
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

  defp assert_next_event(expected, timeout \\ 3_000) do
    receive do
      message -> assert message == expected
    after
      timeout -> flunk("timed out waiting for #{inspect(expected)}")
    end
  end

  defp force_retry(orchestrator_name, issue_id) do
    retry =
      eventually_value(fn ->
        state = :sys.get_state(orchestrator_name)
        Map.get(state.retry_attempts, issue_id)
      end)

    assert is_map(retry)
    send(orchestrator_name, {:retry_issue, issue_id, retry.retry_token})
  end

  defp run_malformed_confirmation_scenario(issue_body, workflow_path) do
    suffix = System.unique_integer([:positive])
    root = Path.join(canonical_tmp_dir(), "symphony-attempt-malformed-confirm-#{suffix}")
    runtime_name = Module.concat(__MODULE__, "MalformedConfirmRuntime#{suffix}")
    orchestrator_name = Module.concat(__MODULE__, "MalformedConfirmOrchestrator#{suffix}")
    lock_name = Module.concat(__MODULE__, "MalformedConfirmLock#{suffix}")

    issue =
      %{issue(suffix) | id: "42", identifier: "GH-42", native_ref: Map.merge(issue(suffix).native_ref, %{"number" => 42, "id" => 4_242, "node_id" => "I_42"})}

    {:ok, remote} = Agent.start_link(fn -> %{remote_state() | issue_body: issue_body} end)

    Application.put_env(:symphony_elixir, :github_client_module, FakeGitHubClient)

    Application.put_env(
      :symphony_elixir,
      :github_attempt_ledger_module,
      ReservationErrorRealDeactivationLedger
    )

    Application.put_env(:symphony_elixir, :attempt_fuse_test_issue, issue)
    Application.put_env(:symphony_elixir, :attempt_fuse_test_pid, self())
    Application.put_env(:symphony_elixir, :attempt_fuse_remote, remote)

    try do
      write_github_attempt_workflow!(workflow_path, root, available_port())
      assert :ok = WorkflowStore.force_reload()
      File.rm_rf!(Path.join(root, "host-state"))

      assert {:ok, runtime_pid} =
               SymphonyElixir.AgentRuntimeSupervisor.start_link(
                 name: runtime_name,
                 orchestrator_name: orchestrator_name,
                 task_supervisor_name: Module.concat(__MODULE__, "MalformedConfirmTasks#{suffix}"),
                 instance_lock_name: lock_name
               )

      Process.unlink(runtime_pid)
      assert_receive {:attempt_reserve_called, "42", 5}, 3_000

      assert eventually_value(fn ->
               if InstanceLock.operational?(lock_name) == false, do: :tripped
             end) == :tripped

      assert :sys.get_state(orchestrator_name).dispatch_suspended
      refute_receive {:attempt_reserve_called, "42", 5}, 100
    after
      if pid = Process.whereis(runtime_name), do: GenServer.stop(pid)
      if Process.alive?(remote), do: Agent.stop(remote)
      File.rm_rf(root)
    end
  end

  defp run_fifth_boundary_scenario(mode) do
    suffix = System.unique_integer([:positive])
    root = Path.join(canonical_tmp_dir(), "symphony-fifth-boundary-#{mode}-#{suffix}")
    workflow_path = Workflow.workflow_file_path()
    runtime_name = Module.concat(__MODULE__, "FifthRuntime#{suffix}")
    orchestrator_name = Module.concat(__MODULE__, "FifthOrchestrator#{suffix}")

    issue =
      %{issue(suffix) | id: "42", identifier: "GH-42", native_ref: Map.merge(issue(suffix).native_ref, %{"number" => 42, "id" => 4_242, "node_id" => "I_42"})}

    {:ok, remote} = Agent.start_link(fn -> remote_state() end)
    {:ok, starter_state} = Agent.start_link(fn -> 0 end)

    stop_default_runtime!()
    Application.put_env(:symphony_elixir, :github_client_module, FakeGitHubClient)
    Application.put_env(:symphony_elixir, :github_attempt_ledger_module, RecordingAttemptLedger)
    Application.put_env(:symphony_elixir, :agent_runner_module, FifthBoundaryRunner)
    Application.put_env(:symphony_elixir, :attempt_fuse_test_issue, issue)
    Application.put_env(:symphony_elixir, :attempt_fuse_test_pid, self())
    Application.put_env(:symphony_elixir, :attempt_fuse_remote, remote)
    Application.put_env(:symphony_elixir, :fifth_boundary_mode, mode)
    Application.put_env(:symphony_elixir, :attempt_fuse_task_starter_state, starter_state)

    if mode == :spawn_failure do
      Application.put_env(:symphony_elixir, :task_starter_module, FailOnFifthTaskStarter)
    end

    on_exit(fn ->
      if pid = Process.whereis(runtime_name), do: GenServer.stop(pid)
      if Process.alive?(remote), do: Agent.stop(remote)
      if Process.alive?(starter_state), do: Agent.stop(starter_state)

      for key <- [
            :github_client_module,
            :github_attempt_ledger_module,
            :agent_runner_module,
            :attempt_fuse_test_issue,
            :attempt_fuse_test_pid,
            :attempt_fuse_remote,
            :fifth_boundary_mode,
            :attempt_fuse_task_starter_state,
            :task_starter_module
          ] do
        Application.delete_env(:symphony_elixir, key)
      end

      write_workflow_file!(workflow_path, tracker_kind: "memory")
      restart_default_runtime!()
      File.rm_rf(root)
    end)

    write_github_attempt_workflow!(workflow_path, root, available_port(), stall_timeout_ms: 1)
    assert :ok = WorkflowStore.force_reload()

    assert {:ok, runtime_pid} =
             SymphonyElixir.AgentRuntimeSupervisor.start_link(
               name: runtime_name,
               orchestrator_name: orchestrator_name,
               task_supervisor_name: Module.concat(__MODULE__, "FifthTasks#{suffix}"),
               instance_lock_name: Module.concat(__MODULE__, "FifthLock#{suffix}")
             )

    Process.unlink(runtime_pid)

    for attempt <- 1..4 do
      assert_next_event({:attempt_reserved, attempt})
      assert_next_event({:worker_started, attempt})
      force_retry(orchestrator_name, issue.id)
    end

    assert_next_event({:attempt_reserved, 5})

    if mode != :spawn_failure do
      assert_next_event({:worker_started, 5})
    end

    assert_receive {:attempt_deactivated, {:ok, %{deactivated: true}}}, 3_000
    refute_receive {:attempt_reserved, 6}, 100
    refute_receive {:worker_started, 6}, 0

    assert %{running: [], retrying: [], blocked: [%{attempt_usage: %{used: 5, exhausted: true}}]} =
             Orchestrator.snapshot(orchestrator_name, 1_000)

    snapshot = Agent.get(remote, & &1)
    assert Enum.count(snapshot.comments, &String.starts_with?(&1["body"], @attempt_marker)) == 5
    assert Enum.count(snapshot.comments, &String.starts_with?(&1["body"], @exhaustion_marker)) == 1
    refute "pilot:symphony" in snapshot.labels
  end
end
