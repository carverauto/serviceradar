defmodule ServiceRadarWebNGWeb.Channels.ArrowStreamHandler do
  @moduledoc """
  A raw WebSock handler designed specifically to receive high-frequency, 
  zero-copy Apache Arrow binary IPC frames from iOS FieldSurvey agents.
  """
  @behaviour WebSock

  require Logger

  @impl true
  def init(options) do
    session_id = Keyword.fetch!(options, :session_id)
    user_id = Keyword.fetch!(options, :user_id)

    Logger.info("ArrowStreamHandler initialized [session: #{session_id}, user: #{user_id}]")

    {:ok, %{session_id: session_id, user_id: user_id, message_count: 0, bytes_received: 0}}
  end

  @impl true
  def handle_in({data, [opcode: :binary]}, state) do
    process_binary_frame(data, state)
  end

  @impl true
  def handle_in({data, [opcode: :text]}, state) do
    Logger.warning("Received unexpected text payload (size: #{byte_size(data)})")
    {:ok, state}
  end

  defp process_binary_frame(data, state) do
    new_state = %{
      state
      | message_count: state.message_count + 1,
        bytes_received: state.bytes_received + byte_size(data)
    }

    # Pass the binary frame to the Rust NIF for zero-copy deserialization
    case ServiceRadarWebNG.Topology.Native.decode_arrow_payload(data) do
      {:ok, samples} ->
        Logger.debug("Decoded #{length(samples)} cyber-physical samples via Arrow IPC")

        # Stream to TimescaleDB & PostGIS via Ash generic action.
        ServiceRadar.Spatial.SurveySample
        |> Ash.ActionInput.for_action(:bulk_insert, %{
          session_id: state.session_id,
          samples: samples
        })
        |> Ash.run_action!(domain: ServiceRadar.Spatial)

        {:ok, new_state}

      {:error, reason} ->
        Logger.error("Arrow IPC Decode Failed: #{inspect(reason)}")
        {:ok, new_state}
    end
  end

  @impl true
  def handle_info(message, state) do
    Logger.debug("ArrowStreamHandler received internal message: #{inspect(message)}")
    {:ok, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info(
      "ArrowStreamHandler closed [session: #{state.session_id}, reason: #{inspect(reason)}, msgs: #{state.message_count}, bytes: #{state.bytes_received}]"
    )

    :ok
  end
end
