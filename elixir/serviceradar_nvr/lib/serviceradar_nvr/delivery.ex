defmodule ServiceRadarNVR.Delivery do
  @moduledoc """
  Explicit delivery of one retained intent. One task, three attempts, thirty seconds.

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
    reply = :erlang.alias([:reply])

    try do
      case Task.Supervisor.start_child(ServiceRadarNVR.DeliveryTasks, fn -> execute(reply, block_id) end) do
        {:ok, pid} -> await(pid, reply)
        {:error, :max_children} -> {:error, :nvr_delivery_capacity}
        {:error, _} -> {:error, :nvr_delivery_unavailable}
      end
    catch
      :exit, _ -> {:error, :nvr_delivery_unavailable}
    after
      :erlang.unalias(reply)
    end
  end

  defp execute(reply, block_id) do
    {:ok, timer} = :timer.exit_after(@timeout, {:shutdown, :nvr_delivery_timeout})

    try do
      send(reply, {reply, deliver(block_id)})
    after
      :timer.cancel(timer)
    end
  end

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
    result = DeliveryHTTP.post(config, bytes)

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
