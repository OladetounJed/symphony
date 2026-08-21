defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single tracker work item in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.{AttemptFuse, Config, PromptBuilder, Tracker}
  alias SymphonyElixir.Tracker.Issue

  @type worker_host :: String.t() | nil

  @doc false
  @spec continue_with_issue_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:continue, Issue.t()} | {:done, Issue.t()} | {:error, term()}
  def continue_with_issue_for_test(%Issue{} = issue, issue_state_fetcher)
      when is_function(issue_state_fetcher, 1) do
    continue_with_issue?(issue, issue_state_fetcher)
  end

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    attempt_fuse = Keyword.get(opts, :attempt_fuse)
    execution_settings = execution_settings(attempt_fuse)

    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host =
      selected_worker_host(
        Keyword.get(opts, :worker_host),
        execution_settings.worker.ssh_hosts
      )

    opts = Keyword.put(opts, :execution_settings, execution_settings)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    attempt_fuse = Keyword.get(opts, :attempt_fuse)

    with :ok <- validate_attempt_fuse(attempt_fuse),
         {:ok, workspace} <- workspace_module().create_for_issue(issue, worker_host, attempt_fuse) do
      send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

      try do
        with :ok <-
               workspace_module().run_before_run_hook(
                 workspace,
                 issue,
                 worker_host,
                 attempt_fuse
               ),
             :ok <- validate_attempt_fuse(attempt_fuse) do
          run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host)
        end
      after
        workspace_module().run_after_run_hook(workspace, issue, worker_host, attempt_fuse)
      end
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp codex_message_handler(recipient, issue) do
    fn message ->
      send_codex_update(recipient, issue, message)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    execution_settings = Keyword.fetch!(opts, :execution_settings)
    max_turns = Keyword.get(opts, :max_turns, execution_settings.agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issues_by_ids/1)

    session_options =
      [worker_host: worker_host]
      |> Keyword.put(:attempt_fuse, Keyword.get(opts, :attempt_fuse))
      |> Keyword.put(:dynamic_tool_binding, Keyword.get(opts, :dynamic_tool_binding))
      |> Keyword.put(:execution_settings, execution_settings)

    app_server = app_server_module()
    opts = Keyword.put(opts, :app_server_module, app_server)

    with {:ok, session} <- app_server.start_session(workspace, session_options) do
      try do
        do_run_codex_turns(
          session,
          workspace,
          issue,
          codex_update_recipient,
          opts,
          issue_state_fetcher,
          1,
          max_turns
        )
      after
        app_server.stop_session(session)
      end
    end
  end

  defp validate_attempt_fuse(nil), do: :ok
  defp validate_attempt_fuse(attempt_fuse) when is_map(attempt_fuse), do: AttemptFuse.validate_current(attempt_fuse)

  defp do_run_codex_turns(
         app_session,
         workspace,
         issue,
         codex_update_recipient,
         opts,
         issue_state_fetcher,
         turn_number,
         max_turns
       ) do
    app_server = Keyword.fetch!(opts, :app_server_module)
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)

    with {:ok, turn_session} <-
           app_server.run_turn(
             app_session,
             prompt,
             issue,
             on_message: codex_message_handler(codex_update_recipient, issue)
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      continuation =
        with :ok <- validate_attempt_fuse(Keyword.get(opts, :attempt_fuse)) do
          continue_with_issue?(
            issue,
            issue_state_fetcher,
            Keyword.fetch!(opts, :execution_settings)
          )
        end

      case continuation do
        {:continue, refreshed_issue} when turn_number < max_turns ->
          Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

          do_run_codex_turns(
            app_session,
            workspace,
            refreshed_issue,
            codex_update_recipient,
            opts,
            issue_state_fetcher,
            turn_number + 1,
            max_turns
          )

        {:continue, refreshed_issue} ->
          Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

          :ok

        {:done, _refreshed_issue} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns), do: PromptBuilder.build_prompt(issue, opts)

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the tracker work item is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp continue_with_issue?(issue, issue_state_fetcher),
    do: continue_with_issue?(issue, issue_state_fetcher, Config.settings!())

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher, settings)
       when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state, settings) and
             issue_routable?(refreshed_issue, settings) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher, _settings), do: {:done, issue}

  defp active_issue_state?(state_name, settings) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    settings.tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name, _settings), do: false

  defp issue_routable?(%Issue{} = issue, settings) do
    Issue.routable?(issue, settings.tracker.required_labels)
  end

  defp execution_settings(%{enabled: true, execution_settings: settings}), do: settings
  defp execution_settings(_attempt_fuse), do: Config.settings!()

  defp workspace_module do
    Application.get_env(:symphony_elixir, :workspace_module, SymphonyElixir.Workspace)
  end

  defp app_server_module do
    Application.get_env(:symphony_elixir, :codex_app_server_module, SymphonyElixir.Codex.AppServer)
  end

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
