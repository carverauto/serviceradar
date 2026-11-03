defmodule ServiceRadar.EventWriter.EdgeRecordDeadLetter do
  @moduledoc """
  The dead-letter for edge records whose projection keeps failing.

  The gateway acknowledged every edge record to its agent once JetStream stored it, so the
  agent no longer holds a copy. When a projector keeps failing on a record (any contract: sweep
  observations, metric batches, unleased sweep results, and every contract added later), the
  EventWriter consumer redelivers it with backoff. Without a dead-letter it would retry until
  the edge-record stream's `MaxAge` evicted it, and the record would be gone with nothing to
  inspect or replay.

  ## When a record is dead-lettered

  A failed delivery is dead-lettered once its delivery count reaches the threshold
  (`threshold/2`): the stream's `dead_letter_after_deliveries`, lowered to `max_deliver - 1`
  when the consumer has a finite `max_deliver`, so the dead-letter happens while one more
  delivery is still left. Earlier failures are NAKed with the pipeline's backoff, as before.

  ## Never lose the record

  The dead-letter message is the record's ORIGINAL bytes and transport headers, plus the
  `Sr-Edge-Dlq-*` failure headers below, published with a PubAck to
  `ServiceRadar.Edge.StreamRoute.dead_letter_route/2` (the source subject's class and
  partition, then `<contract>.v<version>`). The source delivery is ACKed only after that PubAck.
  When the publish fails (a full dead-letter stream refuses with `DiscardNew`, NATS is
  unavailable, the PubAck times out) the source is NAKed with backoff and stays on the
  edge-record stream, so the next delivery tries again.

  The dead-letter's `Nats-Msg-Id` is `edge-dlq:<source stream>:<source sequence>`, and the
  stream keeps that id for the source stream's 24-hour `MaxAge`. A delivery redelivered after a
  lost source ACK is stored once. The same record dead-lettered again after a replay (a new
  source sequence) is stored again rather than deduplicated against a copy the replay already
  deleted. A PubAck that reports the id as a duplicate is a held copy only when that sequence
  is still in the stream. If the sequence was removed, the same bytes are published as
  `edge-dlq:<source stream>:<source sequence>:<n>` for the smallest `n` that is not still
  reserved by a missing message, and the source is acknowledged only once that copy is present.
  The record's own `Nats-Msg-Id` travels in `Sr-Edge-Dlq-Source-Msg-Id`, and replay restores it.

  ## Failure headers

    * `Sr-Edge-Dlq-Version` -- `1`
    * `Sr-Edge-Dlq-Source-Subject`, `-Source-Stream`, `-Source-Sequence` -- where the record
      was delivered from; `-Source-Msg-Id` -- its `Nats-Msg-Id`
    * `Sr-Edge-Dlq-Stored-At` -- when the source stream stored it
    * `Sr-Edge-Dlq-Contract` (`<contract_id>/<version>`), `-Event-Id`, `-Agent-Id`
    * `Sr-Edge-Dlq-Reason` (the failure's class), `-Reason-Detail` (its bounded message)
    * `Sr-Edge-Dlq-Attempts` -- the delivery count when it was dead-lettered
    * `Sr-Edge-Dlq-First-Failed-At`, `-Last-Failed-At` -- the first failure this node saw (or
      the last one when this node saw no earlier failure; deliveries can move between replicas)
      and the dead-lettering failure

  Fields read from the record are omitted when the record does not decode.

  ## Object references

  A dead-lettered record stays authoritative input: replay
  (`ServiceRadar.EventWriter.EdgeRecordDeadLetter.Replay`) projects it again. Any object it
  references out of line (for example a staged artifact's object key) is therefore still
  referenced while the record is in the dead-letter stream. A projector must not delete such
  an object on a failed attempt, only after its ledger transaction commits, and any retention
  pass that deletes objects edge records reference must treat the dead-letter stream as a
  reference source. No catalogued contract carries an out-of-line reference today and no such
  pass exists; whichever change adds the first must add that check.

  The DLQ catalog, its retention and its redrive belong to `add-edge-record-stream-partitioning`.
  """

  alias ServiceRadar.Edge.ContractCatalog
  alias ServiceRadar.Edge.StreamRoute
  alias ServiceRadar.Edge.WireDecode
  alias ServiceRadar.EventWriter.EdgeRecordDeadLetter.FailureLog
  alias ServiceRadar.EventWriter.Telemetry, as: EventWriterTelemetry
  alias ServiceRadar.NATS.Connection
  alias ServiceRadar.NATS.JetStreamPublish

  require Logger

  @prefix "Sr-Edge-Dlq-"
  @version "1"
  @max_detail_bytes 256

  @doc """
  The delivery count at which a failed delivery is dead-lettered: `dead_letter_after`, lowered
  to `max_deliver - 1` for a finite `max_deliver` (at least 1). `nil` when neither bounds it,
  which leaves the stream without a dead-letter.
  """
  @spec threshold(pos_integer() | nil, integer() | nil) :: pos_integer() | nil
  def threshold(dead_letter_after, max_deliver)
      when is_integer(max_deliver) and max_deliver > 0 do
    last_retry = max(max_deliver - 1, 1)
    if is_integer(dead_letter_after), do: min(dead_letter_after, last_retry), else: last_retry
  end

  def threshold(dead_letter_after, _max_deliver) when is_integer(dead_letter_after),
    do: dead_letter_after

  def threshold(_dead_letter_after, _max_deliver), do: nil

  @doc """
  Whether a failed delivery is one this module handles: it was delivered on a subject that has a
  dead-letter route and its stream configures a threshold.
  """
  @spec applies?(map()) :: boolean()
  def applies?(%{metadata: metadata}) when is_map(metadata) do
    is_integer(threshold(metadata[:dead_letter_after], metadata[:max_deliver])) and
      match?({:ok, _}, StreamRoute.dead_letter_route(metadata[:subject] || "", nil))
  end

  def applies?(_message), do: false

  @doc "Whether a failed delivery has reached its dead-letter threshold."
  @spec due?(map()) :: boolean()
  def due?(%{metadata: metadata} = message) when is_map(metadata) do
    case threshold(metadata[:dead_letter_after], metadata[:max_deliver]) do
      nil -> false
      threshold -> attempts(message) >= threshold
    end
  end

  def due?(_message), do: false

  @doc "Records a failed delivery that is not yet due, so the dead-letter can name its first failure."
  @spec note_failure(map()) :: :ok
  def note_failure(message) do
    with {:ok, key} <- source_key(message), do: FailureLog.note(key, now_ms())
    :ok
  end

  @doc "Drops the failure record of a delivery that succeeded."
  @spec forget(map()) :: :ok
  def forget(message) do
    if attempts(message) > 1, do: forget_first_failure(message)

    :ok
  end

  @doc """
  Copies a failed delivery to the dead-letter stream and waits for its PubAck.

  Returns `:ok` once a copy is in the stream. A duplicate PubAck counts only when its sequence
  is still there; a duplicate of a removed sequence is published again under a new id. Any other
  result is an error, and the caller must leave the source unacknowledged. Never raises.
  """
  @spec dead_letter(map()) :: :ok | {:error, term()}
  def dead_letter(message) do
    letter = build(message, DateTime.utc_now())
    result = store_copy(message, letter)
    if match?({:ok, _ack}, result), do: forget_first_failure(message)
    report(letter, result)
  catch
    # A record that cannot be described, or a connection that exits mid-request, is a failed
    # dead-letter like any other: the source stays unacknowledged and is redelivered.
    kind, reason ->
      report(build_safely(message), {:error, {kind, reason}})
  end

  @doc """
  The dead-letter message for a failed delivery at `now`: its subject, body (the record's
  original bytes), its own `Nats-Msg-Id`, and headers (the record's original transport headers
  without broker-control `Nats-*` headers, then the failure headers). Pure apart from reading
  this node's first-failure record.
  """
  @spec build(map(), DateTime.t()) :: map()
  def build(%{data: data, metadata: metadata} = message, %DateTime{} = now)
      when is_binary(data) do
    ack = metadata[:jetstream_ack] || %{}
    source_subject = metadata[:subject] || ""
    record = describe(data)
    # `applies?/1` admitted the subject, so this matches; `dead_letter/1` reports a mismatch.
    {:ok, route} = StreamRoute.dead_letter_route(source_subject, record[:contract])
    {msg_id, transport_headers} = split_transport_headers(metadata[:headers])
    first_failed_ms = first_failed_ms(message)

    failure =
      [
        {"Version", @version},
        {"Source-Subject", source_subject},
        {"Source-Stream", ack[:stream]},
        {"Source-Sequence", ack[:stream_sequence]},
        {"Source-Msg-Id", msg_id},
        {"Stored-At", stored_at(ack[:timestamp])},
        {"Contract", contract_label(record[:contract])},
        {"Event-Id", record[:event_id]},
        {"Agent-Id", record[:agent_id]},
        {"Reason", reason_class(message)},
        {"Reason-Detail", reason_detail(message)},
        {"Attempts", attempts(message)},
        {"First-Failed-At", rfc3339(first_failed_ms) || DateTime.to_iso8601(now)},
        {"Last-Failed-At", DateTime.to_iso8601(now)}
      ]
      |> Enum.reject(fn {_name, value} -> is_nil(value) end)
      |> Enum.map(fn {name, value} -> {@prefix <> name, header_value(value)} end)

    %{
      subject: route.subject,
      body: data,
      msg_id: dead_letter_msg_id(ack),
      headers: transport_headers ++ [{"Nats-Expected-Stream", route.expected_stream}] ++ failure,
      contract: record[:contract],
      source: %{subject: source_subject, stream: ack[:stream], sequence: ack[:stream_sequence]},
      event_id: record[:event_id],
      agent_id: record[:agent_id],
      reason_class: reason_class(message),
      reason_detail: reason_detail(message),
      attempts: attempts(message)
    }
  end

  @doc """
  Splits the headers of a stored dead-letter message into the record's original transport
  headers, without any broker-control `Nats-*` header, and the failure headers, keyed by their
  name without the prefix, lower-cased. The record's `Nats-Msg-Id` is the failure header
  `"source-msg-id"`.
  """
  @spec split_headers([{String.t(), String.t()}]) ::
          {[{String.t(), String.t()}], %{String.t() => String.t()}}
  def split_headers(headers) when is_list(headers) do
    prefix = String.downcase(@prefix)

    headers
    |> Enum.reduce({[], %{}}, fn {name, value}, {transport, failure} ->
      lower = String.downcase(name)

      cond do
        String.starts_with?(lower, prefix) ->
          {transport, Map.put(failure, String.replace_prefix(lower, prefix, ""), value)}

        String.starts_with?(lower, "nats-") ->
          {transport, failure}

        true ->
          {[{name, value} | transport], failure}
      end
    end)
    |> then(fn {transport, failure} -> {Enum.reverse(transport), failure} end)
  end

  # Broker-control headers (`Nats-*`) are dropped from the copy: the gateway's
  # `Nats-Expected-Stream` fenced the source publish and would refuse this one, and the record's
  # `Nats-Msg-Id` moves to `Sr-Edge-Dlq-Source-Msg-Id` (see the moduledoc).
  defp split_transport_headers(headers) do
    pairs = header_pairs(headers)

    msg_id =
      Enum.find_value(pairs, fn {name, value} ->
        if String.downcase(name) == "nats-msg-id", do: value
      end)

    transport =
      Enum.reject(pairs, fn {name, _value} ->
        String.starts_with?(String.downcase(name), "nats-")
      end)

    {msg_id, transport}
  end

  defp header_pairs(headers) when is_list(headers) do
    for {name, value} <- headers, is_binary(name), is_binary(value), do: {name, value}
  end

  defp header_pairs(headers) when is_map(headers) do
    Enum.flat_map(headers, fn
      {name, values} when is_binary(name) and is_list(values) ->
        for value <- values, is_binary(value), do: {name, value}

      {name, value} when is_binary(name) and is_binary(value) ->
        [{name, value}]

      _other ->
        []
    end)
  end

  defp header_pairs(_headers), do: []

  defp dead_letter_msg_id(%{stream: stream, stream_sequence: seq})
       when is_binary(stream) and is_integer(seq),
       do: "edge-dlq:#{stream}:#{seq}"

  defp dead_letter_msg_id(_ack), do: nil

  defp describe(data) do
    case WireDecode.decode_record(data) do
      {:ok, record} ->
        contract =
          case record.output_contract do
            %{contract_id: id, contract_version: version} -> {id, version}
            _other -> nil
          end

        %{
          contract: contract,
          event_id: event_id(record.event_id),
          agent_id: agent_id(record.producer_context)
        }

      {:error, _reason} ->
        %{}
    end
  rescue
    _error -> %{}
  end

  defp event_id(<<_::binary-size(16)>> = id) do
    case Ecto.UUID.load(id) do
      {:ok, uuid} -> uuid
      :error -> Base.encode16(id, case: :lower)
    end
  end

  defp event_id(_id), do: nil

  defp agent_id(%{origin_principal_id: id}) when is_binary(id) and id != "", do: id
  defp agent_id(_context), do: nil

  defp contract_label({id, version}), do: "#{id}/#{version}"
  defp contract_label(nil), do: nil

  # A bounded telemetry label: a catalogued contract by name, anything else lumped together.
  defp contract_tag({id, version} = ref) do
    case ContractCatalog.fetch(ref) do
      {:ok, _entry} -> "#{id}/#{version}"
      :error -> "uncataloged"
    end
  end

  defp contract_tag(nil), do: "undecodable"

  defp attempts(%{metadata: metadata}) when is_map(metadata) do
    case metadata[:jetstream_ack] do
      %{delivery_count: count} when is_integer(count) and count > 0 -> count
      _other -> 1
    end
  end

  defp attempts(_message), do: 1

  defp reason_class(%{status: status}), do: EventWriterTelemetry.failure_class(status)
  defp reason_class(_message), do: "error"

  defp reason_detail(%{status: {:failed, %{__exception__: true} = error}}),
    do: bounded(Exception.message(error))

  defp reason_detail(%{status: {:failed, reason}}), do: bounded(inspect(reason))
  defp reason_detail(_message), do: nil

  defp bounded(text) do
    text = String.replace(text, ~r/[\x00-\x1F\x7F]+/, " ")

    if byte_size(text) > @max_detail_bytes,
      do: String.slice(text, 0, @max_detail_bytes - 3) <> "...",
      else: text
  end

  # NATS header values cannot carry CR/LF; anything that is not a printable single line is hex.
  defp header_value(value) when is_integer(value), do: Integer.to_string(value)

  defp header_value(value) when is_binary(value) do
    if String.valid?(value) and String.printable?(value) and
         not String.match?(value, ~r/[\x00-\x1F\x7F]/) do
      value
    else
      Base.encode16(value, case: :lower)
    end
  end

  defp stored_at(nanos) when is_integer(nanos) and nanos > 0 do
    nanos |> DateTime.from_unix!(:nanosecond) |> DateTime.to_iso8601()
  end

  defp stored_at(_nanos), do: nil

  defp first_failed_ms(message) do
    case source_key(message) do
      {:ok, key} -> FailureLog.first(key)
      :error -> nil
    end
  end

  defp forget_first_failure(message) do
    with {:ok, key} <- source_key(message), do: FailureLog.forget(key)
  end

  defp rfc3339(ms) when is_integer(ms),
    do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

  defp rfc3339(_ms), do: nil

  defp source_key(%{metadata: %{jetstream_ack: %{stream: stream, stream_sequence: seq}}})
       when is_binary(stream) and is_integer(seq), do: {:ok, {stream, seq}}

  defp source_key(_message), do: :error

  defp now_ms, do: System.system_time(:millisecond)

  defp request_fun(%{acknowledger: {_module, _ref, %{request_fun: fun}}})
       when is_function(fun, 3), do: fun

  defp request_fun(_message), do: nil

  defp store_copy(message, letter) do
    publish_until_held(message, letter, letter.msg_id, 0)
  end

  defp publish_until_held(message, letter, base_id, generation) do
    case JetStreamPublish.publish_acked(letter.subject, letter.body,
           msg_id: copy_id(base_id, generation),
           headers: letter.headers,
           request: request_fun(message)
         ) do
      {:ok, %{duplicate: true} = ack} ->
        case copy_held?(message, ack) do
          :held -> {:ok, ack}
          :absent -> next_copy(message, letter, base_id, generation, ack.seq)
          {:error, reason} -> {:error, reason}
        end

      other ->
        other
    end
  end

  defp next_copy(message, letter, base_id, generation, _seq)
       when is_binary(base_id) and base_id != "" do
    publish_until_held(message, letter, base_id, generation + 1)
  end

  defp next_copy(_message, _letter, _base_id, _generation, seq),
    do: {:error, {:dead_letter_copy_missing, seq}}

  defp copy_id(base_id, 0), do: base_id
  defp copy_id(base_id, generation), do: base_id <> ":" <> Integer.to_string(generation)

  defp copy_held?(message, %{stream: stream, seq: seq})
       when is_binary(stream) and is_integer(seq) do
    subject = "$JS.API.STREAM.MSG.GET.#{stream}"

    with {:ok, %{body: body}} <-
           js_request(message, subject, Jason.encode!(%{seq: seq})),
         {:ok, decoded} <- Jason.decode(body) do
      case decoded do
        %{"message" => %{"seq" => ^seq}} -> :held
        %{"error" => %{"err_code" => 10_037}} -> :absent
        %{"error" => %{"code" => 404}} -> :absent
        %{"error" => error} -> {:error, {:jetstream, error}}
        other -> {:error, {:unexpected_reply, other}}
      end
    end
  end

  defp copy_held?(_message, ack), do: {:error, {:unexpected_ack, ack}}

  defp js_request(message, subject, body) do
    opts = [receive_timeout: 5_000]

    case request_fun(message) do
      fun when is_function(fun, 3) -> fun.(subject, body, opts)
      nil -> with {:ok, conn} <- Connection.get(), do: Gnat.request(conn, subject, body, opts)
    end
  end

  # The minimum a failed build can still report.
  defp build_safely(message) do
    metadata = Map.get(message, :metadata) || %{}
    ack = metadata[:jetstream_ack] || %{}

    %{
      subject: nil,
      contract: nil,
      source: %{
        subject: metadata[:subject],
        stream: ack[:stream],
        sequence: ack[:stream_sequence]
      },
      event_id: nil,
      agent_id: nil,
      reason_class: reason_class(message),
      reason_detail: reason_detail(message),
      attempts: attempts(message)
    }
  end

  defp report(letter, {:ok, %{stream: stream, seq: seq} = ack}) do
    emit(letter, "stored")

    Logger.error(
      "Edge record dead-lettered: " <>
        fields(letter,
          dlq_stream: stream,
          dlq_sequence: seq,
          dlq_duplicate: ack.duplicate
        )
    )

    :ok
  end

  defp report(letter, {:error, reason}) do
    emit(letter, "failed")

    Logger.error(
      "Edge record dead-letter publish failed; the source delivery stays unacknowledged: " <>
        fields(letter, publish_error: inspect(reason))
    )

    {:error, reason}
  end

  defp emit(letter, result) do
    :telemetry.execute(
      [:serviceradar, :event_writer, :edge_record, :dead_letter],
      %{count: 1, attempts: letter.attempts},
      %{
        contract: contract_tag(letter.contract),
        reason_class: letter.reason_class,
        result: result
      }
    )
  end

  # The coordinates go in the message itself, as the quarantine report does, so a console
  # formatter that drops Logger metadata still prints what `nats stream get` needs.
  defp fields(letter, extra) do
    [
      source_stream: letter.source.stream,
      source_sequence: letter.source.sequence,
      source_subject: letter.source.subject,
      dlq_subject: letter.subject,
      contract: contract_label(letter.contract),
      event_id: letter.event_id,
      agent_id: letter.agent_id,
      attempts: letter.attempts,
      reason: letter.reason_class,
      reason_detail: letter.reason_detail
    ]
    |> Kernel.++(extra)
    |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{loggable(value)}" end)
  end

  defp loggable(nil), do: "-"
  defp loggable(value) when is_binary(value), do: header_value(value)
  defp loggable(value), do: to_string(value)
end
