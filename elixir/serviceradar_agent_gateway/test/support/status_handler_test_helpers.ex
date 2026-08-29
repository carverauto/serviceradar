defmodule ServiceRadarAgentGateway.StatusHandlerTestHelpers do
  @moduledoc """
  Register/unregister `ServiceRadar.StatusHandler` without racing process death.

  A stub that is killed in one `on_exit` is auto-unregistered by the VM. A later
  `on_exit` that saw `Process.whereis/1` return a pid can then call
  `Process.unregister/1` after the name is gone. OTP 28 raises ArgumentError
  ("not a pid") for that, which is how AddonPartitionStampingTest failed under
  `bazel test //...` with a live stub kill.
  """

  @spec unregister_quietly(atom()) :: :ok
  def unregister_quietly(name) when is_atom(name) do
    try do
      Process.unregister(name)
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  @spec restore(atom(), pid() | nil) :: :ok
  def restore(name, previous) when is_atom(name) do
    unregister_quietly(name)

    if is_pid(previous) and Process.alive?(previous) do
      try do
        Process.register(previous, name)
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end

  @spec kill_and_await(pid()) :: :ok
  def kill_and_await(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        1_000 -> :ok
      end
    else
      :ok
    end
  end
end
