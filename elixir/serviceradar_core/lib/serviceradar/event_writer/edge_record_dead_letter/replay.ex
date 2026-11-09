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

  Options, for every function here:

    * `:subject` -- a filter on the dead-letter subjects, default every bulk record
      (`telemetry.edge-record-dlq.v1.bulk.>`); one contract is
      `telemetry.edge-record-dlq.v1.bulk.*.serviceradar_metrics_batch.v1`
    * `:reason` -- only messages dead-lettered for this reason class (their
      `Sr-Edge-Dlq-Reason` header, as `list/1` and the Edge Pipeline panel show it), so a fixed
      cause is replayed without the records still failing for another one; other messages are
      skipped, kept, and not counted against `:limit`
    * `:contract` -- only messages of this output contract (their `Sr-Edge-Dlq-Contract` header,
      `<contract_id>/<version>`), skipped and counted the same way
    * `:reason` or `:contract` set to `:missing` selects the messages that lack that header (or
      carry it blank), which `inventory/1` groups under a `nil` contract or reason
    * `:from_sequence` -- the first dead-letter stream sequence to read (default 1)
    * `:through_sequence` -- the last dead-letter stream sequence to read, such as the
      `through_sequence` an `inventory/1` returned, so an action covers only what was inspected
    * `:limit` -- at most this many messages (default 100)
    * `:stream` -- the dead-letter stream (default `TELEMETRY_EDGE_RECORD_DLQ_V1_BULK`)
    * `:request` -- `(subject, body, opts -> {:ok, %{body: binary}} | {:error, term})`, a NATS
      request on a connection the caller owns; default `ServiceRadar.NATS.Connection`

  The walk reads only the messages the stream held when it started (`last_seq` at the start,
  then `:subject`, `:from_sequence`, `:through_sequence` and `:limit`), so a record this replay republishes that is
  dead-lettered again is left for the next run. `replay/1` deletes each dead-letter message
  only after the source PubAck. A failed delete leaves it in place (`:replayed_kept`).

  `list/1`, `replay/1` and `purge/1` return
  `{:ok, %{entries: [...], next_sequence: n, complete: boolean}}`. `complete` is false when the
  walk stopped at `:limit` with messages it has not read. When a NATS request fails after the
  walk has handled some messages, it returns those entries with `complete: false` and the
  failure as `:error`, so a replay or purge that stopped part way still reports what it did;
  a failure before any message was handled is `{:error, reason}`. Each entry names its dead-letter
  sequence, source and failure headers, and, for `replay/1` and `purge/1`, its `:result`:
  `:replayed`, `:replayed_kept` (the delete failed: see `:delete_error`), `:purged`, or
  `{:error, reason}` (the message is kept). Pass `next_sequence` as `:from_sequence` to continue.
  `inventory/1` groups what `list/1` reads; see its doc.
  """

  alias ServiceRadar.Edge.StreamRoute
  alias ServiceRadar.Events.AuditWriter
  alias ServiceRadar.EventWriter.EdgeRecordDeadLetter
  alias ServiceRadar.NATS.Connection
  alias ServiceRadar.NATS.JetStreamPublish

  require Logger

  @stream "TELEMETRY_EDGE_RECORD_DLQ_V1_BULK"
  @subject "telemetry.edge-record-dlq.v1.bulk.>"
  @default_limit 100
  @inventory_limit 5_000
  @inventory_agents 10
  @timeout_ms 5_000

  @type walk :: %{
          required(:entries) => [map()],
          required(:next_sequence) => pos_integer(),
          required(:complete) => boolean(),
          optional(:error) => term()
        }

  @doc "Lists dead-lettered records without changing anything. See the moduledoc."
  @spec list(keyword()) :: {:ok, walk()} | {:error, term()}
  def list(opts \\ []), do: walk(opts, &describe/2)

  @doc "Republishes dead-lettered records to their source subjects. See the moduledoc."
  @spec replay(keyword()) :: {:ok, walk()} | {:error, term()}
  def replay(opts \\ []), do: walk(opts, &replay_one/2)

  @doc """
  Deletes held dead-letter messages, one at a time, and reports each as `:purged` or
  `{:error, reason}` (kept). Scope it with `:reason`, `:contract` or `:subject`.

  A dead-letter message is the only copy of its record, so this is for records an operator has
  decided are not worth replaying, such as snapshots newer deliveries have already superseded.
  It deletes message by message because the core NATS identity is denied purging or deleting
  the stream itself (`helm/serviceradar/templates/_nats_static_users.tpl`); deleting one
  message is what replay already does after a republish.
  """
  @spec purge(keyword()) :: {:ok, walk()} | {:error, term()}
  def purge(opts \\ []), do: walk(opts, &purge_one/2)

  @doc """
  Runs `replay/1` or `purge/1` for an operator and audits it from this process: an event when
  it starts (operation, scope, actor) and one with its outcome (`summarize/1`'s counts,
  `complete`, and the error of a run that stopped part way or did not run). Writing both here,
  on the node that walks the stream, keeps the record even when the caller that asked for the
  action goes away before it finishes. Returns what `replay/1` or `purge/1` returned.
  """
  @spec operator_action(:replay | :purge, keyword(), map() | nil) ::
          {:ok, walk()} | {:error, term()}
  def operator_action(action, opts, actor) when action in [:replay, :purge] do
    scope = audit_scope(opts)
    audit(:"#{action}_started", action, scope, actor, %{})

    result = if action == :purge, do: purge(opts), else: replay(opts)

    audit(if(action == :purge, do: :delete, else: :update), action, scope, actor, outcome(result))
    result
  end

  @doc """
  Counts one replay or purge's entries: `done` were replayed or purged, `kept` were replayed but
  their dead-letter copy could not be deleted, and `failed` are still held, with their distinct
  reasons in `errors`.
  """
  @spec summarize([map()]) :: %{
          done: non_neg_integer(),
          kept: non_neg_integer(),
          failed: non_neg_integer(),
          errors: [String.t()]
        }
  def summarize(entries) do
    {done, kept, errors} =
      Enum.reduce(entries, {0, 0, []}, fn
        %{result: result}, {done, kept, errors} when result in [:replayed, :purged] ->
          {done + 1, kept, errors}

        %{result: :replayed_kept}, {done, kept, errors} ->
          {done, kept + 1, errors}

        %{result: {:error, reason}}, {done, kept, errors} ->
          {done, kept, [inspect(reason) | errors]}
      end)

    %{
      done: done,
      kept: kept,
      failed: length(errors),
      errors: errors |> Enum.reverse() |> Enum.uniq()
    }
  end

  defp audit_scope(opts) do
    for key <- [:contract, :reason, :through_sequence], Keyword.has_key?(opts, key), into: %{} do
      value = Keyword.get(opts, key)
      {to_string(key), if(value == :missing, do: "(missing)", else: value)}
    end
  end

  defp audit(audit_action, action, scope, actor, outcome) do
    id = Enum.map_join(["contract", "reason"], " ", &Map.get(scope, &1, "*"))

    case AuditWriter.write(
           action: audit_action,
           resource_type: "edge_record_dead_letters",
           resource_id: id,
           resource_name: id,
           actor: actor,
           details: Map.merge(%{"operation" => to_string(action), "scope" => scope}, outcome)
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Dead-letter #{action} audit event not written: #{inspect(reason)}")
    end
  end

  defp outcome({:ok, %{entries: entries, complete: complete} = walk}) do
    entries
    |> summarize()
    |> Map.merge(%{
      complete: complete,
      error: walk |> Map.get(:error) |> then(&(&1 && inspect(&1)))
    })
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
  end

  defp outcome({:error, reason}), do: %{"error" => inspect(reason)}

  @doc """
  The held dead letters grouped by contract and reason, most first: per group its count, the
  first and last dead-letter sequences and times, the agents it came from (at most
  #{@inventory_agents} named, with `agent_count` the total), and one sample `reason_detail`. It reads up to
  `:limit` messages (default #{@inventory_limit}); `complete` is false when more were held, so a caller
  never presents a partial count as the whole. A group's `contract` or `reason` is `nil` when its
  messages lack that header; pass `:missing` for it to `replay/1` or `purge/1`.
  `through_sequence` is the highest dead-letter sequence read (`nil` when none was); pass it to
  `replay/1` or `purge/1` so they act on no message the inventory did not count.
  """
  @spec inventory(keyword()) ::
          {:ok,
           %{
             groups: [map()],
             scanned: non_neg_integer(),
             complete: boolean(),
             through_sequence: pos_integer() | nil
           }}
          | {:error, term()}
  def inventory(opts \\ []) do
    opts = Keyword.put_new(opts, :limit, @inventory_limit)

    case walk(opts, &describe/2) do
      {:ok, %{error: reason}} ->
        {:error, reason}

      {:ok, %{entries: entries, complete: complete}} ->
        {:ok,
         %{
           groups: group(entries),
           scanned: length(entries),
           complete: complete,
           through_sequence: entries |> List.last(%{}) |> Map.get(:dlq_sequence)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp group(entries) do
    entries
    |> Enum.group_by(&{header_value(&1.failure, "contract"), header_value(&1.failure, "reason")})
    |> Enum.map(fn {{contract, reason}, [first | _] = held} ->
      last = List.last(held)
      agents = held |> Enum.map(& &1.failure["agent-id"]) |> Enum.reject(&is_nil/1) |> Enum.uniq()

      %{
        contract: contract,
        reason: reason,
        count: length(held),
        first_sequence: first.dlq_sequence,
        last_sequence: last.dlq_sequence,
        first_stored_at: first.stored_at,
        last_stored_at: last.stored_at,
        agents: Enum.take(agents, @inventory_agents),
        agent_count: length(agents),
        reason_detail: first.failure["reason-detail"]
      }
    end)
    |> Enum.sort_by(&{-&1.count, &1.contract, &1.reason})
  end

  defp header_value(failure, header) do
    case Map.get(failure, header) do
      value when is_binary(value) and value != "" -> value
      _missing -> nil
    end
  end

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
    from = Keyword.get(opts, :from_sequence, 1)

    ctx = %{
      request: request,
      stream: stream,
      filters: filters(opts)
    }

    # Only the messages already held when the walk starts: a record a replay republishes
    # that fails again is dead-lettered after it, and must not be replayed in the same run.
    with {:ok, last} <- last_sequence(ctx) do
      last = min(last, Keyword.get(opts, :through_sequence) || last)
      filter = Keyword.get(opts, :subject, @subject)
      walk_subject(Map.put(ctx, :last, last), filter, from, limit, fun, [])
    end
  end

  defp filters(opts) do
    for {header, key} <- [{"reason", :reason}, {"contract", :contract}],
        value = Keyword.get(opts, key),
        do: {header, if(value == :missing, do: nil, else: value)}
  end

  defp last_sequence(ctx) do
    case api_request(ctx, "$JS.API.STREAM.INFO.#{ctx.stream}", %{}) do
      {:ok, %{"state" => %{"last_seq" => last}}} when is_integer(last) -> {:ok, last}
      {:ok, other} -> {:error, {:unexpected_reply, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp walk_subject(%{last: last}, _filter, from, _limit, _fun, acc) when from > last,
    do: done(acc, from, true)

  defp walk_subject(ctx, filter, from, 0, _fun, acc) do
    case get_message(ctx, %{"seq" => from, "next_by_subj" => filter}) do
      {:ok, %{seq: seq}} when seq <= ctx.last -> done(acc, from, false)
      {:error, _reason} -> done(acc, from, false)
      _none_left -> done(acc, from, true)
    end
  end

  defp walk_subject(ctx, filter, from, limit, fun, acc) do
    case get_message(ctx, %{"seq" => from, "next_by_subj" => filter}) do
      {:ok, %{seq: seq}} when seq > ctx.last ->
        done(acc, from, true)

      {:ok, message} ->
        if matches?(ctx.filters, message) do
          walk_subject(ctx, filter, message.seq + 1, limit - 1, fun, [fun.(ctx, message) | acc])
        else
          walk_subject(ctx, filter, message.seq + 1, limit, fun, acc)
        end

      :none ->
        done(acc, from, true)

      {:error, reason} when acc == [] ->
        {:error, reason}

      {:error, reason} ->
        {:ok, %{entries: Enum.reverse(acc), next_sequence: from, complete: false, error: reason}}
    end
  end

  defp done(acc, next, complete),
    do: {:ok, %{entries: Enum.reverse(acc), next_sequence: next, complete: complete}}

  defp matches?([], _message), do: true

  defp matches?(filters, message) do
    {_transport, failure} = EdgeRecordDeadLetter.split_headers(message.headers)
    Enum.all?(filters, fn {header, value} -> header_value(failure, header) == value end)
  end

  defp purge_one(ctx, message) do
    entry = describe(ctx, message)

    case delete_message(ctx, message.seq) do
      :ok -> Map.put(entry, :result, :purged)
      {:error, reason} -> Map.put(entry, :result, {:error, reason})
    end
  end

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

  defp delete_after_replay(ctx, seq) do
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
