defmodule SymphonyElixir.GitHub.Adapter do
  @moduledoc """
  GitHub Issues-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.GitHub.{AgentTool, AttemptLedger, Client}
  alias SymphonyElixir.Tracker.Issue

  @active_states ["open"]
  @terminal_states ["closed"]

  @impl true
  @spec validate_config(map()) :: :ok | {:error, term()}
  def validate_config(tracker_settings) do
    with :ok <-
           validate_states(
             tracker_settings.active_states,
             @active_states,
             :missing_github_active_states
           ),
         :ok <-
           validate_states(
             tracker_settings.terminal_states,
             @terminal_states,
             :missing_github_terminal_states
           ),
         :ok <- Client.validate_settings(tracker_settings) do
      AttemptLedger.validate_settings(tracker_settings)
    end
  end

  @impl true
  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @impl true
  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(issue_ids), do: client_module().fetch_issues_by_ids(issue_ids)

  @impl true
  @spec agent_tool_specs() :: [map()]
  def agent_tool_specs, do: AgentTool.tool_specs()

  @impl true
  @spec execute_agent_tool(String.t(), term(), keyword()) :: map()
  def execute_agent_tool(tool, arguments, opts), do: AgentTool.execute(tool, arguments, opts)

  @impl true
  @spec reserve_attempt(Issue.t(), pos_integer()) ::
          {:ok, map()} | {:exhausted, map()} | {:error, term()}
  def reserve_attempt(%Issue{} = issue, max_attempts) do
    attempt_ledger_module().reserve(issue, max_attempts)
  end

  @impl true
  @spec deactivate_attempts(Issue.t(), map()) :: {:ok, map()} | {:error, term()}
  def deactivate_attempts(%Issue{} = issue, evidence) do
    attempt_ledger_module().deactivate(issue, evidence)
  end

  @impl true
  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(tracker_settings), do: Client.secret_environment_names(tracker_settings)

  defp client_module do
    Application.get_env(:symphony_elixir, :github_client_module, Client)
  end

  defp attempt_ledger_module do
    Application.get_env(:symphony_elixir, :github_attempt_ledger_module, AttemptLedger)
  end

  defp validate_states(states, allowed_states, _missing_error) when is_list(states) do
    if Enum.all?(states, &(normalize_state(&1) in allowed_states)) do
      :ok
    else
      {:error, :invalid_github_states}
    end
  end

  defp validate_states(_states, _allowed_states, missing_error), do: {:error, missing_error}

  defp normalize_state(state) when is_binary(state), do: state |> String.trim() |> String.downcase()
  defp normalize_state(_state), do: ""
end
