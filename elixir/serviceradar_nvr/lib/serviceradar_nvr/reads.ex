defmodule ServiceRadarNVR.Reads do
  @moduledoc """
  Admission and lifetime limits for local read work, independent of recording slots.

  The task supervisor admits at most four operations without a waiting queue.
  Each admitted task expires after ten seconds, including when its caller exits.
  Returned bytes belong to the caller; this does not budget downstream buffers.
  """

  @timeout 10_000

  def run(operation) when is_function(operation, 0) do
    reply = :erlang.alias([:reply])

    try do
      case Task.Supervisor.start_child(ServiceRadarNVR.ReadTasks, fn -> execute(reply, operation) end) do
        {:ok, pid} -> await(pid, reply)
        {:error, :max_children} -> {:error, :nvr_read_capacity}
        {:error, _} -> {:error, :nvr_read_unavailable}
      end
    catch
      :exit, _ -> {:error, :nvr_read_unavailable}
    after
      :erlang.unalias(reply)
    end
  end

  defp execute(reply, operation) do
    # A caller-owned receive timeout cannot retire work after that caller dies.
    {:ok, timer} = :timer.exit_after(@timeout, {:shutdown, :nvr_read_timeout})

    try do
      result =
        with :ok <- ServiceRadarNVR.Capacity.recovery_ready(),
             result = operation.(),
             :ok <- ServiceRadarNVR.Capacity.recovery_ready(),
             do: result

      send(reply, {reply, result})
    after
      :timer.cancel(timer)
    end
  end

  defp await(pid, reply) do
    monitor = Process.monitor(pid)

    try do
      receive do
        {^reply, result} ->
          result

        {:DOWN, ^monitor, :process, ^pid, {:shutdown, :nvr_read_timeout}} ->
          {:error, :nvr_read_timeout}

        {:DOWN, ^monitor, :process, ^pid, _reason} ->
          {:error, :nvr_read_unavailable}
      after
        @timeout + 1_000 -> expire(pid, reply)
      end
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  defp expire(pid, reply) do
    :erlang.unalias(reply)
    Process.exit(pid, :kill)

    receive do
      {^reply, _late} -> :ok
    after
      0 -> :ok
    end

    {:error, :nvr_read_timeout}
  end
end
