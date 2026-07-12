defmodule ServiceRadar.Observability.PluginResultSlot do
  @moduledoc false

  alias ServiceRadar.Observability.PluginResultReportedMarker

  @block_width_microseconds PluginResultReportedMarker.block_width_microseconds()
  @allocation_block_count 16_384
  @allocation_window_microseconds PluginResultReportedMarker.allocation_window_microseconds()
  @insert_attempts 1_024

  @doc false
  def block_width_microseconds, do: @block_width_microseconds

  @doc false
  def allocation_window_microseconds, do: @allocation_window_microseconds

  @doc false
  def insert_attempts, do: @insert_attempts

  @doc false
  def logical_observed_at(row) when is_map(row) do
    PluginResultReportedMarker.logical_observed_at(row)
  end

  @doc false
  def logical_observation_timestamp(row) when is_map(row) do
    row |> logical_observed_at() |> DateTime.to_iso8601()
  end

  @doc false
  def block_base(row, 0) when is_map(row) do
    row |> logical_observed_at() |> latest_complete_block_base()
  end

  def block_base(row, attempt)
      when is_map(row) and is_integer(attempt) and attempt > 0 and attempt < @insert_attempts do
    block =
      row
      |> initial_nonzero_block()
      |> then(&(&1 + attempt - 1))
      |> then(&(1 + rem(&1 - 1, @allocation_block_count - 1)))

    row
    |> logical_observed_at()
    |> latest_complete_block_base()
    |> DateTime.add(-block * @block_width_microseconds, :microsecond)
  end

  @doc false
  def within_allocation_window?(physical_timestamp, logical_observed_at) do
    offset = DateTime.diff(physical_timestamp, logical_observed_at, :microsecond)
    offset >= -@allocation_window_microseconds and offset <= 0
  end

  defp initial_nonzero_block(row) do
    seed =
      {
        row.agent_id,
        row.gateway_id,
        row.partition,
        row.service_type,
        row.service_name,
        row.service_id,
        logical_observation_timestamp(row),
        row.available,
        row.message,
        PluginResultReportedMarker.payload_digest_without_marker(row.details)
      }

    <<value::unsigned-big-integer-size(64), _::binary>> =
      :crypto.hash(:sha256, :erlang.term_to_binary(seed, [:deterministic]))

    1 + rem(value, @allocation_block_count - 1)
  end

  defp latest_complete_block_base(observed_at) do
    timestamp = DateTime.to_unix(observed_at, :microsecond)

    timestamp
    |> Kernel.-(@block_width_microseconds - 1)
    |> Integer.floor_div(@block_width_microseconds)
    |> Kernel.*(@block_width_microseconds)
    |> DateTime.from_unix!(:microsecond)
  end
end
