defmodule SymphonyElixir.AttemptFuse do
  @moduledoc """
  Freezes and validates the configuration that defines one attempt budget.

  The complete worker execution profile is immutable for the lifetime of an
  enabled fuse so repository hooks cannot expand executor authority by
  rewriting the workflow after a durable reservation.
  """

  alias SymphonyElixir.{Config, Workflow}
  alias SymphonyElixir.Config.Schema

  @type snapshot :: %{
          enabled: boolean(),
          max_attempts: pos_integer() | nil,
          instance_lock_port: pos_integer() | nil,
          tracker_settings: map() | struct(),
          workspace_root: String.t(),
          execution_settings: Schema.t()
        }

  @spec snapshot(Schema.t()) :: snapshot()
  def snapshot(%Schema{} = settings) do
    workflow_directory =
      Workflow.workflow_file_path()
      |> Path.expand()
      |> Path.dirname()

    %{
      enabled: is_integer(settings.agent.max_attempts),
      max_attempts: settings.agent.max_attempts,
      instance_lock_port: settings.agent.instance_lock_port,
      tracker_settings: settings.tracker,
      workspace_root: Path.expand(settings.workspace.root, workflow_directory),
      execution_settings: settings
    }
  end

  @spec current_snapshot() :: snapshot()
  def current_snapshot, do: Config.settings!() |> snapshot()

  @spec validate_current(snapshot()) :: :ok | {:error, :attempt_fuse_config_drift}
  def validate_current(%{enabled: false}) do
    if current_snapshot().enabled do
      {:error, :attempt_fuse_config_drift}
    else
      :ok
    end
  end

  def validate_current(%{} = frozen) do
    if current_snapshot() == frozen, do: :ok, else: {:error, :attempt_fuse_config_drift}
  end
end
