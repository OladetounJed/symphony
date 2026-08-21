defmodule SymphonyElixir.AttemptFuse do
  @moduledoc """
  Freezes and validates the configuration that defines one attempt budget.

  An enabled fuse is immutable for the lifetime of its host-local instance
  lock. Workflow reloads may change unrelated runtime settings, but any fuse
  drift is rejected before dispatch.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema

  @type snapshot :: %{
          enabled: boolean(),
          max_attempts: pos_integer() | nil,
          instance_lock_port: pos_integer() | nil,
          tracker_settings: map() | struct(),
          workspace_root: String.t()
        }

  @spec snapshot(Schema.t()) :: snapshot()
  def snapshot(%Schema{} = settings) do
    %{
      enabled: is_integer(settings.agent.max_attempts),
      max_attempts: settings.agent.max_attempts,
      instance_lock_port: settings.agent.instance_lock_port,
      tracker_settings: settings.tracker,
      workspace_root: settings.workspace.root
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
