defmodule SymphonyElixir.InstanceLockTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.InstanceLock

  defmodule EmptyGitHubClient do
    def fetch_issues_by_states(_states), do: {:ok, []}
    def fetch_issues_by_ids(_ids), do: {:ok, []}
  end

  test "only one host-local runtime can hold the configured loopback lock" do
    Process.flag(:trap_exit, true)

    port = available_port()
    first_name = Module.concat(__MODULE__, "First#{System.unique_integer([:positive])}")
    second_name = Module.concat(__MODULE__, "Second#{System.unique_integer([:positive])}")

    assert {:ok, first} = InstanceLock.start_link(port: port, name: first_name)

    assert {:error, {:instance_lock_unavailable, ^port, :eaddrinuse}} =
             InstanceLock.start_link(port: port, name: second_name)

    GenServer.stop(first)
    assert {:ok, second} = InstanceLock.start_link(port: port, name: second_name)
    GenServer.stop(second)
  end

  test "a missing lock setting preserves upstream operation and invalid values fail" do
    assert :ignore = InstanceLock.start_link()
    assert :ignore = InstanceLock.start_link(port: nil)
    assert {:error, :invalid_instance_lock_port} = InstanceLock.start_link(port: 0)
    assert {:error, :invalid_instance_lock_port} = InstanceLock.start_link(port: 70_000)
  end

  test "a second full agent runtime cannot reach its poller while the singleton is held" do
    Process.flag(:trap_exit, true)
    suffix = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "symphony-full-runtime-lock-#{suffix}")
    port = available_port()
    workflow_path = Workflow.workflow_file_path()
    first_runtime = Module.concat(__MODULE__, "FirstRuntime#{suffix}")
    first_lock = Module.concat(__MODULE__, "FirstLock#{suffix}")
    first_orchestrator = Module.concat(__MODULE__, "FirstOrchestrator#{suffix}")
    first_tasks = Module.concat(__MODULE__, "FirstTasks#{suffix}")
    second_runtime = Module.concat(__MODULE__, "SecondRuntime#{suffix}")
    second_lock = Module.concat(__MODULE__, "SecondLock#{suffix}")
    second_orchestrator = Module.concat(__MODULE__, "SecondOrchestrator#{suffix}")

    Application.put_env(:symphony_elixir, :github_client_module, EmptyGitHubClient)
    write_attempt_workflow!(workflow_path, root, port)
    assert :ok = WorkflowStore.force_reload()

    on_exit(fn ->
      if pid = Process.whereis(first_runtime), do: GenServer.stop(pid)
      if pid = Process.whereis(second_runtime), do: GenServer.stop(pid)
      Application.delete_env(:symphony_elixir, :github_client_module)
      write_workflow_file!(workflow_path, tracker_kind: "memory")
      File.rm_rf(root)
    end)

    assert {:ok, first_pid} =
             SymphonyElixir.AgentRuntimeSupervisor.start_link(
               name: first_runtime,
               instance_lock_name: first_lock,
               orchestrator_name: first_orchestrator,
               task_supervisor_name: first_tasks
             )

    Process.unlink(first_pid)

    lock_error =
      {:shutdown, {:failed_to_start_child, second_lock, {:instance_lock_unavailable, port, :eaddrinuse}}}

    assert {:error, ^lock_error} =
             SymphonyElixir.AgentRuntimeSupervisor.start_link(
               name: second_runtime,
               instance_lock_name: second_lock,
               orchestrator_name: second_orchestrator,
               task_supervisor_name: Module.concat(__MODULE__, "SecondTasks#{suffix}")
             )

    assert is_nil(Process.whereis(second_orchestrator))
    assert is_pid(Process.whereis(first_orchestrator))
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

      Full runtime singleton test.
      """
    )
  end
end
