defmodule ServiceRadar.FlowAttribution.Observations do
  @moduledoc """
  The JetStream contract for netprobe process attribution observations.

  Core publishes each admitted batch on `flows.attribution.observations`, in the
  dedicated `flows` stream next to `flows.raw.*`, and EventWriter's
  `FlowAttributionObservations` processor loads the rows into the StarRocks
  table `flow_process_attribution_observations`. Core never writes the
  observations to a database itself.

  One message carries at most `@max_rows_per_message` rows and at most
  `@max_message_bytes` bytes when encoded, so a large edge batch stays under
  the NATS payload limit. Each row's `cmdline` is truncated UTF-8-safely to
  the warehouse column width before encoding, so one row can never exceed the
  budget on its own. The publish waits for the JetStream PubAck: a message
  the server refused (for example a subject the NATS user may not publish)
  fails the batch instead of vanishing.
  """

  alias ServiceRadar.NATS.JetStreamPublish

  @subject "flows.attribution.observations"
  @max_rows_per_message 500
  @max_message_bytes 524_288
  @max_cmdline_bytes 65_533

  @spec subject() :: String.t()
  def subject, do: @subject

  @doc """
  Publishes observation rows (as built by `EventRows.from_event/3`).

  `:publish` replaces the JetStream publish, `(subject, body -> :ok | {:error, term})`.
  """
  @spec publish([map()], keyword()) :: :ok | {:error, term()}
  def publish(rows, opts \\ []) when is_list(rows) do
    publish = Keyword.get(opts, :publish, &JetStreamPublish.publish/2)

    rows
    |> Enum.map(&bound_row/1)
    |> split_messages()
    |> Enum.reduce_while(:ok, fn chunk, :ok ->
      case publish.(@subject, Jason.encode!(%{"rows" => chunk})) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
        other -> {:halt, {:error, {:unexpected_publish_result, other}}}
      end
    end)
  end

  defp split_messages([]), do: []

  defp split_messages(rows) do
    {chunks, current} =
      Enum.reduce(rows, {[], []}, fn row, {done, current} ->
        candidate = [row | current]

        if length(candidate) > @max_rows_per_message or
             message_bytes(candidate) > @max_message_bytes do
          case current do
            [] -> {[Enum.reverse(candidate) | done], []}
            _ -> {[Enum.reverse(current) | done], [row]}
          end
        else
          {done, candidate}
        end
      end)

    chunks =
      case current do
        [] -> chunks
        _ -> [Enum.reverse(current) | chunks]
      end

    Enum.reverse(chunks)
  end

  defp message_bytes(chunk) do
    chunk |> Enum.reverse() |> then(&%{"rows" => &1}) |> Jason.encode!() |> byte_size()
  end

  defp bound_row(%{cmdline: cmdline} = row) when is_binary(cmdline) do
    %{row | cmdline: truncate_binary(cmdline, @max_cmdline_bytes)}
  end

  defp bound_row(%{"cmdline" => cmdline} = row) when is_binary(cmdline) do
    %{row | "cmdline" => truncate_binary(cmdline, @max_cmdline_bytes)}
  end

  defp bound_row(row), do: row

  defp truncate_binary(value, max_bytes) do
    value |> binary_part(0, min(max_bytes, byte_size(value))) |> trim_incomplete_utf8()
  end

  defp trim_incomplete_utf8(value) do
    if String.valid?(value) do
      value
    else
      trim_incomplete_utf8(binary_part(value, 0, byte_size(value) - 1))
    end
  end

  @doc "Decodes one observation message into its rows, or `:error`."
  @spec decode(binary()) :: {:ok, [map()]} | :error
  def decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"rows" => rows}} when is_list(rows) -> {:ok, Enum.filter(rows, &valid_row?/1)}
      _ -> :error
    end
  end

  def decode(_body), do: :error

  # The table's key and NOT NULL columns; a row without them would be filtered
  # out of the Stream Load, failing the whole batch's row count.
  defp valid_row?(%{
         "observed_at" => observed_at,
         "partition" => partition,
         "proto" => proto,
         "local_ip" => local_ip,
         "local_port" => local_port,
         "remote_ip" => remote_ip,
         "remote_port" => remote_port,
         "attribution_key" => key
       }) do
    is_binary(observed_at) and is_binary(partition) and is_integer(proto) and
      is_binary(local_ip) and is_integer(local_port) and is_binary(remote_ip) and
      is_integer(remote_port) and is_binary(key)
  end

  defp valid_row?(_row), do: false
end
