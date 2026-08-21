defmodule SymphonyElixir.GitHub.AttemptLedger do
  @moduledoc """
  Durable, host-owned GitHub issue attempt reservations.

  The ledger is authoritative only for a configured immutable GitHub bot/App
  identity. A host-local high-water file can veto a regressed remote history,
  but it never authorizes a worker start by itself.
  """

  import Bitwise, only: [band: 2]

  alias SymphonyElixir.GitHub.Client
  alias SymphonyElixir.PathSafety
  alias SymphonyElixir.Tracker.Issue

  @attempt_marker "<!-- iwe-symphony-attempt:v1 -->\n"
  @exhaustion_marker "<!-- iwe-symphony-exhaustion:v1 -->\n"
  @reserved_marker_prefix "<!-- iwe-symphony-"
  @page_size 100
  @max_pages 10
  @revision_pattern ~r/^[0-9a-f]{40}$/
  @reservation_pattern ~r/^[A-Za-z0-9_-]{22}$/
  @digest_pattern ~r/^[0-9a-f]{64}$/

  @type evidence :: %{
          used: non_neg_integer(),
          max: pos_integer(),
          remaining: non_neg_integer(),
          exhausted: boolean(),
          reservation_id: String.t() | nil,
          evidence_url: String.t() | nil,
          tip_comment_id: pos_integer() | nil,
          tip_digest: String.t() | nil,
          observed_at: String.t()
        }

  defmodule DurableFileOps do
    @moduledoc false

    @spec sync(:file.io_device()) :: :ok | {:error, term()}
    def sync(file), do: :file.sync(file)

    @spec sync_directory(Path.t()) :: :ok | {:error, term()}
    def sync_directory(path) do
      case :file.open(String.to_charlist(path), [:read, :raw, :directory]) do
        {:ok, directory} ->
          result = :file.sync(directory)
          close_result = :file.close(directory)
          if result == :ok, do: close_result, else: result

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @spec validate_settings(map()) :: :ok | {:error, term()}
  def validate_settings(tracker_settings) when is_map(tracker_settings) do
    provider = provider_settings(tracker_settings)

    case provider["attempt_ledger"] do
      nil ->
        :ok

      %{} = raw_settings ->
        with :ok <- validate_agent_tool_setting(provider),
             :ok <- validate_official_api_url(provider),
             {:ok, _settings} <- normalize_ledger_settings(raw_settings, false) do
          :ok
        end

      _ ->
        {:error, :invalid_github_attempt_ledger}
    end
  end

  @spec reserve(Issue.t(), pos_integer(), map()) ::
          {:ok, evidence()} | {:exhausted, evidence()} | {:error, term()}
  def reserve(
        %Issue{} = issue,
        max_attempts,
        %{tracker_settings: tracker_settings, workspace_root: workspace_root}
      )
      when is_integer(max_attempts) and max_attempts > 0 and is_map(tracker_settings) and
             is_binary(workspace_root) do
    reserve_with(
      issue,
      max_attempts,
      tracker_settings,
      &Client.request/5,
      workspace_root: workspace_root
    )
  end

  @spec deactivate(Issue.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def deactivate(
        %Issue{} = issue,
        evidence,
        %{tracker_settings: tracker_settings, workspace_root: workspace_root}
      )
      when is_map(evidence) and is_map(tracker_settings) and is_binary(workspace_root) do
    deactivate_with(
      issue,
      evidence,
      tracker_settings,
      &Client.request/5,
      workspace_root: workspace_root
    )
  end

  @doc false
  @spec reserve_for_test(Issue.t(), pos_integer(), map(), function(), keyword()) ::
          {:ok, evidence()} | {:exhausted, evidence()} | {:error, term()}
  def reserve_for_test(issue, max_attempts, tracker_settings, request_fun, opts \\ []) do
    reserve_with(issue, max_attempts, tracker_settings, request_fun, opts)
  end

  @doc false
  @spec deactivate_for_test(Issue.t(), map(), map(), function(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def deactivate_for_test(issue, evidence, tracker_settings, request_fun, opts \\ []) do
    deactivate_with(issue, evidence, tracker_settings, request_fun, opts)
  end

  defp reserve_with(issue, max_attempts, tracker_settings, request_fun, opts) do
    with {:ok, settings} <- runtime_settings(tracker_settings, opts),
         {:ok, context} <- issue_context(issue, settings, max_attempts, tracker_settings),
         :ok <- ensure_not_quarantined(context),
         {:ok, comments} <- fetch_all_comments(context, tracker_settings, request_fun),
         {:ok, ledger} <- validate_ledger(comments, context),
         {:ok, local_state} <- reconcile_high_water(context, ledger) do
      cond do
        ledger.used >= max_attempts ->
          {:exhausted, evidence(ledger, max_attempts)}

        is_map(local_state["pending"]) ->
          continue_pending_reservation(
            context,
            ledger,
            local_state,
            tracker_settings,
            request_fun
          )

        true ->
          begin_reservation(context, ledger, local_state, tracker_settings, request_fun)
      end
    end
  end

  defp deactivate_with(issue, evidence, tracker_settings, request_fun, opts) do
    result =
      with {:ok, max_attempts} <- evidence_max(evidence),
           {:ok, settings} <-
             base_runtime_settings(tracker_settings, Keyword.put(opts, :allow_disabled, true)),
           {:ok, remote_context} <-
             issue_context(issue, %{settings | high_water_root: nil}, max_attempts, tracker_settings) do
        quarantine_result =
          with {:ok, local_settings} <- prepare_runtime_root(settings, opts),
               {:ok, local_context} <-
                 issue_context(issue, local_settings, max_attempts, tracker_settings) do
            write_quarantine(local_context, evidence)
          end

        exhaustion_result =
          ensure_exhaustion_evidence(
            remote_context,
            evidence,
            tracker_settings,
            request_fun
          )

        delete_result = remove_activation_label(remote_context, tracker_settings, request_fun)

        confirmation_result =
          confirm_activation_label_absent(remote_context, tracker_settings, request_fun)

        {:classified,
         classify_deactivation(
           remote_context,
           quarantine_result,
           exhaustion_result,
           delete_result,
           confirmation_result
         )}
      end

    case result do
      {:classified, classified_result} -> classified_result
      {:error, reason} -> unfenced_preparation_error(reason)
    end
  end

  defp classify_deactivation(
         context,
         quarantine_result,
         exhaustion_result,
         delete_result,
         confirmation_result
       ) do
    case {quarantine_result, exhaustion_result, confirmation_result} do
      {:ok, {:ok, exhaustion}, :ok} ->
        {:ok,
         %{
           activation_label: context.activation_label,
           evidence_url: exhaustion[:evidence_url],
           deactivated: true
         }}

      {{:error, quarantine_reason}, {:ok, exhaustion}, :ok} ->
        {:error, {:deactivated_without_quarantine, quarantine_reason, exhaustion[:evidence_url]}}

      {:ok, {:error, evidence_reason}, :ok} ->
        {:error, {:deactivated_without_exhaustion_evidence, evidence_reason}}

      {{:error, quarantine_reason}, {:error, evidence_reason}, :ok} ->
        {:error, {:deactivated_without_local_or_exhaustion_evidence, quarantine_reason, evidence_reason}}

      {{:error, quarantine_reason}, evidence_result, {:error, confirmation_reason}} ->
        unfenced =
          {:attempt_deactivation_unfenced, quarantine_reason, delete_result, confirmation_reason, evidence_result}

        {:error, unfenced}

      {:ok, evidence_result, {:error, confirmation_reason}} ->
        {:error, {:attempt_deactivation_failed, delete_result, confirmation_reason, evidence_result}}
    end
  end

  defp unfenced_preparation_error(reason) do
    delete_result = :remote_delete_not_attempted
    confirmation_result = :remote_confirmation_not_attempted
    evidence_result = {:error, :remote_evidence_not_attempted}

    unfenced =
      {:attempt_deactivation_unfenced, reason, delete_result, confirmation_result, evidence_result}

    {:error, unfenced}
  end

  defp begin_reservation(context, ledger, local_state, tracker_settings, request_fun) do
    reservation = build_reservation(context, ledger)
    pending_state = Map.put(local_state, "pending", reservation)

    with :ok <- write_high_water(context, pending_state) do
      post_and_confirm(context, ledger, pending_state, tracker_settings, request_fun)
    end
  end

  defp continue_pending_reservation(
         context,
         ledger,
         local_state,
         tracker_settings,
         request_fun
       ) do
    pending = local_state["pending"]

    case Enum.filter(ledger.entries, &(&1.data["reservation_id"] == pending["reservation_id"])) do
      [entry] ->
        finalize_reservation(context, ledger, local_state, entry)

      [] ->
        post_and_confirm(context, ledger, local_state, tracker_settings, request_fun)

      _ ->
        {:error, :github_attempt_duplicate_reservation}
    end
  end

  defp post_and_confirm(context, _ledger, local_state, tracker_settings, request_fun) do
    pending = local_state["pending"]
    body = pending["body"]

    post_result =
      github_request(
        "POST",
        comments_path(context),
        %{},
        %{"body" => body},
        tracker_settings,
        request_fun
      )

    response_comment_id = posted_comment_id(post_result)

    with {:ok, comments} <- fetch_all_comments(context, tracker_settings, request_fun),
         {:ok, confirmed_ledger} <- validate_ledger(comments, context),
         [entry] <-
           Enum.filter(
             confirmed_ledger.entries,
             &(&1.data["reservation_id"] == pending["reservation_id"])
           ),
         :ok <- validate_post_response_id(response_comment_id, entry.comment_id) do
      finalize_reservation(context, confirmed_ledger, local_state, entry)
    else
      [] -> {:error, {:github_attempt_reservation_unconfirmed, pending["reservation_id"]}}
      entries when is_list(entries) -> {:error, :github_attempt_duplicate_reservation}
      {:error, reason} -> {:error, reason}
    end
  end

  defp finalize_reservation(context, ledger, local_state, entry) do
    expected_attempt = local_state["used"] + 1

    cond do
      entry.data["attempt"] != expected_attempt ->
        {:error, :github_attempt_pending_ordinal_mismatch}

      entry != List.last(ledger.entries) ->
        {:error, :github_attempt_pending_not_tip}

      true ->
        finalized_state = high_water_state(context, ledger, nil)

        with :ok <- write_high_water(context, finalized_state) do
          {:ok, evidence(ledger, context.max_attempts)}
        end
    end
  end

  defp reconcile_high_water(context, ledger) do
    with {:ok, local_state} <- read_high_water(context),
         :ok <- validate_high_water(local_state, context, ledger) do
      reconcile_high_water_state(context, ledger, local_state)
    end
  end

  defp reconcile_high_water_state(context, ledger, nil) do
    state = high_water_state(context, ledger, nil)

    with :ok <- write_high_water(context, state), do: {:ok, state}
  end

  defp reconcile_high_water_state(context, ledger, %{} = state),
    do: reconcile_existing_high_water(context, ledger, state)

  defp reconcile_existing_high_water(_context, ledger, state) do
    pending = state["pending"]

    cond do
      is_map(pending) and reservation_present?(ledger, pending["reservation_id"]) ->
        {:ok, state}

      is_map(pending) ->
        {:ok, state}

      ledger.used == state["used"] ->
        {:ok, state}

      true ->
        {:error, :github_attempt_ledger_advanced_without_pending_reservation}
    end
  end

  defp validate_high_water(nil, _context, _ledger), do: :ok

  defp validate_high_water(state, context, ledger) when is_map(state) do
    required_keys = [
      "issue_id",
      "max_attempts",
      "pending",
      "repository_id",
      "source_revision",
      "tip_comment_id",
      "tip_digest",
      "used"
    ]

    with :ok <- require_exact_keys(state, required_keys, :github_attempt_high_water_malformed),
         :ok <- validate_high_water_subject(state, context),
         :ok <- validate_high_water_policy(state, context),
         :ok <- require_non_negative_integer(state["used"], :github_attempt_high_water_malformed),
         :ok <- validate_high_water_count(state, ledger),
         :ok <- validate_high_water_tip(state, ledger) do
      validate_pending_state(state, context)
    end
  end

  defp validate_high_water_subject(state, context) do
    require_all_equal(
      [{state["repository_id"], context.repository_id}, {state["issue_id"], context.issue_id}],
      :github_attempt_high_water_subject_mismatch
    )
  end

  defp validate_high_water_policy(state, context) do
    require_all_equal(
      [
        {state["source_revision"], context.source_revision},
        {state["max_attempts"], context.max_attempts}
      ],
      :github_attempt_high_water_policy_mismatch
    )
  end

  defp validate_high_water_count(state, ledger),
    do: require_true(state["used"] <= ledger.used, :github_attempt_ledger_regressed)

  defp validate_high_water_tip(%{"used" => 0}, _ledger), do: :ok

  defp validate_high_water_tip(state, ledger),
    do: require_true(high_water_tip_present?(state, ledger), :github_attempt_ledger_regressed)

  defp validate_pending_state(%{"pending" => nil}, _context), do: :ok

  defp validate_pending_state(state, context) do
    require_true(
      valid_pending?(state["pending"], context, state),
      :github_attempt_high_water_pending_malformed
    )
  end

  defp high_water_tip_present?(state, ledger) do
    Enum.any?(ledger.entries, fn entry ->
      entry.comment_id == state["tip_comment_id"] and entry.digest == state["tip_digest"] and
        entry.data["attempt"] == state["used"]
    end)
  end

  defp valid_pending?(pending, context, state) when is_map(pending) do
    required_keys = ["attempt", "body", "reservation_id"]

    Enum.sort(Map.keys(pending)) == required_keys and
      pending["attempt"] == state["used"] + 1 and
      pending["attempt"] <= context.max_attempts and
      is_binary(pending["body"]) and
      Regex.match?(@reservation_pattern, pending["reservation_id"] || "") and
      pending["body"] == @attempt_marker <> canonical_json(reservation_data_from_body(pending["body"]))
  rescue
    _ -> false
  end

  defp valid_pending?(_pending, _context, _state), do: false

  defp read_high_water(context) do
    read_local_json(
      context.high_water_path,
      :github_attempt_high_water_malformed,
      :github_attempt_high_water_read
    )
  end

  defp write_high_water(context, state) when is_map(state) do
    write_local_json(
      context.high_water_path,
      state,
      :github_attempt_high_water_target,
      :github_attempt_high_water_write
    )
  end

  defp ensure_not_quarantined(context) do
    case read_quarantine(context) do
      {:ok, nil} ->
        :ok

      {:ok, quarantine} ->
        with :ok <- validate_quarantine(quarantine, context), do: {:error, :github_attempt_quarantined}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_quarantine(context) do
    read_local_json(
      context.quarantine_path,
      :github_attempt_quarantine_malformed,
      :github_attempt_quarantine_read
    )
  end

  defp write_quarantine(context, evidence) do
    case read_quarantine(context) do
      {:ok, nil} ->
        quarantine = quarantine_state(context, evidence)

        write_local_json(
          context.quarantine_path,
          quarantine,
          :github_attempt_quarantine_target,
          :github_attempt_quarantine_write
        )

      {:ok, quarantine} ->
        validate_quarantine(quarantine, context)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp quarantine_state(context, evidence) do
    %{
      "schema" => 1,
      "repository_id" => context.repository_id,
      "issue_id" => context.issue_id,
      "source_revision" => context.source_revision,
      "max_attempts" => context.max_attempts,
      "reason" => to_string(evidence_value(evidence, :reason, "reason", "attempt_dispatch_blocked")),
      "created_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }
  end

  defp validate_quarantine(quarantine, context) when is_map(quarantine) do
    required_keys = [
      "created_at",
      "issue_id",
      "max_attempts",
      "reason",
      "repository_id",
      "schema",
      "source_revision"
    ]

    with :ok <- require_exact_keys(quarantine, required_keys, :github_attempt_quarantine_malformed),
         :ok <- require_equal(quarantine["schema"], 1, :github_attempt_quarantine_malformed),
         :ok <-
           require_all_equal(
             [
               {quarantine["repository_id"], context.repository_id},
               {quarantine["issue_id"], context.issue_id},
               {quarantine["source_revision"], context.source_revision},
               {quarantine["max_attempts"], context.max_attempts}
             ],
             :github_attempt_quarantine_subject_mismatch
           ),
         :ok <- require_true(present_string?(quarantine["reason"]), :github_attempt_quarantine_malformed) do
      require_true(present_string?(quarantine["created_at"]), :github_attempt_quarantine_malformed)
    end
  end

  defp read_local_json(path, malformed_reason, read_reason) do
    with :ok <- validate_local_target(path, malformed_reason) do
      case File.read(path) do
        {:ok, data} ->
          decode_local_json(data, malformed_reason)

        {:error, :enoent} ->
          {:ok, nil}

        {:error, reason} ->
          {:error, {read_reason, reason}}
      end
    end
  end

  defp decode_local_json(data, malformed_reason) do
    case Jason.decode(data) do
      {:ok, state} when is_map(state) -> {:ok, state}
      _ -> {:error, malformed_reason}
    end
  end

  defp write_local_json(path, state, target_reason, write_reason) do
    suffix = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
    temporary_path = path <> ".#{suffix}.tmp"
    encoded = Jason.encode!(state)

    with :ok <- validate_local_target(path, target_reason),
         :ok <- write_synced_temporary(temporary_path, encoded),
         :ok <- File.rename(temporary_path, path),
         :ok <- sync_directory(Path.dirname(path)),
         :ok <- validate_local_target(path, target_reason) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(temporary_path)
        {:error, normalize_local_write_error(reason, write_reason)}
    end
  end

  defp write_synced_temporary(path, encoded) do
    case :file.open(String.to_charlist(path), [:write, :exclusive, :binary, :raw]) do
      {:ok, file} ->
        result =
          with :ok <- :file.write(file, encoded),
               :ok <- File.chmod(path, 0o600) do
            durable_file_ops().sync(file)
          end

        close_result = :file.close(file)
        if result == :ok, do: close_result, else: result

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp sync_directory(path) do
    durable_file_ops().sync_directory(path)
  end

  defp durable_file_ops do
    Application.get_env(:symphony_elixir, :attempt_ledger_file_ops, DurableFileOps)
  end

  defp validate_local_target(path, reason) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} when band(mode, 0o077) == 0 -> :ok
      {:ok, _stat} -> {:error, reason}
      {:error, :enoent} -> :ok
      {:error, file_reason} -> {:error, file_reason}
    end
  end

  defp normalize_local_write_error(reason, _write_reason)
       when reason in [:github_attempt_high_water_target, :github_attempt_quarantine_target],
       do: reason

  defp normalize_local_write_error(reason, write_reason), do: {write_reason, reason}

  defp high_water_state(context, ledger, pending) do
    %{
      "repository_id" => context.repository_id,
      "issue_id" => context.issue_id,
      "source_revision" => context.source_revision,
      "max_attempts" => context.max_attempts,
      "used" => ledger.used,
      "tip_comment_id" => ledger.tip && ledger.tip.comment_id,
      "tip_digest" => ledger.tip && ledger.tip.digest,
      "pending" => pending
    }
  end

  defp build_reservation(context, ledger) do
    reservation_id = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

    data = %{
      "schema" => 1,
      "repository" => context.repo,
      "repository_id" => context.repository_id,
      "issue_id" => context.issue_id,
      "issue_node_id" => context.issue_node_id,
      "issue_number" => context.issue_number,
      "attempt" => ledger.used + 1,
      "max_attempts" => context.max_attempts,
      "reservation_id" => reservation_id,
      "previous_comment_id" => ledger.tip && ledger.tip.comment_id,
      "previous_digest" => ledger.tip && ledger.tip.digest,
      "source_revision" => context.source_revision
    }

    %{
      "attempt" => data["attempt"],
      "reservation_id" => reservation_id,
      "body" => @attempt_marker <> canonical_json(data)
    }
  end

  defp fetch_all_comments(context, tracker_settings, request_fun) do
    fetch_comment_page(context, tracker_settings, request_fun, 1, [])
  end

  defp fetch_comment_page(_context, _tracker_settings, _request_fun, page, _acc)
       when page > @max_pages do
    {:error, :github_attempt_comments_page_limit}
  end

  defp fetch_comment_page(context, tracker_settings, request_fun, page, acc) do
    params = %{"per_page" => @page_size, "page" => page, "sort" => "created", "direction" => "asc"}

    case github_request(
           "GET",
           comments_path(context),
           params,
           nil,
           tracker_settings,
           request_fun
         ) do
      {:ok, %{status: 200, body: comments}} when is_list(comments) ->
        continue_comment_pagination(
          comments,
          context,
          tracker_settings,
          request_fun,
          page,
          acc
        )

      {:ok, %{status: status}} when is_integer(status) ->
        {:error, {:github_attempt_comments_status, status}}

      {:error, reason} ->
        {:error, {:github_attempt_comments_request, reason}}
    end
  end

  defp continue_comment_pagination(comments, _context, _tracker_settings, _request_fun, _page, _acc)
       when length(comments) > @page_size do
    {:error, :github_attempt_comments_page_size}
  end

  defp continue_comment_pagination(comments, context, tracker_settings, request_fun, page, acc) do
    updated = acc ++ comments

    if length(comments) < @page_size do
      {:ok, updated}
    else
      fetch_comment_page(context, tracker_settings, request_fun, page + 1, updated)
    end
  end

  defp validate_ledger(comments, context) when is_list(comments) do
    with {:ok, entries, exhaustion_entries} <- collect_reserved_comments(comments, context),
         :ok <- validate_attempt_chain(entries, context),
         :ok <- validate_exhaustion_entries(exhaustion_entries, entries, context) do
      tip = List.last(entries)

      {:ok,
       %{
         entries: entries,
         exhaustion_entries: exhaustion_entries,
         tip: tip,
         used: length(entries)
       }}
    end
  end

  defp collect_reserved_comments(comments, context) do
    comments
    |> Enum.reduce_while({:ok, [], []}, &collect_reserved_comment(&1, &2, context))
    |> reverse_collected_comments()
  end

  defp collect_reserved_comment(comment, {:ok, attempts, exhaustions}, context) do
    case classify_reserved_comment(comment, context) do
      :ignore -> {:cont, {:ok, attempts, exhaustions}}
      {:attempt, entry} -> {:cont, {:ok, [entry | attempts], exhaustions}}
      {:exhaustion, entry} -> {:cont, {:ok, attempts, [entry | exhaustions]}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp classify_reserved_comment(%{"body" => body} = comment, context) when is_binary(body) do
    cond do
      not String.starts_with?(body, @reserved_marker_prefix) ->
        :ignore

      not trusted_comment?(comment, context) ->
        :ignore

      String.starts_with?(body, @attempt_marker) ->
        tagged_entry(:attempt, parse_attempt_comment(comment, context))

      String.starts_with?(body, @exhaustion_marker) ->
        tagged_entry(:exhaustion, parse_exhaustion_comment(comment, context))

      true ->
        {:error, :github_attempt_trusted_marker_malformed}
    end
  end

  defp classify_reserved_comment(_comment, _context), do: :ignore

  defp tagged_entry(tag, {:ok, entry}), do: {tag, entry}
  defp tagged_entry(_tag, {:error, reason}), do: {:error, reason}

  defp reverse_collected_comments({:ok, attempts, exhaustions}),
    do: {:ok, Enum.reverse(attempts), Enum.reverse(exhaustions)}

  defp reverse_collected_comments({:error, reason}), do: {:error, reason}

  defp parse_attempt_comment(comment, context) do
    with :ok <- validate_comment_metadata(comment),
         {:ok, data} <- parse_canonical_body(comment["body"], @attempt_marker),
         :ok <- validate_attempt_data(data, context),
         {:ok, comment_id} <- positive_integer(comment["id"]),
         true <- present_string?(comment["html_url"]) or {:error, :github_attempt_comment_url} do
      {:ok,
       %{
         comment_id: comment_id,
         evidence_url: comment["html_url"],
         body: comment["body"],
         digest: digest(comment["body"]),
         data: data
       }}
    end
  end

  defp validate_attempt_chain(entries, context) do
    Enum.reduce_while(Enum.with_index(entries, 1), {:ok, nil, MapSet.new()}, fn
      {entry, expected_attempt}, {:ok, previous, reservation_ids} ->
        case validate_attempt_entry(entry, expected_attempt, previous, reservation_ids, context) do
          :ok ->
            updated_ids = MapSet.put(reservation_ids, entry.data["reservation_id"])
            {:cont, {:ok, entry, updated_ids}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
    end)
    |> case do
      {:ok, _tip, _ids} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_attempt_entry(entry, expected_attempt, previous, reservation_ids, context) do
    with :ok <- require_true(expected_attempt <= context.max_attempts, :github_attempt_over_limit),
         :ok <- require_equal(entry.data["attempt"], expected_attempt, :github_attempt_ordinal_gap),
         :ok <-
           require_true(
             not MapSet.member?(reservation_ids, entry.data["reservation_id"]),
             :github_attempt_duplicate_reservation
           ),
         :ok <-
           require_true(
             valid_predecessor?(entry.data, previous),
             :github_attempt_predecessor_mismatch
           ) do
      validate_comment_order(entry, previous)
    end
  end

  defp validate_comment_order(_entry, nil), do: :ok

  defp validate_comment_order(entry, previous),
    do: require_true(entry.comment_id > previous.comment_id, :github_attempt_comment_order)

  defp validate_attempt_data(data, context) when is_map(data) do
    required_keys = [
      "attempt",
      "issue_id",
      "issue_node_id",
      "issue_number",
      "max_attempts",
      "previous_comment_id",
      "previous_digest",
      "repository",
      "repository_id",
      "reservation_id",
      "schema",
      "source_revision"
    ]

    with :ok <- require_exact_keys(data, required_keys, :github_attempt_fields),
         :ok <- require_equal(data["schema"], 1, :github_attempt_schema),
         :ok <- require_equal(data["repository"], context.repo, :github_attempt_repository),
         :ok <-
           require_equal(
             data["repository_id"],
             context.repository_id,
             :github_attempt_repository_id
           ),
         :ok <- require_equal(data["issue_id"], context.issue_id, :github_attempt_issue_id),
         :ok <-
           require_equal(
             data["issue_node_id"],
             context.issue_node_id,
             :github_attempt_issue_node_id
           ),
         :ok <-
           require_equal(
             data["issue_number"],
             context.issue_number,
             :github_attempt_issue_number
           ),
         :ok <- require_equal(data["max_attempts"], context.max_attempts, :github_attempt_maximum),
         :ok <-
           require_equal(
             data["source_revision"],
             context.source_revision,
             :github_attempt_source_revision
           ),
         :ok <- require_positive_integer(data["attempt"], :github_attempt_ordinal),
         :ok <-
           require_pattern(
             data["reservation_id"],
             @reservation_pattern,
             :github_attempt_reservation_id
           ),
         :ok <-
           require_true(
             valid_nullable_positive_integer?(data["previous_comment_id"]),
             :github_attempt_previous_comment
           ) do
      require_true(
        valid_nullable_digest?(data["previous_digest"]),
        :github_attempt_previous_digest
      )
    end
  end

  defp valid_predecessor?(data, nil) do
    is_nil(data["previous_comment_id"]) and is_nil(data["previous_digest"])
  end

  defp valid_predecessor?(data, previous) do
    data["previous_comment_id"] == previous.comment_id and
      data["previous_digest"] == previous.digest
  end

  defp validate_comment_metadata(comment) do
    cond do
      not present_string?(comment["created_at"]) -> {:error, :github_attempt_created_at}
      comment["created_at"] != comment["updated_at"] -> {:error, :github_attempt_comment_edited}
      true -> :ok
    end
  end

  defp trusted_comment?(comment, context) do
    get_in(comment, ["user", "id"]) == context.actor_id and
      get_in(comment, ["user", "type"]) == "Bot" and
      get_in(comment, ["performed_via_github_app", "id"]) == context.app_id
  end

  defp parse_canonical_body(body, marker) do
    json = String.replace_prefix(body, marker, "")

    with {:ok, data} when is_map(data) <- Jason.decode(json),
         true <- body == marker <> canonical_json(data) or {:error, :github_attempt_noncanonical} do
      {:ok, data}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :github_attempt_payload}
    end
  end

  defp canonical_json(data) when is_map(data) do
    data
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map_join(",", fn {key, value} -> Jason.encode!(key) <> ":" <> Jason.encode!(value) end)
    |> then(&("{" <> &1 <> "}"))
  end

  defp reservation_data_from_body(@attempt_marker <> json) do
    {:ok, data} = Jason.decode(json)
    data
  end

  defp reservation_present?(ledger, reservation_id) do
    Enum.any?(ledger.entries, &(&1.data["reservation_id"] == reservation_id))
  end

  defp evidence(ledger, max_attempts) do
    used = ledger.used
    tip = ledger.tip

    %{
      used: used,
      max: max_attempts,
      remaining: max(max_attempts - used, 0),
      exhausted: used >= max_attempts,
      reservation_id: tip && tip.data["reservation_id"],
      evidence_url: tip && tip.evidence_url,
      tip_comment_id: tip && tip.comment_id,
      tip_digest: tip && tip.digest,
      observed_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }
  end

  defp ensure_exhaustion_evidence(context, evidence, tracker_settings, request_fun) do
    if context.enabled do
      ensure_trusted_exhaustion_comment(context, evidence, tracker_settings, request_fun)
    else
      {:ok, %{evidence_url: nil}}
    end
  end

  defp ensure_trusted_exhaustion_comment(context, evidence, tracker_settings, request_fun) do
    with {:ok, comments} <- fetch_all_comments(context, tracker_settings, request_fun),
         {:ok, ledger} <- validate_ledger(comments, context),
         event_data <- exhaustion_data(context, ledger, evidence),
         :ok <- validate_exhaustion_data(event_data, context) do
      event_id = event_data["event_id"]

      case Enum.filter(ledger.exhaustion_entries, &(&1.data["event_id"] == event_id)) do
        [entry] ->
          {:ok, %{evidence_url: entry.evidence_url}}

        [] ->
          post_and_confirm_exhaustion(context, event_data, tracker_settings, request_fun)

        _ ->
          {:error, :github_attempt_duplicate_exhaustion}
      end
    end
  end

  defp post_and_confirm_exhaustion(context, event_data, tracker_settings, request_fun) do
    body = @exhaustion_marker <> canonical_json(event_data)

    _post_result =
      github_request(
        "POST",
        comments_path(context),
        %{},
        %{"body" => body},
        tracker_settings,
        request_fun
      )

    with {:ok, comments} <- fetch_all_comments(context, tracker_settings, request_fun),
         {:ok, ledger} <- validate_ledger(comments, context),
         [entry] <-
           Enum.filter(
             ledger.exhaustion_entries,
             &(&1.data["event_id"] == event_data["event_id"])
           ) do
      {:ok, %{evidence_url: entry.evidence_url}}
    else
      [] -> {:error, :github_attempt_exhaustion_unconfirmed}
      entries when is_list(entries) -> {:error, :github_attempt_duplicate_exhaustion}
      {:error, reason} -> {:error, reason}
    end
  end

  defp exhaustion_data(context, ledger, evidence) do
    used = ledger.used
    tip_comment_id = ledger.tip && ledger.tip.comment_id
    tip_digest = ledger.tip && ledger.tip.digest
    reason = evidence_value(evidence, :reason, "reason", "max_attempts_exhausted")

    event_seed =
      Enum.join(
        [
          context.repository_id,
          context.issue_id,
          used,
          tip_comment_id,
          tip_digest,
          context.max_attempts,
          context.source_revision
        ],
        ":"
      )

    %{
      "schema" => 1,
      "repository" => context.repo,
      "repository_id" => context.repository_id,
      "issue_id" => context.issue_id,
      "issue_node_id" => context.issue_node_id,
      "issue_number" => context.issue_number,
      "used" => used,
      "max_attempts" => context.max_attempts,
      "tip_comment_id" => tip_comment_id,
      "tip_digest" => tip_digest,
      "reason" => to_string(reason),
      "event_id" => digest(event_seed),
      "source_revision" => context.source_revision
    }
  end

  defp parse_exhaustion_comment(comment, context) do
    with :ok <- validate_comment_metadata(comment),
         {:ok, data} <- parse_canonical_body(comment["body"], @exhaustion_marker),
         :ok <- validate_exhaustion_data(data, context),
         {:ok, comment_id} <- positive_integer(comment["id"]),
         true <- present_string?(comment["html_url"]) or {:error, :github_attempt_comment_url} do
      {:ok,
       %{
         comment_id: comment_id,
         evidence_url: comment["html_url"],
         body: comment["body"],
         digest: digest(comment["body"]),
         data: data
       }}
    end
  end

  defp validate_exhaustion_data(data, context) when is_map(data) do
    required_keys = [
      "event_id",
      "issue_id",
      "issue_node_id",
      "issue_number",
      "max_attempts",
      "reason",
      "repository",
      "repository_id",
      "schema",
      "source_revision",
      "tip_comment_id",
      "tip_digest",
      "used"
    ]

    with :ok <- require_exact_keys(data, required_keys, :github_attempt_exhaustion_fields),
         :ok <- require_equal(data["schema"], 1, :github_attempt_exhaustion_schema),
         :ok <- validate_exhaustion_subject(data, context),
         :ok <-
           require_equal(
             data["max_attempts"],
             context.max_attempts,
             :github_attempt_exhaustion_maximum
           ),
         :ok <-
           require_equal(
             data["source_revision"],
             context.source_revision,
             :github_attempt_exhaustion_source
           ),
         :ok <- require_non_negative_integer(data["used"], :github_attempt_exhaustion_used),
         :ok <- require_pattern(data["event_id"], @digest_pattern, :github_attempt_exhaustion_id),
         :ok <- validate_exhaustion_event_id(data),
         :ok <- validate_exhaustion_tip_fields(data) do
      require_true(present_string?(data["reason"]), :github_attempt_exhaustion_reason)
    end
  end

  defp validate_exhaustion_event_id(data) do
    seed =
      Enum.join(
        [
          data["repository_id"],
          data["issue_id"],
          data["used"],
          data["tip_comment_id"],
          data["tip_digest"],
          data["max_attempts"],
          data["source_revision"]
        ],
        ":"
      )

    require_equal(data["event_id"], digest(seed), :github_attempt_exhaustion_id)
  end

  defp validate_exhaustion_subject(data, context) do
    require_all_equal(
      [
        {data["repository"], context.repo},
        {data["repository_id"], context.repository_id},
        {data["issue_id"], context.issue_id},
        {data["issue_node_id"], context.issue_node_id},
        {data["issue_number"], context.issue_number}
      ],
      :github_attempt_exhaustion_subject
    )
  end

  defp validate_exhaustion_tip_fields(data) do
    require_true(
      valid_nullable_positive_integer?(data["tip_comment_id"]) and
        valid_nullable_digest?(data["tip_digest"]),
      :github_attempt_exhaustion_tip
    )
  end

  defp validate_exhaustion_entries(entries, attempts, context) do
    tip = List.last(attempts)

    Enum.reduce_while(entries, MapSet.new(), fn entry, event_ids ->
      case validate_exhaustion_entry(entry, event_ids, attempts, tip, context) do
        :ok -> {:cont, MapSet.put(event_ids, entry.data["event_id"])}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      %MapSet{} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_exhaustion_entry(entry, event_ids, attempts, tip, context) do
    data = entry.data

    with :ok <-
           require_true(
             not MapSet.member?(event_ids, data["event_id"]),
             :github_attempt_duplicate_exhaustion
           ),
         :ok <-
           require_true(data["used"] <= length(attempts), :github_attempt_exhaustion_ahead),
         :ok <- validate_exhaustion_tip(data, attempts, tip) do
      require_true(
        data["used"] != context.max_attempts or not is_nil(tip),
        :github_attempt_exhaustion_tip_mismatch
      )
    end
  end

  defp validate_exhaustion_tip(%{"used" => used} = data, attempts, tip)
       when used == length(attempts) and not is_nil(tip) do
    require_all_equal(
      [{data["tip_comment_id"], tip.comment_id}, {data["tip_digest"], tip.digest}],
      :github_attempt_exhaustion_tip_mismatch
    )
  end

  defp validate_exhaustion_tip(_data, _attempts, _tip), do: :ok

  defp remove_activation_label(context, tracker_settings, request_fun) do
    path = issue_path(context) <> "/labels/" <> URI.encode(context.activation_label, &URI.char_unreserved?/1)

    case github_request("DELETE", path, %{}, nil, tracker_settings, request_fun) do
      {:ok, %{status: status}} when status in 200..299 or status == 404 -> :ok
      {:ok, %{status: status}} -> {:error, {:github_attempt_deactivation_status, status}}
      {:error, reason} -> {:error, {:github_attempt_deactivation_request, reason}}
    end
  end

  defp confirm_activation_label_absent(context, tracker_settings, request_fun) do
    case github_request("GET", issue_path(context), %{}, nil, tracker_settings, request_fun) do
      {:ok, %{status: 200, body: issue}} when is_map(issue) ->
        case normalized_issue_labels(issue) do
          {:ok, labels} -> confirm_label_absence(labels, context.activation_label)
          {:error, reason} -> {:error, reason}
        end

      {:ok, %{status: status}} when is_integer(status) ->
        {:error, {:github_attempt_deactivation_confirm_status, status}}

      {:error, reason} ->
        {:error, {:github_attempt_deactivation_confirm_request, reason}}
    end
  end

  defp normalized_issue_labels(%{"labels" => labels}) when is_list(labels) do
    Enum.reduce_while(labels, {:ok, []}, &normalize_issue_label/2)
  end

  defp normalized_issue_labels(_issue),
    do: {:error, :github_attempt_deactivation_confirm_payload}

  defp normalize_issue_label(%{"name" => name}, {:ok, acc}) when is_binary(name),
    do: append_normalized_label(name, acc)

  defp normalize_issue_label(name, {:ok, acc}) when is_binary(name),
    do: append_normalized_label(name, acc)

  defp normalize_issue_label(_label, _acc),
    do: {:halt, {:error, :github_attempt_deactivation_confirm_payload}}

  defp append_normalized_label(name, acc) do
    case name |> String.trim() |> String.downcase() do
      "" -> {:halt, {:error, :github_attempt_deactivation_confirm_payload}}
      normalized -> {:cont, {:ok, [normalized | acc]}}
    end
  end

  defp confirm_label_absence(labels, activation_label) do
    if String.downcase(activation_label) in labels do
      {:error, :github_attempt_deactivation_unconfirmed}
    else
      :ok
    end
  end

  defp runtime_settings(tracker_settings, opts) do
    with {:ok, settings} <- base_runtime_settings(tracker_settings, opts) do
      prepare_runtime_root(settings, opts)
    end
  end

  defp base_runtime_settings(tracker_settings, opts) do
    provider = provider_settings(tracker_settings)

    with :ok <- validate_agent_tool_setting(provider),
         :ok <- validate_official_api_url(provider),
         %{} = raw_settings <- provider["attempt_ledger"] || %{},
         {:ok, settings} <- normalize_ledger_settings(raw_settings, true),
         true <-
           settings.enabled or Keyword.get(opts, :allow_disabled, false) or
             {:error, :github_attempt_ledger_disabled} do
      {:ok, settings}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_github_attempt_ledger}
    end
  end

  defp prepare_runtime_root(settings, opts) do
    with {:ok, high_water_root} <- resolve_high_water_root(settings.high_water_root, opts),
         {:ok, secure_root} <-
           prepare_high_water_root(high_water_root, Keyword.get(opts, :workspace_root)) do
      {:ok, Map.put(settings, :high_water_root, secure_root)}
    end
  end

  defp normalize_ledger_settings(raw_settings, _runtime?) when is_map(raw_settings) do
    enabled = raw_settings["enabled"] == true

    settings = %{
      enabled: enabled,
      repository_id: raw_settings["repository_id"],
      actor_id: raw_settings["actor_id"],
      app_id: raw_settings["app_id"],
      activation_label: raw_settings["activation_label"],
      source_revision: raw_settings["source_revision"],
      high_water_root: raw_settings["high_water_root"]
    }

    required_keys = [
      "activation_label",
      "actor_id",
      "app_id",
      "enabled",
      "high_water_root",
      "repository_id",
      "source_revision"
    ]

    with :ok <- require_exact_keys(raw_settings, required_keys, :invalid_github_attempt_ledger_fields),
         :ok <- require_true(is_boolean(raw_settings["enabled"]), :invalid_github_attempt_ledger_enabled),
         :ok <-
           require_true(
             positive_integer?(settings.repository_id),
             :invalid_github_attempt_ledger_repository_id
           ),
         :ok <-
           require_true(
             present_string?(settings.activation_label),
             :invalid_github_attempt_ledger_activation_label
           ),
         :ok <-
           require_pattern(
             settings.source_revision,
             @revision_pattern,
             :invalid_github_attempt_ledger_source_revision
           ),
         :ok <-
           require_true(
             valid_high_water_token?(settings.high_water_root),
             :invalid_github_attempt_ledger_high_water_root
           ),
         :ok <- validate_enabled_identity(settings, enabled) do
      {:ok, settings}
    end
  end

  defp validate_enabled_identity(_settings, false), do: :ok

  defp validate_enabled_identity(settings, true) do
    with :ok <-
           require_true(
             positive_integer?(settings.actor_id),
             :invalid_github_attempt_ledger_actor_id
           ) do
      require_true(
        positive_integer?(settings.app_id),
        :invalid_github_attempt_ledger_app_id
      )
    end
  end

  defp validate_agent_tool_setting(%{"attempt_ledger" => %{} = _ledger} = provider) do
    if provider["agent_tools_enabled"] == false do
      :ok
    else
      {:error, :github_attempt_ledger_requires_disabled_agent_tools}
    end
  end

  defp validate_agent_tool_setting(_provider), do: :ok

  defp validate_official_api_url(provider) do
    case provider["api_url"] do
      nil -> :ok
      "https://api.github.com" -> :ok
      "https://api.github.com/" -> :ok
      _ -> {:error, :github_attempt_ledger_requires_official_api}
    end
  end

  defp resolve_high_water_root("$" <> env_name, opts) do
    if String.match?(env_name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/) do
      value = Keyword.get(opts, :high_water_root) || System.get_env(env_name)

      if present_string?(value), do: {:ok, Path.expand(value)}, else: {:error, :github_attempt_high_water_root_missing}
    else
      {:error, :invalid_github_attempt_ledger_high_water_root}
    end
  end

  defp resolve_high_water_root(value, opts) when is_binary(value) do
    root = Keyword.get(opts, :high_water_root) || value
    if Path.type(root) == :absolute, do: {:ok, Path.expand(root)}, else: {:error, :github_attempt_high_water_root_relative}
  end

  defp resolve_high_water_root(_value, _opts), do: {:error, :github_attempt_high_water_root_missing}

  defp prepare_high_water_root(root, workspace_root) do
    with :ok <- reject_symlink_components(root),
         :ok <- require_preprovisioned_root(root),
         {:ok, canonical_root} <- PathSafety.canonicalize(root),
         {:ok, canonical_workspace} <- canonical_workspace(workspace_root),
         :ok <- validate_root_separation(canonical_root, canonical_workspace),
         :ok <- reject_symlink_components(root),
         :ok <- confirm_canonical_root(root, canonical_root),
         :ok <- validate_secure_directory(canonical_root) do
      {:ok, canonical_root}
    else
      {:error, {:path_canonicalize_failed, _path, reason}} ->
        {:error, {:github_attempt_high_water_root_canonicalize, reason}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp require_preprovisioned_root(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, _stat} -> {:error, :github_attempt_high_water_root_insecure}
      {:error, :enoent} -> {:error, :github_attempt_high_water_root_not_provisioned}
      {:error, reason} -> {:error, {:github_attempt_high_water_root_lstat, reason}}
    end
  end

  defp confirm_canonical_root(root, expected) do
    case PathSafety.canonicalize(root) do
      {:ok, ^expected} -> :ok
      {:ok, _changed} -> {:error, :github_attempt_high_water_root_changed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp canonical_workspace(nil), do: {:ok, nil}
  defp canonical_workspace(path) when is_binary(path), do: PathSafety.canonicalize(path)
  defp canonical_workspace(_path), do: {:error, :github_attempt_workspace_root_invalid}

  defp validate_root_separation(_root, nil), do: :ok

  defp validate_root_separation(root, workspace) do
    if path_contains?(root, workspace) or path_contains?(workspace, root) do
      {:error, :github_attempt_high_water_inside_workspace}
    else
      :ok
    end
  end

  defp path_contains?(parent, child) do
    Path.dirname(parent) == parent or parent == child or
      String.starts_with?(child <> "/", parent <> "/")
  end

  defp reject_symlink_components(path) do
    path
    |> Path.expand()
    |> Path.split()
    |> Enum.reduce_while(nil, fn segment, current ->
      candidate = if is_nil(current), do: segment, else: Path.join(current, segment)

      case File.lstat(candidate) do
        {:ok, %File.Stat{type: :symlink}} ->
          {:halt, {:error, :github_attempt_high_water_symlink}}

        {:ok, _stat} ->
          {:cont, candidate}

        {:error, :enoent} ->
          {:halt, :ok}

        {:error, reason} ->
          {:halt, {:error, {:github_attempt_high_water_lstat, reason}}}
      end
    end)
    |> case do
      path when is_binary(path) -> :ok
      result -> result
    end
  end

  defp validate_secure_directory(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory, mode: mode}} when band(mode, 0o077) == 0 -> :ok
      {:ok, _stat} -> {:error, :github_attempt_high_water_root_insecure}
      {:error, reason} -> {:error, {:github_attempt_high_water_root_lstat, reason}}
    end
  end

  defp issue_context(%Issue{} = issue, settings, max_attempts, tracker_settings) do
    provider = provider_settings(tracker_settings)
    repo = provider["repo"] || get_in(issue.native_ref || %{}, ["repo"])
    native_ref = issue.native_ref || %{}

    with true <- present_string?(repo) or {:error, :github_attempt_repository_missing},
         true <- native_ref["repo"] == repo or {:error, :github_attempt_repository_mismatch},
         {:ok, issue_number} <- positive_integer(native_ref["number"]),
         {:ok, issue_id} <- positive_integer(native_ref["id"]),
         true <- present_string?(native_ref["node_id"]) or {:error, :github_attempt_issue_node_id},
         true <- Integer.to_string(issue_number) == issue.id or {:error, :github_attempt_issue_number_mismatch} do
      high_water_path = local_state_path(settings, issue_id, ".json")
      quarantine_path = local_state_path(settings, issue_id, ".quarantine.json")

      {:ok,
       %{
         enabled: settings.enabled,
         repo: repo,
         repository_id: settings.repository_id,
         issue_number: issue_number,
         issue_id: issue_id,
         issue_node_id: native_ref["node_id"],
         actor_id: settings.actor_id,
         app_id: settings.app_id,
         activation_label: settings.activation_label,
         source_revision: settings.source_revision,
         high_water_path: high_water_path,
         quarantine_path: quarantine_path,
         max_attempts: max_attempts
       }}
    end
  end

  defp local_state_path(%{high_water_root: root, repository_id: repository_id}, issue_id, suffix)
       when is_binary(root) do
    Path.join(root, "#{repository_id}-#{issue_id}#{suffix}")
  end

  defp local_state_path(_settings, _issue_id, _suffix), do: nil

  defp evidence_max(evidence) do
    value = evidence_value(evidence, :max, "max", nil)
    if positive_integer?(value), do: {:ok, value}, else: {:error, :github_attempt_evidence_max}
  end

  defp evidence_value(evidence, atom_key, string_key, default) do
    Map.get(evidence, atom_key, Map.get(evidence, string_key, default))
  end

  defp github_request(method, path, params, body, tracker_settings, request_fun) do
    Client.request(
      method,
      path,
      params,
      body,
      tracker_settings: tracker_settings,
      request_fun: request_fun
    )
  end

  defp posted_comment_id({:ok, %{status: status, body: %{"id" => id}}})
       when status in 200..299 and is_integer(id) and id > 0,
       do: id

  defp posted_comment_id(_result), do: nil

  defp validate_post_response_id(nil, _confirmed_id), do: :ok
  defp validate_post_response_id(id, id), do: :ok
  defp validate_post_response_id(_response_id, _confirmed_id), do: {:error, :github_attempt_post_id_mismatch}

  defp provider_settings(%{provider: provider}) when is_map(provider), do: provider
  defp provider_settings(%{"provider" => provider}) when is_map(provider), do: provider
  defp provider_settings(_tracker_settings), do: %{}

  defp comments_path(context), do: issue_path(context) <> "/comments"
  defp issue_path(context), do: "/repos/#{encoded_repo(context.repo)}/issues/#{context.issue_number}"

  defp encoded_repo(repo) do
    repo
    |> String.split("/", parts: 2)
    |> Enum.map_join("/", &URI.encode(&1, fn character -> URI.char_unreserved?(character) end))
  end

  defp digest(value) when is_binary(value) do
    :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive_integer(_value), do: {:error, :invalid_positive_integer}
  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp require_exact_keys(value, keys, reason),
    do: require_true(Enum.sort(Map.keys(value)) == keys, reason)

  defp require_equal(actual, expected, reason), do: require_true(actual == expected, reason)

  defp require_all_equal(pairs, reason) do
    require_true(Enum.all?(pairs, fn {actual, expected} -> actual == expected end), reason)
  end

  defp require_positive_integer(value, reason), do: require_true(positive_integer?(value), reason)

  defp require_non_negative_integer(value, reason),
    do: require_true(is_integer(value) and value >= 0, reason)

  defp require_pattern(value, pattern, reason),
    do: require_true(is_binary(value) and Regex.match?(pattern, value), reason)

  defp require_true(true, _reason), do: :ok
  defp require_true(false, reason), do: {:error, reason}

  defp valid_nullable_positive_integer?(nil), do: true
  defp valid_nullable_positive_integer?(value), do: positive_integer?(value)
  defp valid_nullable_digest?(nil), do: true
  defp valid_nullable_digest?(value) when is_binary(value), do: Regex.match?(@digest_pattern, value)
  defp valid_nullable_digest?(_value), do: false

  defp valid_high_water_token?("$" <> env_name),
    do: String.match?(env_name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/)

  defp valid_high_water_token?(value) when is_binary(value), do: Path.type(value) == :absolute
  defp valid_high_water_token?(_value), do: false

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false
end
