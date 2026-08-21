defmodule SymphonyElixir.InstanceLockTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.InstanceLock

  test "only one host-local runtime can hold the configured loopback lock" do
    Process.flag(:trap_exit, true)

    port = available_port()
    first_name = Module.concat(__MODULE__, "First#{System.unique_integer([:positive])}")
    second_name = Module.concat(__MODULE__, "Second#{System.unique_integer([:positive])}")

    assert {:ok, first} = InstanceLock.start_link(port: port, name: first_name)

    assert {:error, {:instance_lock_unavailable, ^port, :eaddrinuse}} =
             InstanceLock.start_link(port: port, name: second_name)

    GenServer.stop(first)
    assert {:ok, second} = InstanceLock.start_link(port: port, name: second_name)
    GenServer.stop(second)
  end

  test "a missing lock setting preserves upstream operation and invalid values fail" do
    assert :ignore = InstanceLock.start_link(port: nil)
    assert {:error, :invalid_instance_lock_port} = InstanceLock.start_link(port: 0)
    assert {:error, :invalid_instance_lock_port} = InstanceLock.start_link(port: 70_000)
  end

  defp available_port do
    {:ok, socket} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        ip: {127, 0, 0, 1},
        reuseaddr: false
      ])

    {:ok, {_address, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
