defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Dispatches client-side tool calls to the configured tracker adapter.
  """

  alias SymphonyElixir.Tracker

  @spec execute(String.t() | nil, term(), map(), keyword()) :: map()
  def execute(tool, arguments, binding, opts \\ []) do
    Tracker.execute_bound_agent_tool(binding, tool, arguments, opts)
  end

  @spec bind(map() | struct()) :: map()
  def bind(tracker_settings \\ SymphonyElixir.Config.settings!().tracker) do
    Tracker.bind_agent_tools(tracker_settings)
  end
end
