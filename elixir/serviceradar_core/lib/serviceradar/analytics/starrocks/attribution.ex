defmodule ServiceRadar.Analytics.StarRocks.Attribution do
  @moduledoc """
  Versioned flow-attribution updates for the StarRocks destination.

  Traffic totals are not part of the payload. A lower attribution_version must
  not overwrite a higher one on redelivery.

  `time` travels with every update because it is part of the warehouse table's
  primary key (the partition column must be), and a StarRocks partial update
  has to carry the whole key.
  """

  alias ServiceRadar.NATS.Connection

  @subject "events.flow.attribution"
  @load_columns [
    "id",
    "time",
    "event_type",
    "attribution_version",
    "pid",
    "comm",
    "cmdline",
    "workload_identity"
  ]

  @spec jetstream_subject() :: String.t()
  def jetstream_subject, do: @subject

  @spec load_columns() :: [String.t()]
  def load_columns, do: @load_columns

  @spec update_event(map(), pos_integer()) :: map()
  def update_event(row, version) when is_map(row) and is_integer(version) and version > 0 do
    %{
      "id" => field(row, :id),
      "time" => field(row, :time),
      "attribution_version" => version,
      "pid" => field(row, :pid),
      "comm" => field(row, :comm),
      "cmdline" => field(row, :cmdline),
      "workload_identity" => field(row, :workload_identity)
    }
  end

  @spec apply_monotonic(non_neg_integer(), non_neg_integer()) :: :apply | :ignore
  def apply_monotonic(existing_version, incoming_version)
      when is_integer(existing_version) and is_integer(incoming_version) do
    if incoming_version > existing_version, do: :apply, else: :ignore
  end

  @spec publish_updates([map()], keyword()) :: :ok | {:error, term()}
  def publish_updates(rows, opts \\ []) when is_list(rows) do
    publisher = Keyword.get(opts, :publish, &default_publish/1)

    Enum.reduce_while(rows, :ok, fn row, _acc ->
      id = field(row, :id)
      version = field(row, :attribution_version)

      if is_binary(id) and id != "" and is_integer(version) and version > 0 and
           field(row, :time) != nil do
        case publisher.(%{subject: @subject, payload: update_event(row, version)}) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
          other -> {:halt, {:error, {:unexpected_publish_result, other}}}
        end
      else
        {:halt, {:error, :unresolved_flow_attribution}}
      end
    end)
  end

  defp default_publish(%{subject: subject, payload: payload}) do
    with {:ok, body} <- Jason.encode(payload),
         {:ok, conn} <- Connection.get(),
         {:ok, %{body: ack}} <- Gnat.request(conn, subject, body, receive_timeout: 5_000),
         {:ok, %{"stream" => stream, "seq" => seq}} when is_binary(stream) and is_integer(seq) <-
           Jason.decode(ack) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_jetstream_ack, other}}
    end
  end

  defp field(row, key) when is_atom(key) do
    Map.get(row, key) || Map.get(row, Atom.to_string(key))
  end
end
