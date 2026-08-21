defmodule SymphonyElixir.InstanceLock do
  @moduledoc """
  Holds a host-local loopback socket for the lifetime of the agent runtime.

  This is a fail-closed singleton fence for a single-host deployment. It does
  not provide multi-host or high-availability coordination.
  """

  use GenServer

  alias SymphonyElixir.{AttemptFuse, Config}

  @loopback {127, 0, 0, 1}

  @spec start_link(keyword()) :: GenServer.on_start() | :ignore
  def start_link(opts \\ []) do
    attempt_fuse =
      Keyword.get_lazy(opts, :attempt_fuse, fn ->
        Config.settings!() |> AttemptFuse.snapshot()
      end)

    port = Keyword.get(opts, :port, attempt_fuse.instance_lock_port)

    case port do
      value when is_integer(value) and value > 0 and value < 65_536 ->
        GenServer.start_link(
          __MODULE__,
          {value, attempt_fuse},
          name: Keyword.get(opts, :name, __MODULE__)
        )

      nil ->
        :ignore

      _ ->
        {:error, :invalid_instance_lock_port}
    end
  end

  @spec attempt_fuse(GenServer.server()) :: AttemptFuse.snapshot()
  def attempt_fuse(server \\ __MODULE__), do: GenServer.call(server, :attempt_fuse)

  @spec operational?(GenServer.server()) :: boolean()
  def operational?(server \\ __MODULE__), do: GenServer.call(server, :operational?)

  @spec trip(GenServer.server(), term()) :: :ok
  def trip(server \\ __MODULE__, reason), do: GenServer.call(server, {:trip, reason})

  @impl true
  def init({port, attempt_fuse}) do
    options = [
      :binary,
      active: false,
      ip: @loopback,
      reuseaddr: false,
      backlog: 1
    ]

    case :gen_tcp.listen(port, options) do
      {:ok, socket} ->
        {:ok, %{port: port, socket: socket, attempt_fuse: attempt_fuse, trip_reason: nil}}

      {:error, reason} ->
        {:stop, {:instance_lock_unavailable, port, reason}}
    end
  end

  @impl true
  def handle_call(:attempt_fuse, _from, state), do: {:reply, state.attempt_fuse, state}

  def handle_call(:operational?, _from, state), do: {:reply, is_nil(state.trip_reason), state}

  def handle_call({:trip, reason}, _from, state) do
    {:reply, :ok, %{state | trip_reason: state.trip_reason || reason}}
  end

  @impl true
  def terminate(_reason, %{socket: socket}) do
    :gen_tcp.close(socket)
    :ok
  end
end
