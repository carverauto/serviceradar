defmodule ServiceRadar.Analytics.StarRocks.Retention do
  @moduledoc """
  Applies the operator's telemetry retention to the StarRocks warehouse tables.

  The telemetry tables are partitioned by day, so retention is enforced by
  StarRocks itself: keeping the most recent N daily partitions drops anything
  older without a delete job. Retention is per dataset and stored in CNPG
  (`ServiceRadar.Observability.WarehouseRetentionSetting`, one row per dataset),
  edited on the Data retention settings page. The environment
  (`SERVICERADAR_STARROCKS_RETENTION_DAYS_<DATASET>`, Helm
  `analytics.starrocks.retentionDays.<dataset>`, Compose
  `STARROCKS_RETENTION_DAYS_<DATASET>`) only seeds a dataset that has no row yet;
  after that the stored value wins. Existing datasets default to one year and
  process attribution to 30 days (`Env.default_retention_days/0`).

  MTR is one dataset over two tables, `mtr_traces` and `mtr_hops`, so a trace and
  its hops expire together; OTel metrics likewise covers `otel_metrics` and
  `otel_metric_points`. OTel traces (`traces`) is `otel_traces`; the
  unpartitioned `otel_trace_summaries` is pruned to the same window by
  `RefreshTraceSummariesWorker`.

  The applier is a process that reconciles the stored settings with the
  warehouse: at start it applies every dataset (a warehouse rebuilt from DDL
  defaults converges again), and afterwards it applies a dataset whose stored
  value has not been applied yet. A save broadcasts on
  `WarehouseRetentionNotifier.topic/0`, which triggers a reconcile at once; a
  timer reconciles too, so a lost broadcast only delays the apply. Each outcome
  is recorded on the row (`applied`, `pending` while the Frontend does not
  answer, `failed` when it answers with an error).

  A warehouse Frontend is routinely slower to answer than core is to boot, and a
  value that never lands means partitions are dropped on the DDL default
  instead, which cannot be undone. A dataset that did not apply is therefore
  retried with capped backoff rather than given up on.

  Floors: every dataset keeps at least one day. Process attribution also never
  keeps fewer than two live partitions: correlation joins flows to observations
  across a skew window, which straddles midnight, so one partition would drop
  the half of the window that lies in yesterday.
  """

  use GenServer

  alias ServiceRadar.Analytics.StarRocks.Env
  alias ServiceRadar.Analytics.StarRocks.MySQL
  alias ServiceRadar.Analytics.StarRocks.Retention.Store
  alias ServiceRadar.Observability.WarehouseRetentionNotifier

  require Logger

  # A dataset may own more than one table; each table is listed once.
  @tables [
    flows: "ocsf_network_activity",
    metrics: "timeseries_metrics",
    logs: "logs",
    events: "events",
    mtr: "mtr_traces",
    mtr: "mtr_hops",
    otel: "otel_metrics",
    otel: "otel_metric_points",
    traces: "otel_traces",
    bmp: "bmp_routing_events"
  ]

  @min_days 1
  @min_partitions [attribution: 2]

  # A value above this multiple of the dataset's default is accepted with a
  # storage warning on the settings page.
  @storage_warning_factor 2

  @missing_table_error "this release has no warehouse table for the dataset yet; " <>
                         "the setting applies once it does"

  @initial_delay_ms 5_000
  @max_delay_ms 300_000
  @reconcile_interval_ms 60_000

  @spec tables() :: keyword(String.t())
  def tables, do: @tables

  @doc "Every dataset with a retention setting, in display order."
  @spec datasets() :: [atom()]
  def datasets, do: Keyword.keys(Env.default_retention_days())

  @doc "The warehouse tables a dataset owns; empty for a dataset whose table does not exist yet."
  @spec tables_for(atom()) :: [String.t()]
  def tables_for(dataset), do: for({^dataset, table} <- @tables, do: table)

  @doc "The product default for a dataset, used when neither the environment nor CNPG sets one."
  @spec default_days(atom()) :: pos_integer()
  def default_days(dataset), do: Keyword.fetch!(Env.default_retention_days(), dataset)

  @doc "The fewest days a dataset may be set to."
  @spec min_days(atom()) :: pos_integer()
  def min_days(_dataset), do: @min_days

  @doc "The fewest daily partitions the applier keeps for a dataset, whatever its days."
  @spec min_partitions(atom()) :: pos_integer()
  def min_partitions(dataset), do: Keyword.get(@min_partitions, dataset, 1)

  @doc "The `partition_live_number` applied for `days` of a dataset, after its floors."
  @spec partitions(atom(), integer()) :: pos_integer()
  def partitions(dataset, days) when is_integer(days) do
    Enum.max([days, min_days(dataset), min_partitions(dataset)])
  end

  @doc "Whether `days` is large enough to warrant a storage warning."
  @spec storage_warning?(atom(), integer()) :: boolean()
  def storage_warning?(dataset, days) when is_integer(days) do
    days > default_days(dataset) * @storage_warning_factor
  end

  @doc "Checks a value an operator wants to save against the dataset's floor."
  @spec validate_days(atom(), term()) :: :ok | {:error, String.t()}
  def validate_days(dataset, days) when is_integer(days) do
    min = min_days(dataset)
    max = ServiceRadar.Observability.WarehouseRetentionSetting.max_days()

    cond do
      days < min -> {:error, "must be at least #{min} #{pluralize_days(min)}"}
      days > max -> {:error, "must be at most #{max} days"}
      true -> :ok
    end
  end

  def validate_days(_dataset, _days), do: {:error, "must be a whole number of days"}

  @spec statements(keyword()) :: [String.t()]
  def statements(config) when is_list(config) do
    Enum.map(days_by_table(config), fn {table, days} -> alter_sql(table, days) end)
  end

  @doc "The statements that apply `days` to every table of one dataset."
  @spec dataset_statements(atom(), integer()) :: [String.t()]
  def dataset_statements(dataset, days) do
    partitions = partitions(dataset, days)
    Enum.map(tables_for(dataset), &alter_sql(&1, partitions))
  end

  @doc """
  The daily partitions each telemetry table keeps, in table order.

  With no argument this is the effective setting: the stored value of each
  dataset, or its environment seed while none is stored.
  """
  @spec days_by_table(keyword()) :: [{String.t(), pos_integer()}]
  def days_by_table(config) when is_list(config) do
    retention = Keyword.get(config, :retention_days, [])

    Enum.map(@tables, fn {dataset, table} ->
      {table, partitions(dataset, Keyword.get(retention, dataset, default_days(dataset)))}
    end)
  end

  @spec days_by_table() :: [{String.t(), pos_integer()}]
  def days_by_table, do: days_by_table(retention_days: effective_retention_days())

  @doc "The effective days of every dataset: stored when present, else the environment seed."
  @spec effective_retention_days(keyword()) :: keyword(pos_integer())
  def effective_retention_days(opts \\ []) do
    store = Keyword.get(opts, :store, Store)
    seeds = Keyword.get_lazy(opts, :seeds, &seed_days/0)

    stored =
      case store.list() do
        {:ok, rows} -> Map.new(rows, &{&1.dataset, &1.days})
        {:error, _reason} -> %{}
      end

    Enum.map(datasets(), fn dataset ->
      {dataset, Map.get(stored, Atom.to_string(dataset), Keyword.fetch!(seeds, dataset))}
    end)
  end

  @doc "The effective days of one dataset."
  @spec dataset_days(atom()) :: pos_integer()
  def dataset_days(dataset), do: Keyword.fetch!(effective_retention_days(), dataset)

  @doc "The environment seed of every dataset (the product default where the env is unset)."
  @spec seed_days() :: keyword(pos_integer())
  def seed_days, do: Keyword.get(Env.config(), :retention_days, Env.default_retention_days())

  @doc """
  Brings the warehouse in line with the stored settings once.

  Seeds a dataset with no row from `:seeds`, records the current seed on each
  row, then applies every dataset that needs it (all of them with
  `force: true`) and records the outcome. Returns `:retry` when the warehouse or
  CNPG did not answer, so the caller backs off, and `:ok` otherwise.
  """
  @spec reconcile(keyword()) :: :ok | :retry
  def reconcile(opts \\ []) do
    store = Keyword.get(opts, :store, Store)
    query = Keyword.get(opts, :query, &MySQL.query/1)
    seeds = Keyword.get_lazy(opts, :seeds, &seed_days/0)
    force = Keyword.get(opts, :force, false)

    case store.list() do
      {:ok, rows} ->
        results =
          rows
          |> ensure_seeded(seeds, store)
          |> Enum.map(&reconcile_row(&1, force, query, store))

        if Enum.member?(results, :retry), do: :retry, else: :ok

      {:error, reason} ->
        Logger.warning("Warehouse retention settings could not be read: #{inspect(reason)}")
        :retry
    end
  end

  @spec child_spec(term()) :: Supervisor.child_spec() | nil
  def child_spec(opts) do
    if Env.config()[:enabled] and Application.get_env(:serviceradar_core, :repo_enabled, true) do
      %{
        id: __MODULE__,
        start: {__MODULE__, :start_link, [List.wrap(opts)]},
        restart: :permanent,
        type: :worker
      }
    end
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    if Keyword.get(opts, :subscribe, true) do
      Phoenix.PubSub.subscribe(ServiceRadar.PubSub, WarehouseRetentionNotifier.topic())
    end

    send(self(), :reconcile)

    {:ok,
     %{
       opts: opts,
       force: true,
       delay: Keyword.get(opts, :initial_delay_ms, @initial_delay_ms),
       interval: Keyword.get(opts, :interval_ms, @reconcile_interval_ms),
       timer: nil
     }}
  end

  @impl true
  def handle_info(:reconcile, state), do: {:noreply, run_reconcile(state)}

  def handle_info({:warehouse_retention_changed, _dataset}, state) do
    initial = Keyword.get(state.opts, :initial_delay_ms, @initial_delay_ms)
    {:noreply, run_reconcile(%{state | delay: initial})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp run_reconcile(state) do
    if state.timer, do: Process.cancel_timer(state.timer)

    case reconcile(Keyword.put(state.opts, :force, state.force)) do
      :ok ->
        initial = Keyword.get(state.opts, :initial_delay_ms, @initial_delay_ms)
        timer = Process.send_after(self(), :reconcile, state.interval)
        %{state | force: false, delay: initial, timer: timer}

      :retry ->
        Logger.warning("Warehouse retention not fully applied, retrying in #{state.delay}ms")
        timer = Process.send_after(self(), :reconcile, state.delay)
        # The start-up pass stays forced until one completes, so a warehouse
        # rebuilt while core was retrying still gets every dataset.
        %{state | delay: next_delay(state.delay), timer: timer}
    end
  end

  defp next_delay(delay), do: min(delay * 2, @max_delay_ms)

  defp ensure_seeded(rows, seeds, store) do
    by_dataset = Map.new(rows, &{&1.dataset, &1})

    Enum.flat_map(datasets(), fn dataset ->
      seed = Keyword.fetch!(seeds, dataset)

      case Map.fetch(by_dataset, Atom.to_string(dataset)) do
        {:ok, %{seed_days: ^seed} = row} ->
          [{dataset, row}]

        {:ok, row} ->
          [{dataset, record(row, store.record_seed(row, %{seed_days: seed}), :record_seed)}]

        :error ->
          case store.seed(Atom.to_string(dataset), seed) do
            {:ok, row} ->
              [{dataset, row}]

            # Another core seeded it first; the next pass reads that row.
            {:error, reason} ->
              Logger.warning("Warehouse retention for #{dataset} not seeded: #{inspect(reason)}")
              []
          end
      end
    end)
  end

  defp reconcile_row({dataset, row}, force, query, store) do
    if force or needs_apply?(row) do
      outcome = apply_dataset(dataset, row.days, query)
      maybe_record_outcome(store, row, outcome)
      if outcome.retry, do: :retry, else: :ok
    else
      :ok
    end
  end

  defp needs_apply?(row) do
    row.last_applied_status != "applied" or row.last_applied_days != row.days
  end

  defp apply_dataset(dataset, days, query) do
    case dataset_statements(dataset, days) do
      [] ->
        %{status: "pending", error: @missing_table_error, days: nil, retry: false}

      statements ->
        statements
        |> Enum.reduce_while(:ok, fn sql, :ok ->
          case query.(sql) do
            {:ok, _result} -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> case do
          :ok ->
            %{status: "applied", error: nil, days: days, retry: false}

          {:error, reason} ->
            Logger.warning("StarRocks retention for #{dataset} not applied: #{inspect(reason)}")
            %{status: failure_status(reason), error: format_error(reason), days: nil, retry: true}
        end
    end
  end

  # The Frontend did not answer: the value is still on its way. Anything else is
  # the warehouse refusing it, which is retried too but shown as a failure.
  defp failure_status(reason) when reason in [:connect_failed, :starrocks_mysql_not_started],
    do: "pending"

  defp failure_status(_reason), do: "failed"

  defp format_error({:starrocks_mysql, message}) when is_binary(message), do: message
  defp format_error(:connect_failed), do: "the StarRocks Frontend did not answer"
  defp format_error(:starrocks_mysql_not_started), do: "the StarRocks connection is not started"
  defp format_error(reason), do: inspect(reason)

  defp maybe_record_outcome(store, row, %{status: "applied", days: days}) do
    attrs = %{
      last_applied_status: "applied",
      last_applied_days: days,
      last_applied_error: nil,
      last_applied_at: DateTime.utc_now()
    }

    record(row, store.record_outcome(row, attrs), :record_outcome)
  end

  # A failed attempt keeps the last value the warehouse did take; only the
  # status and error change, and an unchanged outcome is not rewritten on every
  # retry.
  defp maybe_record_outcome(store, row, %{status: status, error: error}) do
    if row.last_applied_status != status or row.last_applied_error != error do
      attrs = %{last_applied_status: status, last_applied_error: error}
      record(row, store.record_outcome(row, attrs), :record_outcome)
    else
      row
    end
  end

  defp record(row, result, action) do
    case result do
      {:ok, updated} ->
        updated

      {:error, reason} ->
        Logger.warning(
          "Warehouse retention #{action} for #{row.dataset} failed: #{inspect(reason)}"
        )

        row
    end
  end

  defp alter_sql(table, partitions) do
    "ALTER TABLE `#{table}` SET (\"partition_live_number\" = \"#{partitions}\")"
  end

  defp pluralize_days(1), do: "day"
  defp pluralize_days(_n), do: "days"
end
