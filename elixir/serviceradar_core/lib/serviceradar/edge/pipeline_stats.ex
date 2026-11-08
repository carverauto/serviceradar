defmodule ServiceRadar.Edge.PipelineStats do
  @moduledoc """
  Node-local counters for the durable edge-record pipeline, per output contract, read by the
  Settings -> Cluster "Edge Pipeline" panel.

  Each owner counts its own stage into one public ETS table, and never waits on anything to do
  it:

    * the agent gateway (`ServiceRadarAgentGateway.EdgeRecordIngestServer`): records it
      refused for good (`:gateway_refused`) and withheld for the agent to send again
      (`:gateway_withheld`);
    * the gateway's `ServiceRadar.Edge.PublishPipeline`: primary records JetStream stored as a
      new message (`:gateway_admitted`), publishes JetStream answered as a duplicate of a stored
      message (`:gateway_duplicate`), and publish attempts that did not store
      (`:gateway_publish_retry`);
    * the EventWriter edge-record processor (`ServiceRadar.EventWriter.Processors.EdgeRecord`):
      first primary deliveries committed through the ledger and projector (`:projected`), refused without a
      projection (`:projector_refused`), and failed attempts JetStream will redeliver
      (`:failed`);
    * `ServiceRadar.EventWriter.EdgeRecordDeadLetter`: records stored on the dead-letter stream
      (`:dead_lettered`), also counted per failure reason (`record_dead_letter/2`) so the panel
      shows why records were dead-lettered and which reason to replay once it is fixed;
    * `ServiceRadar.EventWriter.ConsumerLagReporter`: the latest JetStream state of each
      edge-record durable (pending, ack pending, redelivered, and its stream's message count,
      which for the dead-letter stream is the DLQ depth, or nil when that stream's poll failed).

  The contract label is bounded: a catalogued contract as `<contract_id>/<version>`
  (`ServiceRadar.Edge.ContractCatalog`), any other contract as `uncataloged`, and a record whose
  contract is not known at the point it was counted (a frame refused before it decoded) as
  `unattributed`. No agent, event or payload identifier becomes a key. A dead-letter reason is
  the failure's class (`ServiceRadar.EventWriter.Telemetry.failure_class/1`): a refusal or error
  atom, or an exception's module name, so it is bounded by the code, not by the records.

  Counts are cumulative for the life of the owning process. `snapshot/0` reads the table
  without calling any process; callers aggregate the snapshots of every node in the cluster.
  """

  use GenServer

  alias ServiceRadar.Edge.ContractCatalog
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias ServiceRadar.Edge.WireDecode

  @table __MODULE__
  @events [
    :gateway_admitted,
    :gateway_duplicate,
    :gateway_publish_retry,
    :gateway_refused,
    :gateway_withheld,
    :projected,
    :projector_refused,
    :failed,
    :dead_lettered
  ]
  # The events whose latest occurrence is kept as an age.
  @last_seen %{gateway_admitted: :last_admitted_at_ms, projected: :last_projected_at_ms}
  @consumer_classes [
    "edge_record",
    "edge_record_audit",
    "edge_record_quarantine",
    "edge_record_dlq"
  ]
  @unattributed "unattributed"

  @type contract_ref :: ContractCatalog.ref() | nil
  @type contract_counts :: %{
          required(:contract) => String.t(),
          required(:gateway_admitted) => non_neg_integer(),
          required(:gateway_duplicate) => non_neg_integer(),
          required(:gateway_publish_retry) => non_neg_integer(),
          required(:gateway_refused) => non_neg_integer(),
          required(:gateway_withheld) => non_neg_integer(),
          required(:projected) => non_neg_integer(),
          required(:projector_refused) => non_neg_integer(),
          required(:failed) => non_neg_integer(),
          required(:dead_lettered) => non_neg_integer(),
          required(:last_admitted_at_ms) => integer() | nil,
          required(:last_projected_at_ms) => integer() | nil
        }
  @type dead_letter_reason :: %{
          required(:contract) => String.t(),
          required(:reason) => String.t(),
          required(:count) => non_neg_integer()
        }
  @type consumer_state :: %{
          required(:subject_class) => String.t(),
          required(:stream) => String.t(),
          required(:durable) => String.t(),
          required(:pending) => non_neg_integer(),
          required(:ack_pending) => non_neg_integer(),
          required(:redelivered) => non_neg_integer(),
          required(:stream_messages) => non_neg_integer() | nil,
          required(:sampled_at_ms) => integer()
        }

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, nil}
  end

  @doc "The label of every catalogued contract, in catalog order."
  @spec contract_labels() :: [String.t()]
  def contract_labels, do: Enum.map(ContractCatalog.entries(), &contract_label(&1.ref))

  @doc "The bounded label a contract is counted under."
  @spec contract_label(contract_ref()) :: String.t()
  def contract_label({id, version} = ref) do
    case ContractCatalog.fetch(ref) do
      {:ok, _entry} -> "#{id}/#{version}"
      :error -> "uncataloged"
    end
  end

  def contract_label(_ref), do: @unattributed

  @doc "The contract a decoded record names, or nil."
  @spec contract_ref(EdgeRecordV1.t() | term()) :: contract_ref()
  def contract_ref(%EdgeRecordV1{output_contract: %{contract_id: id, contract_version: version}})
      when is_binary(id) and is_integer(version), do: {id, version}

  def contract_ref(_record), do: nil

  @doc """
  The contract named by raw `EdgeRecordV1` bytes, or nil when they do not decode. For a stage
  that holds only the bytes a record arrived as.
  """
  @spec contract_of(binary()) :: contract_ref()
  def contract_of(record_bytes) when is_binary(record_bytes) do
    case WireDecode.decode_record(record_bytes) do
      {:ok, record} -> contract_ref(record)
      {:error, _reason} -> nil
    end
  end

  @doc "Counts `count` records of `contract` at `event`. A no-op where the table is not running."
  @spec record(atom(), contract_ref(), pos_integer()) :: :ok
  def record(event, contract, count \\ 1)
      when event in @events and is_integer(count) and count > 0 do
    label = contract_label(contract)
    key = {:count, label, event}
    :ets.update_counter(@table, key, {2, count}, {key, 0})

    case @last_seen do
      %{^event => field} ->
        :ets.insert(@table, {{:last, label, field}, System.system_time(:millisecond)})

      _other ->
        true
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Counts one record of `contract` stored on the dead-letter stream for `reason` (its
  `Sr-Edge-Dlq-Reason` class). A no-op where the table is not running.
  """
  @spec record_dead_letter(contract_ref(), String.t()) :: :ok
  def record_dead_letter(contract, reason) when is_binary(reason) do
    record(:dead_lettered, contract)
    key = {:dead_letter_reason, contract_label(contract), reason}
    :ets.update_counter(@table, key, {2, 1}, {key, 0})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Keeps the latest JetStream state of an edge-record durable: `consumer_info` and `stream_info`
  are the `Consumer.info/3` and `Stream.info/2` responses. Other subject classes are ignored.
  """
  @spec record_consumer(map(), map(), map() | nil) :: :ok
  def record_consumer(
        %{subject_class: class, stream: stream, durable: durable},
        consumer_info,
        stream_info
      )
      when class in @consumer_classes and is_map(consumer_info) do
    state = %{
      subject_class: class,
      stream: stream,
      durable: durable,
      pending: count(consumer_info, :num_pending),
      ack_pending: count(consumer_info, :num_ack_pending),
      redelivered: count(consumer_info, :num_redelivered),
      stream_messages: stream_info |> value(:state) |> known_count(:messages),
      sampled_at_ms: System.system_time(:millisecond)
    }

    :ets.insert(@table, {{:consumer, stream, durable}, state})
    :ok
  rescue
    ArgumentError -> :ok
  end

  def record_consumer(_consumer, _consumer_info, _stream_info), do: :ok

  @doc """
  This node's counters: one entry per contract it has counted, its dead-lettered records per
  contract and reason, and the edge-record durables its lag reporter has sampled.
  `{:error, :unavailable}` where the table is not running.
  """
  @spec snapshot() ::
          {:ok,
           %{
             node: String.t(),
             contracts: [contract_counts()],
             dead_letter_reasons: [dead_letter_reason()],
             consumers: [consumer_state()]
           }}
          | {:error, :unavailable}
  def snapshot do
    rows = :ets.tab2list(@table)

    contracts =
      rows
      |> Enum.reduce(%{}, fn
        {{:count, label, event}, value}, acc ->
          Map.update(acc, label, %{event => value}, &Map.put(&1, event, value))

        {{:last, label, field}, value}, acc ->
          Map.update(acc, label, %{field => value}, &Map.put(&1, field, value))

        _row, acc ->
          acc
      end)
      |> Enum.map(fn {label, values} -> Map.merge(empty_counts(label), values) end)

    dead_letter_reasons =
      for {{:dead_letter_reason, label, reason}, count} <- rows,
          do: %{contract: label, reason: reason, count: count}

    consumers = for {{:consumer, _stream, _durable}, state} <- rows, do: state

    {:ok,
     %{
       node: to_string(node()),
       contracts: contracts,
       dead_letter_reasons: dead_letter_reasons,
       consumers: consumers
     }}
  rescue
    ArgumentError -> {:error, :unavailable}
  end

  @doc "A contract's counts before anything was counted."
  @spec empty_counts(String.t()) :: contract_counts()
  def empty_counts(label) do
    @events
    |> Map.new(&{&1, 0})
    |> Map.merge(%{contract: label, last_admitted_at_ms: nil, last_projected_at_ms: nil})
  end

  defp value(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp value(_map, _key), do: nil

  defp count(map, key), do: known_count(map, key) || 0

  defp known_count(map, key) do
    case value(map, key) do
      n when is_integer(n) and n >= 0 -> n
      _other -> nil
    end
  end
end
