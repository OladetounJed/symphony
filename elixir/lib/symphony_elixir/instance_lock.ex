defmodule SymphonyElixir.InstanceLock do
  @moduledoc """
  Holds a host-local loopback socket for the lifetime of the agent runtime.

  This is a fail-closed singleton fence for a single-host deployment. It does
  not provide multi-host or high-availability coordination.
  """

  use GenServer

  alias SymphonyElixir.Config

  @loopback {127, 0, 0, 1}

  @spec start_link(keyword()) :: GenServer.on_start() | :ignore
  def start_link(opts \\ []) do
    port = Keyword.get_lazy(opts, :port, fn -> Config.settings!().agent.instance_lock_port end)

    case port do
      value when is_integer(value) and value > 0 and value < 65_536 ->
        GenServer.start_link(__MODULE__, value, name: Keyword.get(opts, :name, __MODULE__))

      nil ->
        :ignore

      _ ->
        {:error, :invalid_instance_lock_port}
    end
  end

  @impl true
  def init(port) do
    options = [
      :binary,
      active: false,
      ip: @loopback,
      reuseaddr: false,
      backlog: 1
    ]

    case :gen_tcp.listen(port, options) do
      {:ok, socket} -> {:ok, %{port: port, socket: socket}}
      {:error, reason} -> {:stop, {:instance_lock_unavailable, port, reason}}
    end
  end

  @impl true
  def terminate(_reason, %{socket: socket}) do
    :gen_tcp.close(socket)
    :ok
  end
end
