defmodule SymphonyElixir.AgentRuntimeSupervisor do
  @moduledoc """
  Supervises the scheduler authority together with its agent tasks.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    task_supervisor_name =
      Keyword.get(opts, :task_supervisor_name, SymphonyElixir.TaskSupervisor)

    orchestrator_name = Keyword.get(opts, :orchestrator_name, SymphonyElixir.Orchestrator)
    instance_lock_name = Keyword.get(opts, :instance_lock_name, SymphonyElixir.InstanceLock)

    worker_runtime_name =
      Keyword.get_lazy(opts, :worker_runtime_name, fn -> worker_runtime_name(opts) end)

    worker_runtime_options = [
      name: worker_runtime_name,
      orchestrator_name: orchestrator_name,
      task_supervisor: task_supervisor_name,
      instance_lock_name: instance_lock_name
    ]

    children = [
      Supervisor.child_spec(
        {SymphonyElixir.InstanceLock, name: instance_lock_name},
        id: instance_lock_name
      ),
      Supervisor.child_spec(
        {SymphonyElixir.WorkerRuntimeSupervisor, worker_runtime_options},
        id: worker_runtime_name
      )
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  defp worker_runtime_name(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      __MODULE__ -> SymphonyElixir.WorkerRuntimeSupervisor
      name when is_atom(name) -> Module.concat(name, WorkerRuntimeSupervisor)
    end
  end
end
