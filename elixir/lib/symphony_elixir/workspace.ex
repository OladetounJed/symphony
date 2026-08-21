defmodule SymphonyElixir.Workspace do
  @moduledoc """
  Creates isolated per-issue workspaces for parallel Codex agents.
  """

  require Logger
  alias SymphonyElixir.{AttemptFuse, Config, PathSafety, SSH}

  @remote_workspace_marker "__SYMPHONY_WORKSPACE__"
  @remote_workspace_validation_marker "__SYMPHONY_REMOTE_WORKSPACE_VALID__"

  @type worker_host :: String.t() | nil

  @spec create_for_issue(map() | String.t() | nil, worker_host()) ::
          {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier, worker_host \\ nil),
    do: create_for_issue(issue_or_identifier, worker_host, nil)

  @doc false
  @spec create_for_issue(map() | String.t() | nil, worker_host(), map() | nil) ::
          {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier, worker_host, attempt_fuse) do
    issue_context = issue_context(issue_or_identifier)
    settings = execution_settings(attempt_fuse)

    try do
      safe_id = workspace_key(issue_or_identifier)

      with :ok <- validate_attempt_fuse(attempt_fuse),
           :ok <- notify_workspace_boundary(:before_path, safe_id, worker_host),
           workspace_root <- execution_workspace_root(attempt_fuse, settings, worker_host),
           {:ok, workspace} <-
             workspace_path_for_issue(safe_id, worker_host, workspace_root),
           :ok <- validate_workspace_path(workspace, worker_host, workspace_root),
           :ok <- validate_attempt_fuse(attempt_fuse),
           {:ok, workspace, created?} <-
             ensure_workspace(
               workspace,
               worker_host,
               workspace_root,
               settings.hooks.timeout_ms
             ) do
        result =
          with :ok <- notify_workspace_boundary(:prepared, workspace, worker_host),
               :ok <- validate_attempt_fuse(attempt_fuse),
               :ok <-
                 maybe_run_after_create_hook(
                   workspace,
                   issue_context,
                   created?,
                   worker_host,
                   settings.hooks,
                   workspace_root
                 ),
               {:ok, validated_workspace} <-
                 validate_prepared_workspace(
                   workspace,
                   worker_host,
                   workspace_root,
                   settings.hooks.timeout_ms
                 ),
               :ok <- validate_attempt_fuse(attempt_fuse) do
            {:ok, validated_workspace}
          end

        case result do
          {:error, _reason} = error ->
            cleanup_failed_new_workspace(
              workspace,
              created?,
              worker_host,
              settings.hooks.timeout_ms,
              workspace_root
            )

            error

          {:ok, _workspace} = success ->
            success
        end
      end
    rescue
      error in [ArgumentError, ErlangError, File.Error] ->
        Logger.error("Workspace creation failed #{issue_log_context(issue_context)} worker_host=#{worker_host_for_log(worker_host)} error=#{Exception.message(error)}")
        {:error, error}
    end
  end

  defp ensure_workspace(workspace, nil, _workspace_root, _timeout_ms) do
    cond do
      File.dir?(workspace) ->
        {:ok, workspace, false}

      File.exists?(workspace) ->
        File.rm_rf!(workspace)
        create_workspace(workspace)

      true ->
        create_workspace(workspace)
    end
  end

  defp ensure_workspace(workspace, worker_host, workspace_root, timeout_ms)
       when is_binary(worker_host) and is_binary(workspace_root) do
    script =
      [
        "set -eu",
        remote_shell_assign("workspace", workspace),
        remote_shell_assign("workspace_root", workspace_root),
        "if [ -d \"$workspace\" ]; then",
        "  created=0",
        "elif [ -e \"$workspace\" ]; then",
        "  rm -rf \"$workspace\"",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "else",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "fi",
        remote_workspace_guard_script(workspace, workspace_root),
        "printf '%s\\t%s\\t%s\\t%s\\n' '#{@remote_workspace_marker}' \"$created\" \"$workspace_root\" \"$workspace\""
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, timeout_ms) do
      {:ok, {output, 0}} ->
        parse_remote_workspace_output(output, Path.basename(workspace))

      {:ok, {output, status}} ->
        {:error, {:workspace_prepare_failed, worker_host, status, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_workspace(workspace) do
    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)
    {:ok, workspace, true}
  end

  defp notify_workspace_boundary(stage, value, worker_host) do
    case Application.get_env(:symphony_elixir, :workspace_boundary_observer) do
      observer when is_function(observer, 3) ->
        case observer.(stage, value, worker_host) do
          :ok -> :ok
          {:error, _reason} = error -> error
          other -> {:error, {:workspace_boundary_observer_invalid, other}}
        end

      _ ->
        :ok
    end
  end

  @spec remove(Path.t()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace), do: remove(workspace, nil)

  @spec remove(Path.t(), worker_host()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace, nil) do
    case File.exists?(workspace) do
      true ->
        case validate_workspace_path(workspace, nil) do
          :ok ->
            remove_local_workspace(workspace)

          {:error, reason} ->
            {:error, reason, ""}
        end

      false ->
        File.rm_rf(workspace)
    end
  end

  def remove(workspace, worker_host) when is_binary(worker_host) do
    remove_remote_workspace(
      workspace,
      worker_host,
      current_workspace_root(worker_host),
      Config.settings!().hooks
    )
  end

  defp remove_remote_workspace(workspace, worker_host, workspace_root, hooks)
       when is_binary(workspace) and is_binary(worker_host) and is_binary(workspace_root) do
    with {:ok, canonical_workspace} <-
           validate_remote_workspace(workspace, workspace_root, worker_host, hooks.timeout_ms),
         :ok <-
           maybe_run_before_remove_hook(
             canonical_workspace,
             worker_host,
             workspace_root,
             hooks
           ),
         {:ok, ^canonical_workspace} <-
           validate_remote_workspace(
             canonical_workspace,
             workspace_root,
             worker_host,
             hooks.timeout_ms
           ) do
      script =
        [
          "set -eu",
          remote_workspace_guard_script(canonical_workspace, workspace_root),
          "rm -rf \"$workspace\""
        ]
        |> Enum.join("\n")

      case run_remote_command(worker_host, script, hooks.timeout_ms) do
        {:ok, {_output, 0}} ->
          {:ok, []}

        {:ok, {output, status}} ->
          {:error, {:workspace_remove_failed, worker_host, status, output}, ""}

        {:error, reason} ->
          {:error, reason, ""}
      end
    else
      {:ok, other_workspace} ->
        {:error, {:remote_workspace_changed, workspace, other_workspace}, ""}

      {:error, reason} ->
        {:error, reason, ""}
    end
  end

  @doc false
  @spec remove_recorded(Path.t(), worker_host()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove_recorded(workspace, nil) when is_binary(workspace) do
    if Path.type(workspace) == :absolute do
      case validate_recorded_workspace_path(workspace) do
        :ok ->
          remove_local_workspace(workspace)

        {:error, reason} ->
          {:error, reason, ""}
      end
    else
      {:error, {:workspace_path_unreadable, workspace, :not_absolute}, ""}
    end
  end

  def remove_recorded(workspace, worker_host) when is_binary(workspace) and is_binary(worker_host) do
    if Path.type(workspace) == :absolute do
      remove_remote_workspace(
        workspace,
        worker_host,
        Path.dirname(workspace),
        Config.settings!().hooks
      )
    else
      {:error, {:workspace_path_unreadable, workspace, :not_absolute}, ""}
    end
  end

  def remove_recorded(workspace, _worker_host) do
    {:error, {:workspace_path_unreadable, workspace, :invalid}, ""}
  end

  defp remove_local_workspace(workspace) do
    maybe_run_before_remove_hook(workspace, nil)
    File.rm_rf(workspace)
  end

  @spec remove_issue_workspaces(term()) :: :ok
  def remove_issue_workspaces(identifier), do: remove_issue_workspaces(identifier, nil)

  @spec remove_issue_workspaces(term(), worker_host()) :: :ok
  def remove_issue_workspaces(%{id: _issue_id, identifier: _identifier} = issue, worker_host)
      when is_binary(worker_host) do
    case workspace_path_for_issue(workspace_key(issue), worker_host) do
      {:ok, workspace} -> remove(workspace, worker_host)
      {:error, _reason} -> :ok
    end

    :ok
  end

  def remove_issue_workspaces(%{id: _issue_id, identifier: _identifier} = issue, nil) do
    case Config.settings!().worker.ssh_hosts do
      [] ->
        case workspace_path_for_issue(workspace_key(issue), nil) do
          {:ok, workspace} -> remove(workspace, nil)
          {:error, _reason} -> :ok
        end

      worker_hosts ->
        Enum.each(worker_hosts, &remove_issue_workspaces(issue, &1))
    end

    :ok
  end

  def remove_issue_workspaces(identifier, worker_host) when is_binary(identifier) and is_binary(worker_host) do
    case workspace_path_for_issue(workspace_key(identifier), worker_host) do
      {:ok, workspace} -> remove(workspace, worker_host)
      {:error, _reason} -> :ok
    end

    :ok
  end

  def remove_issue_workspaces(identifier, nil) when is_binary(identifier) do
    case Config.settings!().worker.ssh_hosts do
      [] ->
        case workspace_path_for_issue(workspace_key(identifier), nil) do
          {:ok, workspace} -> remove(workspace, nil)
          {:error, _reason} -> :ok
        end

      worker_hosts ->
        Enum.each(worker_hosts, &remove_issue_workspaces(identifier, &1))
    end

    :ok
  end

  def remove_issue_workspaces(_identifier, _worker_host), do: :ok

  @spec run_before_run_hook(Path.t(), map() | String.t() | nil, worker_host()) ::
          :ok | {:error, term()}
  def run_before_run_hook(workspace, issue_or_identifier, worker_host \\ nil),
    do: run_before_run_hook(workspace, issue_or_identifier, worker_host, nil)

  @doc false
  @spec run_before_run_hook(Path.t(), map() | String.t() | nil, worker_host(), map() | nil) ::
          :ok | {:error, term()}
  def run_before_run_hook(workspace, issue_or_identifier, worker_host, attempt_fuse)
      when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    settings = execution_settings(attempt_fuse)
    hooks = settings.hooks
    workspace_root = execution_workspace_root(attempt_fuse, settings, worker_host)

    case hooks.before_run do
      nil ->
        validate_hook_workspace(workspace, worker_host, workspace_root, hooks.timeout_ms)

      command ->
        with :ok <- validate_hook_workspace(workspace, worker_host, workspace_root, hooks.timeout_ms),
             :ok <-
               run_hook(
                 command,
                 workspace,
                 issue_context,
                 "before_run",
                 worker_host,
                 hooks.timeout_ms,
                 workspace_root
               ) do
          validate_hook_workspace(workspace, worker_host, workspace_root, hooks.timeout_ms)
        end
    end
  end

  @spec run_after_run_hook(Path.t(), map() | String.t() | nil, worker_host()) :: :ok
  def run_after_run_hook(workspace, issue_or_identifier, worker_host \\ nil),
    do: run_after_run_hook(workspace, issue_or_identifier, worker_host, nil)

  @doc false
  @spec run_after_run_hook(Path.t(), map() | String.t() | nil, worker_host(), map() | nil) :: :ok
  def run_after_run_hook(workspace, issue_or_identifier, worker_host, attempt_fuse)
      when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    settings = execution_settings(attempt_fuse)
    hooks = settings.hooks
    workspace_root = execution_workspace_root(attempt_fuse, settings, worker_host)

    case hooks.after_run do
      nil ->
        :ok

      command ->
        with :ok <-
               validate_hook_workspace(workspace, worker_host, workspace_root, hooks.timeout_ms) do
          run_hook(
            command,
            workspace,
            issue_context,
            "after_run",
            worker_host,
            hooks.timeout_ms,
            workspace_root
          )
        end
        |> ignore_hook_failure()
    end
  end

  defp workspace_path_for_issue(safe_id, worker_host),
    do: workspace_path_for_issue(safe_id, worker_host, current_workspace_root(worker_host))

  defp workspace_path_for_issue(safe_id, nil, workspace_root) when is_binary(safe_id) do
    workspace_root
    |> Path.join(safe_id)
    |> PathSafety.canonicalize()
  end

  defp workspace_path_for_issue(safe_id, worker_host, workspace_root)
       when is_binary(safe_id) and is_binary(worker_host) do
    {:ok, Path.join(workspace_root, safe_id)}
  end

  @doc """
  Returns the collision-safe directory name for an issue identifier.

  The hash is derived from the original identifier so callers that only know the identifier can
  derive the same key as callers holding a full tracker issue.
  """
  @spec workspace_key(map() | String.t() | nil) :: String.t()
  def workspace_key(%{identifier: identifier}), do: workspace_key(identifier)

  def workspace_key(identifier) when is_binary(identifier) do
    safe_identifier = safe_identifier(identifier)

    if safe_identifier == identifier do
      safe_identifier
    else
      "#{safe_identifier}--#{short_identifier_hash(identifier)}"
    end
  end

  def workspace_key(_identifier), do: "issue"

  defp safe_identifier(identifier) when is_binary(identifier),
    do: String.replace(identifier, ~r/[^a-zA-Z0-9._-]/, "_")

  defp short_identifier_hash(identifier) do
    :crypto.hash(:sha256, identifier)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp maybe_run_after_create_hook(
         workspace,
         issue_context,
         created?,
         worker_host,
         hooks,
         workspace_root
       ) do
    case created? do
      true ->
        case hooks.after_create do
          nil ->
            :ok

          command ->
            run_hook(
              command,
              workspace,
              issue_context,
              "after_create",
              worker_host,
              hooks.timeout_ms,
              workspace_root
            )
        end

      false ->
        :ok
    end
  end

  defp cleanup_failed_new_workspace(_workspace, false, _worker_host, _timeout_ms, _workspace_root),
    do: :ok

  defp cleanup_failed_new_workspace(workspace, true, nil, _timeout_ms, _workspace_root) do
    case File.rm_rf(workspace) do
      {:ok, _removed} ->
        :ok

      {:error, reason, path} ->
        Logger.warning("Failed to remove partial workspace path=#{path} reason=#{inspect(reason)}")
    end
  end

  defp cleanup_failed_new_workspace(workspace, true, worker_host, timeout_ms, workspace_root)
       when is_binary(worker_host) and is_binary(workspace_root) do
    script =
      [
        "set -eu",
        remote_workspace_guard_script(workspace, workspace_root),
        "rm -rf \"$workspace\""
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, timeout_ms) do
      {:ok, {_output, 0}} ->
        :ok

      result ->
        Logger.warning("Failed to remove partial workspace worker_host=#{worker_host_for_log(worker_host)} result=#{inspect(result)}")
    end
  end

  defp maybe_run_before_remove_hook(workspace, nil) do
    hooks = Config.settings!().hooks

    case File.dir?(workspace) do
      true ->
        case hooks.before_remove do
          nil ->
            :ok

          command ->
            run_hook(
              command,
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove",
              nil
            )
            |> ignore_hook_failure()
        end

      false ->
        :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace, worker_host, workspace_root, hooks)
       when is_binary(worker_host) and is_binary(workspace_root) do
    case hooks.before_remove do
      nil ->
        :ok

      command ->
        script =
          [
            "set -eu",
            remote_workspace_guard_script(workspace, workspace_root),
            "if [ -d \"$workspace\" ]; then",
            "  cd \"$workspace\"",
            "  #{command}",
            "fi"
          ]
          |> Enum.join("\n")

        run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms)
        |> case do
          {:ok, {output, status}} ->
            handle_hook_command_result(
              {output, status},
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove"
            )

          {:error, {:workspace_hook_timeout, "before_remove", _timeout_ms} = reason} ->
            {:error, reason}

          {:error, reason} ->
            {:error, reason}
        end
        |> ignore_hook_failure()
    end
  end

  defp ignore_hook_failure(:ok), do: :ok
  defp ignore_hook_failure({:error, _reason}), do: :ok

  defp run_hook(command, workspace, issue_context, hook_name, worker_host) do
    run_hook(
      command,
      workspace,
      issue_context,
      hook_name,
      worker_host,
      Config.settings!().hooks.timeout_ms,
      current_workspace_root(worker_host)
    )
  end

  defp run_hook(command, workspace, issue_context, hook_name, nil, timeout_ms, _workspace_root) do
    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local")

    task =
      Task.async(fn ->
        System.cmd("sh", ["-lc", command], cd: workspace, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      nil ->
        Task.shutdown(task, :brutal_kill)

        Logger.warning("Workspace hook timed out hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local timeout_ms=#{timeout_ms}")

        {:error, {:workspace_hook_timeout, hook_name, timeout_ms}}
    end
  end

  defp run_hook(
         command,
         workspace,
         issue_context,
         hook_name,
         worker_host,
         timeout_ms,
         workspace_root
       )
       when is_binary(worker_host) and is_binary(workspace_root) do
    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host}")

    script =
      [
        "set -eu",
        remote_workspace_guard_script(workspace, workspace_root),
        "cd \"$workspace\"",
        command
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      {:error, {:workspace_hook_timeout, ^hook_name, _timeout_ms} = reason} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execution_settings(%{enabled: true, execution_settings: settings}), do: settings
  defp execution_settings(_attempt_fuse), do: Config.settings!()

  defp validate_attempt_fuse(nil), do: :ok

  defp validate_attempt_fuse(attempt_fuse) when is_map(attempt_fuse),
    do: AttemptFuse.validate_current(attempt_fuse)

  defp execution_workspace_root(%{enabled: true, workspace_root: root}, _settings, nil), do: root

  defp execution_workspace_root(%{enabled: true}, settings, worker_host)
       when is_binary(worker_host),
       do: settings.workspace.root

  defp execution_workspace_root(_attempt_fuse, _settings, worker_host),
    do: current_workspace_root(worker_host)

  defp current_workspace_root(nil), do: Config.local_workspace_root()
  defp current_workspace_root([]), do: Config.local_workspace_root()
  defp current_workspace_root(_worker), do: Config.settings!().workspace.root

  defp handle_hook_command_result({_output, 0}, _workspace, _issue_id, _hook_name) do
    :ok
  end

  defp handle_hook_command_result({output, status}, workspace, issue_context, hook_name) do
    sanitized_output = sanitize_hook_output_for_log(output)

    Logger.warning("Workspace hook failed hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} status=#{status} output=#{inspect(sanitized_output)}")

    {:error, {:workspace_hook_failed, hook_name, status, output}}
  end

  defp sanitize_hook_output_for_log(output, max_bytes \\ 2_048) do
    binary_output = IO.iodata_to_binary(output)

    case byte_size(binary_output) <= max_bytes do
      true ->
        binary_output

      false ->
        binary_part(binary_output, 0, max_bytes) <> "... (truncated)"
    end
  end

  defp validate_workspace_path(workspace, nil) when is_binary(workspace) do
    validate_local_workspace_path(workspace, Config.local_workspace_root())
  end

  defp validate_workspace_path(workspace, nil, workspace_root)
       when is_binary(workspace) and is_binary(workspace_root) do
    validate_local_workspace_path(workspace, workspace_root)
  end

  defp validate_workspace_path(workspace, worker_host, workspace_root)
       when is_binary(workspace) and is_binary(worker_host) and is_binary(workspace_root) do
    validate_remote_path_inputs(workspace, workspace_root)
  end

  defp validate_prepared_workspace(workspace, nil, workspace_root, _timeout_ms) do
    case validate_local_workspace_path(workspace, workspace_root) do
      :ok -> {:ok, workspace}
      {:error, _reason} = error -> error
    end
  end

  defp validate_prepared_workspace(workspace, worker_host, workspace_root, timeout_ms)
       when is_binary(workspace) and is_binary(worker_host) and is_binary(workspace_root) do
    validate_remote_workspace(workspace, workspace_root, worker_host, timeout_ms)
  end

  defp validate_hook_workspace(_workspace, nil, _workspace_root, _timeout_ms), do: :ok

  defp validate_hook_workspace(workspace, worker_host, workspace_root, timeout_ms)
       when is_binary(worker_host) do
    case validate_remote_workspace(workspace, workspace_root, worker_host, timeout_ms) do
      {:ok, ^workspace} -> :ok
      {:ok, other} -> {:error, {:remote_workspace_changed, workspace, other}}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec validate_remote_workspace(Path.t(), Path.t(), String.t(), pos_integer()) ::
          {:ok, Path.t()} | {:error, term()}
  def validate_remote_workspace(workspace, workspace_root, worker_host, timeout_ms)
      when is_binary(workspace) and is_binary(workspace_root) and is_binary(worker_host) and
             is_integer(timeout_ms) and timeout_ms > 0 do
    with :ok <- validate_remote_path_inputs(workspace, workspace_root) do
      script =
        [
          "set -eu",
          remote_workspace_guard_script(workspace, workspace_root),
          "printf '%s\\t%s\\t%s\\n' '#{@remote_workspace_validation_marker}' \"$workspace_root\" \"$workspace\""
        ]
        |> Enum.join("\n")

      case run_remote_command(worker_host, script, timeout_ms) do
        {:ok, {output, 0}} ->
          parse_remote_workspace_validation(output, Path.basename(workspace))

        {:ok, {output, status}} ->
          {:error, {:remote_workspace_validation_failed, worker_host, status, output}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp validate_remote_path_inputs(workspace, workspace_root) do
    cond do
      String.trim(workspace) == "" or String.trim(workspace_root) == "" ->
        {:error, {:workspace_path_unreadable, workspace, :empty}}

      String.contains?(workspace <> workspace_root, ["\n", "\r", "\t", <<0>>]) ->
        {:error, {:workspace_path_unreadable, workspace, :invalid_characters}}

      true ->
        :ok
    end
  end

  defp validate_recorded_workspace_path(workspace) when is_binary(workspace) do
    validate_local_workspace_path(workspace, Path.dirname(workspace))
  end

  defp validate_local_workspace_path(workspace, workspace_root)
       when is_binary(workspace) and is_binary(workspace_root) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(workspace_root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:workspace_equals_root, canonical_workspace, canonical_root}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          :ok

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:workspace_symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:workspace_outside_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:workspace_path_unreadable, path, reason}}
    end
  end

  defp remote_shell_assign(variable_name, raw_path)
       when is_binary(variable_name) and is_binary(raw_path) do
    [
      "#{variable_name}=#{shell_escape(raw_path)}",
      "case \"$#{variable_name}\" in",
      "  '~') #{variable_name}=\"$HOME\" ;;",
      "  '~/'*) " <> variable_name <> "=\"$HOME/${" <> variable_name <> "#\\~/}\" ;;",
      "esac"
    ]
    |> Enum.join("\n")
  end

  @doc false
  @spec remote_workspace_guard_script(Path.t(), Path.t()) :: String.t()
  def remote_workspace_guard_script(workspace, workspace_root)
      when is_binary(workspace) and is_binary(workspace_root) do
    [
      remote_shell_assign("workspace", workspace),
      remote_shell_assign("workspace_root", workspace_root),
      "case \"$workspace$workspace_root\" in *$'\\n'*|*$'\\r'*|*$'\\t'*) exit 71 ;; esac",
      "[ -d \"$workspace_root\" ] || exit 72",
      "[ -d \"$workspace\" ] || exit 73",
      "workspace_root=$(cd \"$workspace_root\" && pwd -P)",
      "workspace_key=${workspace%/}",
      "workspace_key=${workspace_key##*/}",
      "workspace=$(cd \"$workspace\" && pwd -P)",
      "[ \"$workspace\" = \"$workspace_root/$workspace_key\" ] || exit 74"
    ]
    |> Enum.join("\n")
  end

  defp parse_remote_workspace_output(output, expected_key) do
    lines = String.split(IO.iodata_to_binary(output), "\n", trim: true)

    payload =
      Enum.find_value(lines, fn line ->
        case String.split(line, "\t", parts: 4) do
          [@remote_workspace_marker, created, root, path]
          when created in ["0", "1"] and root != "" and path != "" ->
            {created == "1", root, path}

          _ ->
            nil
        end
      end)

    case payload do
      {created?, root, workspace} when is_boolean(created?) ->
        case validate_remote_workspace_payload(root, workspace, expected_key) do
          :ok -> {:ok, workspace, created?}
          {:error, _reason} = error -> error
        end

      _ ->
        {:error, {:workspace_prepare_failed, :invalid_output, output}}
    end
  end

  defp parse_remote_workspace_validation(output, expected_key) do
    lines = String.split(IO.iodata_to_binary(output), "\n", trim: true)

    payload =
      Enum.find_value(lines, fn line ->
        case String.split(line, "\t", parts: 3) do
          [@remote_workspace_validation_marker, root, workspace]
          when root != "" and workspace != "" ->
            {root, workspace}

          _ ->
            nil
        end
      end)

    case payload do
      {root, workspace} ->
        case validate_remote_workspace_payload(root, workspace, expected_key) do
          :ok -> {:ok, workspace}
          {:error, _reason} = error -> error
        end

      _ ->
        {:error, {:remote_workspace_validation_failed, :invalid_output, output}}
    end
  end

  defp validate_remote_workspace_payload(root, workspace, expected_key)
       when is_binary(root) and is_binary(workspace) and is_binary(expected_key) do
    cond do
      Path.type(root) != :absolute or Path.type(workspace) != :absolute ->
        {:error, {:remote_workspace_validation_failed, :non_absolute, root, workspace}}

      Path.dirname(workspace) != root ->
        {:error, {:remote_workspace_validation_failed, :outside_root, root, workspace}}

      Path.basename(workspace) != expected_key ->
        {:error, {:remote_workspace_validation_failed, :unexpected_key, expected_key, workspace}}

      true ->
        :ok
    end
  end

  defp run_remote_command(worker_host, script, timeout_ms)
       when is_binary(worker_host) and is_binary(script) and is_integer(timeout_ms) and timeout_ms > 0 do
    task =
      Task.async(fn ->
        SSH.run(worker_host, script, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:workspace_hook_timeout, "remote_command", timeout_ms}}
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    %{
      issue_id: issue_id,
      issue_identifier: identifier || "issue"
    }
  end

  defp issue_context(identifier) when is_binary(identifier) do
    %{
      issue_id: nil,
      issue_identifier: identifier
    }
  end

  defp issue_context(_identifier) do
    %{
      issue_id: nil,
      issue_identifier: "issue"
    }
  end

  defp issue_log_context(%{issue_id: issue_id, issue_identifier: issue_identifier}) do
    "issue_id=#{issue_id || "n/a"} issue_identifier=#{issue_identifier || "issue"}"
  end
end
