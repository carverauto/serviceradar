defmodule ServiceRadar.FlowAttribution.Observations do
  @moduledoc """
  The JetStream contract for netprobe process attribution observations.

  Core publishes each admitted batch on `flows.attribution.observations`, in the
  dedicated `flows` stream next to `flows.raw.*`, and EventWriter's
  `FlowAttributionObservations` processor loads the rows into the StarRocks
  table `flow_process_attribution_observations`. Core never writes the
  observations to a database itself.

  One message carries at most `@max_rows_per_message` rows, so a large edge
  batch stays well under the NATS payload limit. The publish waits for the
  JetStream PubAck: a message the server refused (for example a subject the
  NATS user may not publish) fails the batch instead of vanishing.
  """

  alias ServiceRadar.NATS.JetStreamPublish

  @subject "flows.attribution.observations"
  @max_rows_per_message 500

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
    |> Enum.chunk_every(@max_rows_per_message)
    |> Enum.reduce_while(:ok, fn chunk, :ok ->
      case publish.(@subject, Jason.encode!(%{"rows" => chunk})) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
        other -> {:halt, {:error, {:unexpected_publish_result, other}}}
      end
    end)
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
