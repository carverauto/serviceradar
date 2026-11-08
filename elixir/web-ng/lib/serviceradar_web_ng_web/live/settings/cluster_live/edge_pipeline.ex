defmodule ServiceRadarWebNGWeb.Settings.ClusterLive.EdgePipeline do
  @moduledoc """
  The Settings -> Cluster "Edge Pipeline" panel: every durable agent data family, per output
  contract, from gateway admission through EventWriter projection, plus the JetStream state of
  the edge-record durables.

  The numbers are `ServiceRadar.Edge.PipelineStats` snapshots of every connected node (gateways
  and EventWriter cores), read from ETS and summed here, so the panel costs one remote call per
  node per page refresh and no database query.
  """

  use ServiceRadarWebNGWeb, :html

  alias ServiceRadar.Edge.PipelineStats

  @rpc_timeout_ms 1_500
  @last_seen_fields [:last_admitted_at_ms, :last_projected_at_ms]

  @doc "Stats for a mount: loaded only on the connected render."
  @spec stats_for_mount(boolean()) :: map()
  def stats_for_mount(true), do: load()
  def stats_for_mount(false), do: unavailable()

  @doc "Every connected node's snapshot, merged."
  @spec load() :: map()
  def load do
    [Node.self() | Node.list()]
    |> Enum.uniq()
    |> :erpc.multicall(PipelineStats, :snapshot, [], @rpc_timeout_ms)
    |> Enum.flat_map(fn
      {:ok, {:ok, %{contracts: contracts, consumers: consumers} = snapshot}}
      when is_list(contracts) and is_list(consumers) ->
        [snapshot]

      _unavailable ->
        []
    end)
    |> merge(System.system_time(:millisecond))
  end

  @doc "The stats when no node reported."
  @spec unavailable() :: map()
  def unavailable, do: %{available: false, nodes: [], contracts: [], dead_letter_reasons: [], consumers: [], now_ms: 0}

  @doc """
  Sums node snapshots: one row per catalogued contract in catalog order, then any other label a
  node counted; dead-lettered records per contract and reason, most first; the latest sample of
  each durable, with its stream depth taken from the latest sample that read it. `now_ms` is
  when the ages are measured from.
  """
  @spec merge([map()], integer()) :: map()
  def merge([], _now_ms), do: unavailable()

  def merge(snapshots, now_ms) do
    by_label = snapshots |> Enum.flat_map(& &1.contracts) |> Enum.group_by(& &1.contract)
    catalog = PipelineStats.contract_labels()
    labels = catalog ++ Enum.sort(Map.keys(by_label) -- catalog)

    consumers =
      snapshots
      |> Enum.flat_map(& &1.consumers)
      |> Enum.group_by(&{&1.stream, &1.durable})
      |> Enum.map(fn {_durable, samples} -> latest_sample(samples) end)
      |> Enum.sort_by(&{&1.subject_class, &1.durable})

    %{
      available: true,
      nodes: Enum.map(snapshots, & &1.node),
      contracts: Enum.map(labels, &merge_contract(&1, Map.get(by_label, &1, []))),
      dead_letter_reasons: merge_dead_letter_reasons(snapshots),
      consumers: consumers,
      now_ms: now_ms
    }
  end

  # A node that predates per-reason counts reports none.
  defp merge_dead_letter_reasons(snapshots) do
    snapshots
    |> Enum.flat_map(&Map.get(&1, :dead_letter_reasons, []))
    |> Enum.group_by(&{&1.contract, &1.reason}, & &1.count)
    |> Enum.map(fn {{contract, reason}, counts} ->
      %{contract: contract, reason: reason, count: Enum.sum(counts)}
    end)
    |> Enum.sort_by(&{-&1.count, &1.contract, &1.reason})
  end

  defp latest_sample(samples) do
    sample = Enum.max_by(samples, & &1.sampled_at_ms)
    known = for %{stream_messages: messages} = known <- samples, is_integer(messages), do: known

    case {sample.stream_messages, known} do
      {nil, [_ | _]} -> %{sample | stream_messages: Enum.max_by(known, & &1.sampled_at_ms).stream_messages}
      _known_or_none -> sample
    end
  end

  defp merge_contract(label, entries) do
    Enum.reduce(entries, PipelineStats.empty_counts(label), fn entry, acc ->
      Map.new(acc, fn
        {:contract, value} -> {:contract, value}
        {field, value} when field in @last_seen_fields -> {field, latest(value, entry[field])}
        {field, value} -> {field, value + Map.get(entry, field, 0)}
      end)
    end)
  end

  defp latest(nil, other), do: other
  defp latest(value, nil), do: value
  defp latest(value, other), do: max(value, other)

  @doc "How long before `now_ms` a record was last seen."
  @spec format_age(integer() | nil, integer()) :: String.t()
  def format_age(nil, _now_ms), do: "never"

  def format_age(at_ms, now_ms) do
    seconds = max(div(now_ms - at_ms, 1_000), 0)

    cond do
      seconds < 60 -> "#{seconds}s ago"
      seconds < 3_600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3_600)}h ago"
      true -> "#{div(seconds, 86_400)}d ago"
    end
  end

  attr(:stats, :map, required: true)

  def panel(assigns) do
    ~H"""
    <.ui_panel>
      <:header>
        <div>
          <div class="text-sm font-semibold">Edge Pipeline</div>
          <p class="text-xs text-sr-muted">
            Edge records per output contract: gateway admission, EventWriter projection, and
            JetStream durable health. Counts are cluster totals since each node started.
          </p>
        </div>
      </:header>

      <div
        :if={not @stats.available}
        id="cluster-edge-pipeline-unavailable"
        class="py-6 text-center text-sm text-sr-muted"
      >
        No agent gateway or EventWriter node is reachable to report edge pipeline counts.
      </div>

      <div :if={@stats.available} class="space-y-4">
        <div id="cluster-edge-pipeline-contracts" class="sr-ui-table-shell">
          <table class={ui_table_class(size: "sm")}>
            <thead>
              <tr class="text-xs uppercase tracking-wide text-sr-muted">
                <th>Output contract</th>
                <th>Gateway admitted</th>
                <th>Gateway refused</th>
                <th>Gateway withheld</th>
                <th title="Duplicate PubAcks / publish attempts that did not store">
                  Dup / retry
                </th>
                <th>Projected</th>
                <th>Projector refused</th>
                <th>Failed attempts</th>
                <th>Dead-lettered</th>
                <th>Last admitted</th>
                <th>Last projected</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={row <- @stats.contracts}
                id={"cluster-edge-contract-#{dom_id(row.contract)}"}
              >
                <td class="font-mono text-xs font-medium">{row.contract}</td>
                <td class="font-mono text-xs">{row.gateway_admitted}</td>
                <td class={count_class(row.gateway_refused, "text-error font-semibold")}>
                  {row.gateway_refused}
                </td>
                <td class={count_class(row.gateway_withheld, "text-warning")}>
                  {row.gateway_withheld}
                </td>
                <td class={count_class(row.gateway_publish_retry, "text-warning")}>
                  {row.gateway_duplicate} / {row.gateway_publish_retry}
                </td>
                <td class="font-mono text-xs text-success">{row.projected}</td>
                <td class={count_class(row.projector_refused, "text-warning font-semibold")}>
                  {row.projector_refused}
                </td>
                <td class={count_class(row.failed, "text-warning")}>{row.failed}</td>
                <td class={count_class(row.dead_lettered, "text-error font-semibold")}>
                  {row.dead_lettered}
                </td>
                <td class="font-mono text-xs text-sr-muted">
                  {format_age(row.last_admitted_at_ms, @stats.now_ms)}
                </td>
                <td class="font-mono text-xs text-sr-muted">
                  {format_age(row.last_projected_at_ms, @stats.now_ms)}
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <div
          :if={@stats.dead_letter_reasons != []}
          id="cluster-edge-pipeline-dead-letter-reasons"
          class="sr-ui-table-shell"
        >
          <table class={ui_table_class(size: "sm")}>
            <thead>
              <tr class="text-xs uppercase tracking-wide text-sr-muted">
                <th>Dead-lettered contract</th>
                <th title="The Sr-Edge-Dlq-Reason class; replay one reason once its cause is fixed">
                  Reason
                </th>
                <th>Records</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={row <- @stats.dead_letter_reasons}
                id={"cluster-edge-dlq-reason-#{dom_id(row.contract)}-#{dom_id(row.reason)}"}
              >
                <td class="font-mono text-xs font-medium">{row.contract}</td>
                <td class="font-mono text-xs">{row.reason}</td>
                <td class="font-mono text-xs text-error font-semibold">{row.count}</td>
              </tr>
            </tbody>
          </table>
        </div>

        <div
          :if={@stats.consumers == []}
          id="cluster-edge-pipeline-consumers-unavailable"
          class="py-2 text-center text-xs text-sr-muted"
        >
          No EventWriter coordinator has sampled the edge-record durables yet.
        </div>

        <div
          :if={@stats.consumers != []}
          id="cluster-edge-pipeline-consumers"
          class="sr-ui-table-shell"
        >
          <table class={ui_table_class(size: "sm")}>
            <thead>
              <tr class="text-xs uppercase tracking-wide text-sr-muted">
                <th>Stream</th>
                <th>Durable</th>
                <th>Pending</th>
                <th>Ack Pending</th>
                <th>Redelivered</th>
                <th>Stream Messages</th>
                <th>Sampled</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={consumer <- @stats.consumers}
                id={"cluster-edge-consumer-#{dom_id(consumer.subject_class)}"}
              >
                <td class="font-mono text-xs font-medium">{consumer.stream}</td>
                <td class="font-mono text-xs">{consumer.durable}</td>
                <td class={count_class(consumer.pending, "text-warning")}>{consumer.pending}</td>
                <td class={count_class(consumer.ack_pending, "text-warning")}>
                  {consumer.ack_pending}
                </td>
                <td class={count_class(consumer.redelivered, "text-warning")}>
                  {consumer.redelivered}
                </td>
                <td class={stream_messages_class(consumer)}>
                  {consumer.stream_messages || "unknown"}
                </td>
                <td class="font-mono text-xs text-sr-muted">
                  {format_age(consumer.sampled_at_ms, @stats.now_ms)}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </.ui_panel>
    """
  end

  defp count_class(count, emphasis) when is_integer(count) and count > 0, do: "font-mono text-xs #{emphasis}"
  defp count_class(_count, _emphasis), do: "font-mono text-xs text-sr-muted"

  # A message held on the dead-letter stream is a record no projector could take.
  defp stream_messages_class(%{subject_class: "edge_record_dlq", stream_messages: messages}),
    do: count_class(messages, "text-error font-semibold")

  defp stream_messages_class(_consumer), do: "font-mono text-xs"

  defp dom_id(label), do: String.replace(label, ~r/[^A-Za-z0-9_-]/, "-")
end
