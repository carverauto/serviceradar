defmodule ServiceRadar.EventWriter.HostSliceSubscriber do
  @moduledoc """
  NATS core subscriber for `flow.host-slice.>`.

  Decodes incoming `Flowpb.AttributedFlowMessage` payloads (attribution field
  empty) published by the rust flow-collector for agents advertising
  `host-network-visibility`, extracts the agent id from the subject suffix,
  and forwards each record to
  `ServiceRadar.EventWriter.AttributedFlowJoiner.put_host_slice/3` for the
  5-tuple join.

  This is a core-NATS subscription (not a durable JetStream consumer) — host
  slice messages are best-effort joins, so dropping in-flight messages on a
  reconnect is acceptable. The partition-core NATS creds must grant
  `subscribe_allow: ["flow.host-slice.>"]`.
  """

  use GenServer

  alias Flowpb.AttributedFlowMessage
  alias Flowpb.FlowMessage
  alias ServiceRadar.EventWriter.AttributedFlowJoiner
  alias ServiceRadar.NATS.Connection

  require Logger

  @default_subject "flow.host-slice.>"
  @reconnect_delay 5_000

  @telemetry_decoded [:serviceradar, :event_writer, :attributed_flow, :host_slice_decoded]
  @telemetry_decode_failed [
    :serviceradar,
    :event_writer,
    :attributed_flow,
    :host_slice_decode_failed
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    subject = Keyword.get(opts, :subject, @default_subject)
    joiner = Keyword.get(opts, :joiner, AttributedFlowJoiner)
    send(self(), :subscribe)
    {:ok, %{subject: subject, sid: nil, joiner: joiner}}
  end

  @impl true
  def handle_info(:subscribe, %{subject: subject} = state) do
    case Connection.get() do
      {:ok, conn} ->
        case Gnat.sub(conn, self(), subject) do
          {:ok, sid} ->
            Logger.info(
              "HostSliceSubscriber subscribed to NATS subject",
              subject: subject,
              sid: sid
            )

            Process.monitor(conn)
            {:noreply, %{state | sid: sid}}

          {:error, reason} ->
            Logger.warning(
              "HostSliceSubscriber subscribe failed; will retry",
              subject: subject,
              reason: inspect(reason)
            )

            Process.send_after(self(), :subscribe, @reconnect_delay)
            {:noreply, state}
        end

      {:error, reason} ->
        Logger.debug(
          "HostSliceSubscriber NATS not connected; will retry",
          reason: inspect(reason)
        )

        Process.send_after(self(), :subscribe, @reconnect_delay)
        {:noreply, state}
    end
  end

  def handle_info({:msg, %{body: body, topic: subject}}, state) do
    handle_host_slice(body, subject, state)
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.warning("HostSliceSubscriber NATS connection down; resubscribing",
      reason: inspect(reason)
    )

    Process.send_after(self(), :subscribe, @reconnect_delay)
    {:noreply, %{state | sid: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Internal

  defp handle_host_slice(body, subject, %{joiner: joiner}) when is_binary(body) do
    agent_id = agent_id_from_subject(subject)

    case decode(body) do
      %AttributedFlowMessage{flow: %FlowMessage{}} = msg ->
        :telemetry.execute(@telemetry_decoded, %{count: 1}, %{
          agent_id: agent_id,
          subject: subject
        })

        joiner_module(joiner).put_host_slice(msg, agent_id, [])

      :error ->
        :telemetry.execute(@telemetry_decode_failed, %{count: 1}, %{
          agent_id: agent_id,
          subject: subject
        })

        :ok
    end
  end

  defp handle_host_slice(_body, _subject, _state), do: :ok

  defp joiner_module(mod) when is_atom(mod), do: mod
  defp joiner_module(_), do: AttributedFlowJoiner

  defp decode(binary) do
    case AttributedFlowMessage.decode(binary) do
      {:ok, %AttributedFlowMessage{} = msg} -> msg
      %AttributedFlowMessage{} = msg -> msg
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp agent_id_from_subject(subject) when is_binary(subject) do
    case String.split(subject, ".", parts: 3) do
      ["flow", "host-slice", agent_id] when agent_id != "" -> agent_id
      _ -> nil
    end
  end

  defp agent_id_from_subject(_), do: nil
end
