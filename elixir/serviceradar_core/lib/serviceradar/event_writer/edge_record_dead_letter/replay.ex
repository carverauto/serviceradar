defmodule ServiceRadar.EventWriter.EdgeRecordDeadLetter.Replay do
  @moduledoc """
  Lists dead-lettered edge records and replays them after the fault is fixed.

  Replay republishes each record's original bytes and transport headers, with a PubAck, to the
  subject it was first delivered on (`Sr-Edge-Dlq-Source-Subject`), and deletes the dead-letter
  message only after that PubAck. The EventWriter consumer then projects the record as it does
  any delivery:

    * a record whose earlier attempt never committed is projected now;
    * a record the ledger already holds is a replay and writes nothing, so replaying the same
      message twice, or one whose delete failed, changes nothing;
    * a record that fails again goes back through its retries and is dead-lettered again,
      so a replay never loses it.

  The republish restores the record's own `Nats-Msg-Id`. If the edge-record stream reports it
  as a duplicate (a message with that id was stored within its duplicate window, so nothing new
  was stored), the dead-letter message is kept and the entry says `:source_duplicate`; replay it
  again once the window has passed.

  Run it on a core node, where `ServiceRadar.NATS.Connection` is connected:

      bin/serviceradar_core_elx rpc 'IO.inspect(ServiceRadar.EventWriter.EdgeRecordDeadLetter.Replay.list(limit: 20))'
      bin/serviceradar_core_elx rpc 'IO.inspect(ServiceRadar.EventWriter.EdgeRecordDeadLetter.Replay.replay(limit: 20))'

  Options, for both:

    * `:subject` -- a filter on the dead-letter subjects, default every bulk record
      (`telemetry.edge-record-dlq.v1.bulk.>`); one contract is
      `telemetry.edge-record-dlq.v1.bulk.*.serviceradar_metrics_batch.v1`
    * `:from_sequence` -- the first dead-letter stream sequence to read (default 1)
    * `:sequences` -- exactly these sequences, instead of `:subject`/`:from_sequence`
    * `:limit` -- at most this many messages (default 100)
    * `:stream` -- the dead-letter stream (default `TELEMETRY_EDGE_RECORD_DLQ_V1_BULK`)
    * `:request` -- `(subject, body, opts -> {:ok, %{body: binary}} | {:error, term})`, a NATS
      request on a connection the caller owns; default `ServiceRadar.NATS.Connection`

  A walk over `:subject` reads only the messages the stream held when it started, so a record
  this replay republishes that is dead-lettered again is left for the next run.

  `replay/1` also takes `:delete` (default `true`): `false` republishes and leaves the
  dead-letter message in place.

  Both return `{:ok, %{entries: [...], next_sequence: n}}`, where each entry names its
  dead-letter sequence, source and failure headers, and, for `replay/1`, its `:result`:
  `:replayed`, `:replayed_kept` (`delete: false`, or the delete failed: see `:delete_error`), or
  `{:error, reason}` (the message is kept). Pass `next_sequence` as `:from_sequence` to continue.
  """

  alias ServiceRadar.Edge.StreamRoute
  alias ServiceRadar.EventWriter.EdgeRecordDeadLetter
  alias ServiceRadar.NATS.Connection
  alias ServiceRadar.NATS.JetStreamPublish

  require Logger

  @stream "TELEMETRY_EDGE_RECORD_DLQ_V1_BULK"
  @subject "telemetry.edge-record-dlq.v1.bulk.>"
  @default_limit 100
  @timeout_ms 5_000

  @doc "Lists dead-lettered records without changing anything. See the moduledoc."
  @spec list(keyword()) ::
          {:ok, %{entries: [map()], next_sequence: pos_integer()}} | {:error, term()}
  def list(opts \\ []), do: walk(opts, &describe/2)

  @doc "Republishes dead-lettered records to their source subjects. See the moduledoc."
  @spec replay(keyword()) ::
          {:ok, %{entries: [map()], next_sequence: pos_integer()}} | {:error, term()}
  def replay(opts \\ []), do: walk(opts, &replay_one/2)

  @doc """
  What replaying a stored dead-letter message publishes: its source subject, the record's
  original bytes, its `Nats-Msg-Id`, and its transport headers without the failure headers,
  fenced with `Nats-Expected-Stream` to its source stream.
  Refuses a message whose source subject is not an edge-record subject that dead-letters.
  """
  @spec republication(%{data: binary(), headers: [{String.t(), String.t()}]}) ::
          {:ok, %{subject: String.t(), body: binary(), msg_id: String.t() | nil, headers: list()}}
          | {:error, term()}
  def republication(%{data: data, headers: headers}) when is_binary(data) do
    {transport, failure} = EdgeRecordDeadLetter.split_headers(headers)
    source = Map.get(failure, "source-subject")

    with {:source, source} when is_binary(source) <- {:source, source},
         {:ok, _route} <- StreamRoute.dead_letter_route(source, nil) do
      {:ok,
       %{
         subject: source,
         body: data,
         msg_id: Map.get(failure, "source-msg-id"),
         headers: transport ++ expected_stream(Map.get(failure, "source-stream"))
       }}
    else
      {:source, _missing} -> {:error, :no_source_subject}
      {:error, reason} -> {:error, reason}
    end
  end

  # Fence the republish to the stream the record came from, as the gateway fenced the original.
  defp expected_stream(stream) when is_binary(stream) and stream != "",
    do: [{"Nats-Expected-Stream", stream}]

  defp expected_stream(_stream), do: []

  defp walk(opts, fun) do
    request = Keyword.get(opts, :request) || (&connection_request/3)
    stream = Keyword.get(opts, :stream, @stream)
    limit = Keyword.get(opts, :limit, @default_limit)
    ctx = %{request: request, stream: stream, opts: opts}

    case Keyword.get(opts, :sequences) do
      sequences when is_list(sequences) ->
        walk_sequences(ctx, Enum.take(sequences, limit), fun, [])

      nil ->
        from = Keyword.get(opts, :from_sequence, 1)

        # Only the messages already held when the walk starts: a record a replay republishes
        # that fails again is dead-lettered after it, and must not be replayed in the same run.
        with {:ok, last} <- last_sequence(ctx) do
          filter = Keyword.get(opts, :subject, @subject)
          walk_subject(Map.put(ctx, :last, last), filter, from, limit, fun, [])
        end
    end
  end

  defp last_sequence(ctx) do
    case api_request(ctx, "$JS.API.STREAM.INFO.#{ctx.stream}", %{}) do
      {:ok, %{"state" => %{"last_seq" => last}}} when is_integer(last) -> {:ok, last}
      {:ok, other} -> {:error, {:unexpected_reply, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp walk_sequences(_ctx, [], _fun, acc),
    do: {:ok, %{entries: Enum.reverse(acc), next_sequence: next_after(acc)}}

  defp walk_sequences(ctx, [seq | rest], fun, acc) do
    case get_message(ctx, %{"seq" => seq}) do
      {:ok, message} -> walk_sequences(ctx, rest, fun, [fun.(ctx, message) | acc])
      :none -> walk_sequences(ctx, rest, fun, [%{dlq_sequence: seq, result: :not_found} | acc])
      {:error, reason} -> {:error, reason}
    end
  end

  defp walk_subject(_ctx, _filter, from, 0, _fun, acc),
    do: {:ok, %{entries: Enum.reverse(acc), next_sequence: from}}

  defp walk_subject(%{last: last}, _filter, from, _limit, _fun, acc) when from > last,
    do: {:ok, %{entries: Enum.reverse(acc), next_sequence: from}}

  defp walk_subject(ctx, filter, from, limit, fun, acc) do
    case get_message(ctx, %{"seq" => from, "next_by_subj" => filter}) do
      {:ok, %{seq: seq}} when seq > ctx.last ->
        {:ok, %{entries: Enum.reverse(acc), next_sequence: from}}

      {:ok, message} ->
        walk_subject(ctx, filter, message.seq + 1, limit - 1, fun, [fun.(ctx, message) | acc])

      :none ->
        {:ok, %{entries: Enum.reverse(acc), next_sequence: from}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp next_after([]), do: 1
  defp next_after(acc), do: (acc |> Enum.map(& &1.dlq_sequence) |> Enum.max()) + 1

  defp describe(_ctx, message) do
    {_transport, failure} = EdgeRecordDeadLetter.split_headers(message.headers)

    %{
      dlq_sequence: message.seq,
      dlq_subject: message.subject,
      stored_at: message.time,
      bytes: byte_size(message.data),
      failure: failure
    }
  end

  defp replay_one(ctx, message) do
    entry = describe(ctx, message)

    case republish(ctx, message) do
      :ok -> Map.merge(entry, delete_after_replay(ctx, message.seq))
      {:error, reason} -> Map.put(entry, :result, {:error, reason})
    end
  end

  defp republish(ctx, message) do
    with {:ok, publication} <- republication(message),
         {:ok, ack} <-
           JetStreamPublish.publish_acked(publication.subject, publication.body,
             msg_id: publication.msg_id,
             headers: publication.headers,
             request: ctx.request
           ) do
      if ack.duplicate, do: {:error, :source_duplicate}, else: :ok
    end
  end

  defp delete_after_replay(%{opts: opts} = ctx, seq) do
    if Keyword.get(opts, :delete, true) do
      case delete_message(ctx, seq) do
        :ok ->
          %{result: :replayed}

        {:error, reason} ->
          Logger.warning("Replayed edge-record dead-letter could not be deleted",
            dlq_sequence: seq,
            reason: inspect(reason)
          )

          %{result: :replayed_kept, delete_error: reason}
      end
    else
      %{result: :replayed_kept}
    end
  end

  # `$JS.API.STREAM.MSG.GET` with `seq` alone reads that sequence; with `next_by_subj` too, it
  # reads the first message at or after `seq` on that subject filter.
  defp get_message(ctx, query) do
    api = "$JS.API.STREAM.MSG.GET.#{ctx.stream}"

    with {:ok, %{"message" => message}} <- api_request(ctx, api, query),
         {:ok, data} <- decode64(message["data"]),
         {:ok, headers} <- decode_headers(message["hdrs"]) do
      {:ok,
       %{
         seq: message["seq"],
         subject: message["subject"],
         time: message["time"],
         data: data,
         headers: headers
       }}
    else
      {:error, %{"err_code" => 10_037}} -> :none
      {:error, %{"code" => 404}} -> :none
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_reply, other}}
    end
  end

  defp delete_message(ctx, seq) do
    case api_request(ctx, "$JS.API.STREAM.MSG.DELETE.#{ctx.stream}", %{"seq" => seq}) do
      {:ok, %{"success" => true}} -> :ok
      {:ok, other} -> {:error, {:unexpected_reply, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp api_request(ctx, subject, payload) do
    with {:ok, %{body: body}} <-
           ctx.request.(subject, Jason.encode!(payload), receive_timeout: @timeout_ms),
         {:ok, decoded} <- Jason.decode(body) do
      case decoded do
        %{"error" => error} -> {:error, error}
        reply -> {:ok, reply}
      end
    end
  end

  defp decode64(nil), do: {:ok, ""}
  defp decode64(value) when is_binary(value), do: decode64_result(Base.decode64(value))

  defp decode64_result({:ok, data}), do: {:ok, data}
  defp decode64_result(:error), do: {:error, :invalid_base64}

  defp decode_headers(nil), do: {:ok, []}

  defp decode_headers(value) do
    with {:ok, block} <- decode64(value) do
      case Gnat.Parsec.parse_headers(block) do
        {:ok, _status, _description, headers} -> {:ok, headers}
        {:error, reason} -> {:error, {:headers, reason}}
      end
    end
  end

  defp connection_request(subject, body, opts) do
    with {:ok, conn} <- Connection.get(), do: Gnat.request(conn, subject, body, opts)
  end
end
