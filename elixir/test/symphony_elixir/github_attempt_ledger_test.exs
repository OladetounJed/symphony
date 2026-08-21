defmodule SymphonyElixir.GitHub.AttemptLedgerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.AttemptLedger

  @repo "octo/repo"
  @repository_id 77
  @actor_id 88
  @app_id 99
  @source_revision String.duplicate("a", 40)

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-attempt-ledger-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(root, "workspace")
    high_water_root = Path.join(root, "host-state")
    File.mkdir_p!(workspace_root)

    state =
      start_supervised!({Agent, &initial_remote_state/0})

    on_exit(fn -> File.rm_rf(root) end)

    context = [
      root: root,
      workspace_root: workspace_root,
      high_water_root: high_water_root,
      state: state,
      issue: issue(),
      tracker_settings: tracker_settings(high_water_root)
    ]

    {:ok, context}
  end

  test "five reservations survive restart state and no sixth start is authorized", context do
    request_fun = request_fun(context.state)

    evidence =
      Enum.reduce(1..5, nil, fn expected, _previous ->
        assert {:ok, evidence} = reserve(context, request_fun)
        assert evidence.used == expected
        assert evidence.max == 5
        assert evidence.remaining == 5 - expected
        assert evidence.exhausted == (expected == 5)
        evidence
      end)

    assert {:exhausted, exhausted} = reserve(context, request_fun)
    assert exhausted.used == 5
    assert exhausted.tip_comment_id == evidence.tip_comment_id

    assert {:ok, %{deactivated: true, activation_label: "pilot:symphony"}} =
             AttemptLedger.deactivate_for_test(
               context.issue,
               exhausted,
               context.tracker_settings,
               request_fun
             )

    snapshot = Agent.get(context.state, & &1)
    assert Enum.count(snapshot.comments, &String.starts_with?(&1["body"], attempt_marker())) == 5
    assert Enum.count(snapshot.comments, &String.starts_with?(&1["body"], exhaustion_marker())) == 1
    refute "pilot:symphony" in snapshot.labels

    # A process restart loses all in-memory orchestrator state. The durable
    # comments and host high-water file still deny a sixth reservation.
    assert {:exhausted, %{used: 5}} = reserve(context, request_fun)
  end

  test "disposable no-credential and no-Codex rehearsal stops after five starts across restart", context do
    {:ok, first_runtime} = Agent.start_link(&initial_remote_state/0)
    first_request = request_fun(first_runtime)

    worker_starts =
      Enum.reduce(1..2, 0, fn expected, starts ->
        assert {:ok, %{used: ^expected}} = reserve(context, first_request)
        starts + 1
      end)

    remote_snapshot = Agent.get(first_runtime, & &1)
    :ok = Agent.stop(first_runtime)

    {:ok, restarted_runtime} = Agent.start_link(fn -> remote_snapshot end)
    restarted_request = request_fun(restarted_runtime)

    worker_starts =
      Enum.reduce(3..5, worker_starts, fn expected, starts ->
        assert {:ok, %{used: ^expected}} = reserve(context, restarted_request)
        starts + 1
      end)

    assert {:exhausted, evidence} = reserve(context, restarted_request)
    assert worker_starts == 5

    assert {:ok, %{deactivated: true}} =
             AttemptLedger.deactivate_for_test(
               context.issue,
               evidence,
               context.tracker_settings,
               restarted_request
             )

    final_state = Agent.get(restarted_runtime, & &1)
    assert Enum.count(final_state.comments, &String.starts_with?(&1["body"], attempt_marker())) == 5
    assert Enum.count(final_state.comments, &String.starts_with?(&1["body"], exhaustion_marker())) == 1
    assert final_state.codex_calls == 0
    refute "pilot:symphony" in final_state.labels
    :ok = Agent.stop(restarted_runtime)
  end

  test "a lost POST response is resolved by the same durable reservation id", context do
    Agent.update(context.state, &%{&1 | post_mode: :store_then_error})

    assert {:ok, %{used: 1, reservation_id: reservation_id}} =
             reserve(context, request_fun(context.state))

    assert is_binary(reservation_id)
    assert byte_size(reservation_id) == 22
    assert length(Agent.get(context.state, & &1.comments)) == 1
  end

  test "an unconfirmed POST launches nothing and retry reuses the pending reservation", context do
    Agent.update(context.state, &%{&1 | post_mode: :success_without_store})

    assert {:error, {:github_attempt_reservation_unconfirmed, reservation_id}} =
             reserve(context, request_fun(context.state))

    high_water = read_high_water!(context.high_water_root)
    assert high_water["pending"]["reservation_id"] == reservation_id

    Agent.update(context.state, &%{&1 | post_mode: :normal})

    assert {:ok, %{used: 1, reservation_id: ^reservation_id}} =
             reserve(context, request_fun(context.state))

    assert length(Agent.get(context.state, & &1.comments)) == 1
  end

  test "malformed or edited trusted ledger comments fail closed", context do
    malformed = trusted_comment(1_000, attempt_marker() <> "{}")
    Agent.update(context.state, &%{&1 | comments: [malformed], next_id: 1_001})

    assert {:error, _reason} = reserve(context, request_fun(context.state))

    assert {:error, {:deactivated_without_exhaustion_evidence, _reason}} =
             AttemptLedger.deactivate_for_test(
               context.issue,
               %{used: 0, max: 5, reason: "malformed_ledger"},
               context.tracker_settings,
               request_fun(context.state)
             )

    refute "pilot:symphony" in Agent.get(context.state, & &1.labels)

    Agent.update(context.state, fn state ->
      edited = %{malformed | "updated_at" => "2026-01-02T00:00:00Z"}
      %{state | comments: [edited]}
    end)

    assert {:error, :github_attempt_comment_edited} =
             reserve(context, request_fun(context.state))
  end

  test "untrusted marker comments are ignored and cannot consume the budget", context do
    forged =
      trusted_comment(1_000, attempt_marker() <> "{}")
      |> put_in(["user", "id"], 123_456)

    Agent.update(context.state, &%{&1 | comments: [forged], next_id: 1_001})

    assert {:ok, %{used: 1}} = reserve(context, request_fun(context.state))
    assert length(Agent.get(context.state, & &1.comments)) == 2
  end

  test "deleted middle or tail entries are rejected by chain and high-water evidence", context do
    request_fun = request_fun(context.state)
    assert {:ok, %{used: 1}} = reserve(context, request_fun)
    assert {:ok, %{used: 2}} = reserve(context, request_fun)

    [first, second] = Agent.get(context.state, & &1.comments)
    Agent.update(context.state, &%{&1 | comments: [second]})
    assert {:error, :github_attempt_ordinal_gap} = reserve(context, request_fun)

    Agent.update(context.state, &%{&1 | comments: [first]})
    assert {:error, :github_attempt_ledger_regressed} = reserve(context, request_fun)
  end

  test "high-water write failure happens before any GitHub reservation", context do
    blocked_root = Path.join(context.root, "not-a-directory")
    File.write!(blocked_root, "file")

    tracker_settings = tracker_settings(blocked_root)

    assert {:error, {:github_attempt_high_water_read, :enotdir}} =
             AttemptLedger.reserve_for_test(
               context.issue,
               5,
               tracker_settings,
               request_fun(context.state),
               workspace_root: context.workspace_root
             )

    assert Agent.get(context.state, & &1.comments) == []
  end

  test "an oversized comment page fails closed", context do
    oversized_request = fn "GET", _path, _params, nil, _settings ->
      {:ok, %{status: 200, body: List.duplicate(%{"body" => "ordinary"}, 101)}}
    end

    assert {:error, :github_attempt_comments_page_size} = reserve(context, oversized_request)
  end

  test "settings require disabled agent tools and immutable actor/App ids when enabled", context do
    assert :ok = AttemptLedger.validate_settings(context.tracker_settings)

    assert {:error, :github_attempt_ledger_requires_disabled_agent_tools} =
             AttemptLedger.validate_settings(put_in(context.tracker_settings, [:provider, "agent_tools_enabled"], true))

    assert {:error, :invalid_github_attempt_ledger_actor_id} =
             AttemptLedger.validate_settings(
               put_in(
                 context.tracker_settings,
                 [:provider, "attempt_ledger", "actor_id"],
                 nil
               )
             )
  end

  test "a disabled ledger still removes accidental dispatch eligibility without trusting comments", context do
    disabled_settings =
      context.tracker_settings
      |> put_in([:provider, "attempt_ledger", "enabled"], false)
      |> put_in([:provider, "attempt_ledger", "actor_id"], 0)
      |> put_in([:provider, "attempt_ledger", "app_id"], 0)

    assert {:ok, %{deactivated: true, evidence_url: nil}} =
             AttemptLedger.deactivate_for_test(
               context.issue,
               %{used: 0, max: 5, reason: "ledger_disabled"},
               disabled_settings,
               request_fun(context.state)
             )

    refute "pilot:symphony" in Agent.get(context.state, & &1.labels)
  end

  defp reserve(context, request_fun) do
    AttemptLedger.reserve_for_test(
      context.issue,
      5,
      context.tracker_settings,
      request_fun,
      workspace_root: context.workspace_root
    )
  end

  defp request_fun(state_agent) do
    fn method, path, params, body, _github_settings ->
      Agent.get_and_update(state_agent, fn state ->
        state = record_call(state, method, path, params, body)
        handle_request(method, path, params, body, state)
      end)
    end
  end

  defp record_call(state, method, path, params, body),
    do: %{state | calls: [{method, path, params, body} | state.calls]}

  defp handle_request("GET", "/repos/octo/repo/issues/42/comments", params, _body, state) do
    comments = if params["page"] == 1, do: state.comments, else: []
    {{:ok, %{status: 200, body: comments}}, state}
  end

  defp handle_request("POST", "/repos/octo/repo/issues/42/comments", _params, body, state) do
    comment = trusted_comment(state.next_id, body["body"])
    handle_post(state.post_mode, state, comment)
  end

  defp handle_request("DELETE", "/repos/octo/repo/issues/42/labels/pilot%3Asymphony", _params, _body, state) do
    response = {:ok, %{status: 204, body: nil}}
    {response, %{state | labels: state.labels -- ["pilot:symphony"]}}
  end

  defp handle_request("GET", "/repos/octo/repo/issues/42", _params, _body, state) do
    labels = Enum.map(state.labels, &%{"name" => &1})
    {{:ok, %{status: 200, body: %{"labels" => labels}}}, state}
  end

  defp handle_request(method, path, _params, _body, state),
    do: {{:error, {:unexpected_request, method, path}}, state}

  defp handle_post(:normal, state, comment) do
    response = {:ok, %{status: 201, body: comment}}
    {response, store_comment(state, comment)}
  end

  defp handle_post(:store_then_error, state, comment) do
    {{:error, :timeout}, %{store_comment(state, comment) | post_mode: :normal}}
  end

  defp handle_post(:success_without_store, state, comment),
    do: {{:ok, %{status: 201, body: comment}}, state}

  defp store_comment(state, comment),
    do: %{state | comments: state.comments ++ [comment], next_id: state.next_id + 1}

  defp initial_remote_state do
    %{
      comments: [],
      labels: ["agent-ready", "pilot:symphony"],
      next_id: 1_000,
      post_mode: :normal,
      calls: [],
      codex_calls: 0
    }
  end

  defp tracker_settings(high_water_root) do
    %{
      kind: "github",
      provider: %{
        "repo" => @repo,
        "token" => "test-token",
        "agent_tools_enabled" => false,
        "attempt_ledger" => %{
          "enabled" => true,
          "repository_id" => @repository_id,
          "actor_id" => @actor_id,
          "app_id" => @app_id,
          "activation_label" => "pilot:symphony",
          "source_revision" => @source_revision,
          "high_water_root" => high_water_root
        }
      },
      active_states: ["open"],
      terminal_states: ["closed"]
    }
  end

  defp issue do
    %Issue{
      id: "42",
      identifier: "GH-42",
      title: "Disposable attempt rehearsal",
      state: "open",
      url: "https://github.test/octo/repo/issues/42",
      labels: ["agent-ready", "pilot:symphony"],
      native_ref: %{
        "repo" => @repo,
        "number" => 42,
        "id" => 4_242,
        "node_id" => "I_kwDO_TEST_42"
      }
    }
  end

  defp trusted_comment(id, body) do
    %{
      "id" => id,
      "html_url" => "https://github.test/octo/repo/issues/42#issuecomment-#{id}",
      "body" => body,
      "created_at" => "2026-01-01T00:00:00Z",
      "updated_at" => "2026-01-01T00:00:00Z",
      "user" => %{"id" => @actor_id, "type" => "Bot"},
      "performed_via_github_app" => %{"id" => @app_id}
    }
  end

  defp read_high_water!(root) do
    [path] = Path.wildcard(Path.join(root, "*.json"))
    path |> File.read!() |> Jason.decode!()
  end

  defp attempt_marker, do: "<!-- iwe-symphony-attempt:v1 -->\n"
  defp exhaustion_marker, do: "<!-- iwe-symphony-exhaustion:v1 -->\n"
end
