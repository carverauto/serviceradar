defmodule ServiceRadarNVR.Delivery do
  @moduledoc """
  Delivery of one retained intent or one recovery-page entry. One task, three attempts, thirty seconds.

  The worker owns its deadline even after caller loss. Acceptance is an unknown
  outcome after a timeout; retry the retained operation, never mint a replacement.
  This acknowledgement does not register a qualified copy or authorize deletion.
  """

  alias ServiceRadarNVR.Capacity
  alias ServiceRadarNVR.DeliveryHTTP
  alias ServiceRadarRecordingMetadata.LocalPublicationAcknowledgement
  alias ServiceRadarRecordingMetadata.LocalPublicationIntent

  @timeout 30_000

  def run(block_id) do
    with {:ok, pid, reply} <- start(fn -> deliver(block_id) end) do
      try do
        await(pid, reply)
      after
        :erlang.unalias(reply)
      end
    end
  end

  @doc false
  def start_pending(cursor), do: start(fn -> pending(cursor) end)

  defp start(operation) do
    reply = :erlang.alias([:reply])

    result =
      try do
        Task.Supervisor.start_child(ServiceRadarNVR.DeliveryTasks, fn -> execute(reply, operation) end)
      catch
        :exit, _ -> {:error, :unavailable}
      end

    case result do
      {:ok, pid} ->
        {:ok, pid, reply}

      {:error, reason} ->
        :erlang.unalias(reply)
        error = if reason == :max_children, do: :nvr_delivery_capacity, else: :nvr_delivery_unavailable
        {:error, error}
    end
  end

  defp execute(reply, operation) do
    {:ok, timer} = :timer.exit_after(@timeout, {:shutdown, :nvr_delivery_timeout})

    try do
      send(reply, {reply, operation.()})
    after
      :timer.cancel(timer)
    end
  end

  defp pending(cursor) do
    with {:ok, page} <- ServiceRadarNVR.publication_page(cursor, 1) do
      {block_id, outcome} = visit(page.entries)
      {:ok, %{next_cursor: page.next_cursor, block_id: block_id, outcome: outcome}}
    end
  end

  defp visit([]), do: {nil, :empty}

  defp visit([%{state: :pending, block_id: block_id}]) do
    outcome =
      case deliver(block_id) do
        {:ok, _ack} -> :delivered
        {:error, _} = error -> error
      end

    {block_id, outcome}
  end

  defp visit([%{state: :unresolved, block_id: block_id, reason: reason}]), do: {block_id, {:unresolved, reason}}

  defp visit([%{state: state, block_id: block_id}]), do: {block_id, state}

  defp deliver(block_id) do
    with {:ok, config} <- Capacity.delivery_config(),
         {:ok, bytes} <- ServiceRadarNVR.publication_intent(block_id),
         {:ok, intent} <- LocalPublicationIntent.decode(bytes),
         reference = %{
           operation_id: intent["operation_id"],
           recording_block_id: intent["recording_block_id"],
           descriptor_sha256: intent["descriptor_sha256"]
         },
         {:ok, ^bytes} <- ServiceRadarNVR.prepare_publication(block_id, reference),
         {:ok, ack} <- attempt(config, bytes, 1),
         :ok <- LocalPublicationAcknowledgement.validate(ack, bytes) do
      ServiceRadarNVR.acknowledge_publication(block_id, ack)
    end
  end

  defp attempt(config, bytes, number) do
    result = with :ok <- Capacity.recovery_ready(), do: DeliveryHTTP.post(config, bytes)

    if number < 3 and retry?(result) do
      Process.sleep(number * 100)
      attempt(config, bytes, number + 1)
    else
      result
    end
  end

  defp retry?({:error, :nvr_delivery_transport}), do: true
  defp retry?({:error, {:nvr_delivery_status, status}}), do: status in [408, 429] or status in 500..599
  defp retry?(_), do: false

  defp await(pid, reply) do
    monitor = Process.monitor(pid)

    try do
      receive do
        {^reply, result} -> result
        {:DOWN, ^monitor, :process, ^pid, {:shutdown, :nvr_delivery_timeout}} -> {:error, :nvr_delivery_timeout}
        {:DOWN, ^monitor, :process, ^pid, _} -> {:error, :nvr_delivery_unavailable}
      after
        @timeout + 1_000 ->
          :erlang.unalias(reply)
          Process.exit(pid, :kill)
          {:error, :nvr_delivery_timeout}
      end
    after
      Process.demonitor(monitor, [:flush])
    end
  end
end
