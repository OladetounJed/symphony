defmodule SymphonyElixir.WorkerRuntimeSupervisor do
  @moduledoc false

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    task_supervisor_name =
      Keyword.get(opts, :task_supervisor, SymphonyElixir.TaskSupervisor)

    orchestrator_name = Keyword.get(opts, :orchestrator_name, SymphonyElixir.Orchestrator)
    instance_lock_name = Keyword.get(opts, :instance_lock_name, SymphonyElixir.InstanceLock)

    orchestrator_options = [
      name: orchestrator_name,
      task_supervisor: task_supervisor_name,
      instance_lock_name: instance_lock_name
    ]

    children = [
      Supervisor.child_spec(
        {Task.Supervisor, name: task_supervisor_name},
        id: task_supervisor_name
      ),
      Supervisor.child_spec(
        {SymphonyElixir.Orchestrator, orchestrator_options},
        id: orchestrator_name
      )
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
