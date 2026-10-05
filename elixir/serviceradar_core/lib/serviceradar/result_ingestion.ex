defmodule ServiceRadar.ResultIngestion do
  @moduledoc """
  Per-class ingestion queues behind `ServiceRadar.ResultsRouter`.

  Each result class that does database work gets its own
  `ServiceRadar.ResultIngestion.KeyedQueue`, keyed by agent so one agent's
  results apply in arrival order while different agents ingest concurrently.

  Defaults can be overridden per class:

      config :serviceradar_core, ServiceRadar.ResultIngestion,
        sweep: [workers: 4, max_items: 512, max_bytes: 268_435_456,
                max_items_per_key: 32, job_timeout_ms: 120_000],
        mapper: [enabled: false]

  `enabled: false` sends that class back through the router's inline path.
  """

  use Supervisor

  alias ServiceRadar.ResultIngestion.KeyedQueue

  @task_supervisor ServiceRadar.ResultIngestion.TaskSupervisor

  @defaults %{
    sweep: [workers: 4, max_items: 512, max_bytes: 256 * 1_024 * 1_024, max_items_per_key: 32],
    mapper: [workers: 2, max_items: 256, max_bytes: 128 * 1_024 * 1_024, max_items_per_key: 16],
    bumblebee: [workers: 2, max_items: 256, max_bytes: 128 * 1_024 * 1_024, max_items_per_key: 16],
    plugin_result: [
      workers: 2,
      max_items: 256,
      max_bytes: 128 * 1_024 * 1_024,
      max_items_per_key: 16
    ],
    # StatusHandler's periodic full-state reports: a newer pending report for an
    # agent replaces the older one, so an agent holds at most one running and one
    # pending report.
    workload_identity: [
      workers: 2,
      max_items: 1_024,
      max_bytes: 256 * 1_024 * 1_024,
      max_items_per_key: 2,
      coalesce: true
    ],
    addon_status: [
      workers: 2,
      max_items: 1_024,
      max_bytes: 64 * 1_024 * 1_024,
      max_items_per_key: 2,
      coalesce: true
    ],
    # Decode and admission of endpoint inventory, off the StatusHandler process.
    endpoint_inventory_admission: [
      workers: 4,
      max_items: 256,
      max_bytes: 256 * 1_024 * 1_024,
      max_items_per_key: 32
    ],
    # The router's batched service-state upserts, one batch at a time.
    service_state: [
      workers: 1,
      max_items: 64,
      max_bytes: 64 * 1_024 * 1_024,
      max_items_per_key: 64
    ]
  }

  @default_job_timeout_ms 120_000

  @type class ::
          :sweep
          | :mapper
          | :bumblebee
          | :plugin_result
          | :workload_identity
          | :addon_status
          | :endpoint_inventory_admission
          | :service_state

  @spec classes() :: [class()]
  def classes, do: Map.keys(@defaults)

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "The registered name of a class's queue."
  @spec queue(class()) :: atom()
  def queue(class), do: Module.concat(__MODULE__, Macro.camelize(Atom.to_string(class)))

  @doc "Whether a class is routed through its queue (on unless configured off)."
  @spec enabled?(class()) :: boolean()
  def enabled?(class), do: Keyword.get(class_config(class), :enabled, true) != false

  @doc """
  Admits `fun` to a class queue under `key`.

  Returns `:inline` when the class is configured off or its queue is not
  running; the caller then does the work itself, as before the queues existed.
  """
  @spec admit(class(), term(), non_neg_integer(), (-> term()), keyword()) ::
          :ok | :inline | {:error, term()}
  def admit(class, key, bytes, fun, opts \\ []) do
    if enabled?(class) and is_pid(Process.whereis(queue(class))) do
      KeyedQueue.admit(queue(class), key, bytes, fun, opts)
    else
      :inline
    end
  end

  @doc "Current stats of every running class queue. Never touches the database."
  @spec stats() :: %{class() => map()}
  def stats do
    for class <- classes(),
        {:ok, stats} <- [KeyedQueue.stats(queue(class))],
        into: %{},
        do: {class, stats}
  end

  @impl true
  def init(_opts) do
    queues =
      for class <- classes() do
        config = class_config(class)

        Supervisor.child_spec(
          {KeyedQueue,
           [
             name: queue(class),
             class: class,
             task_supervisor: @task_supervisor,
             workers: Keyword.fetch!(config, :workers),
             max_items: Keyword.fetch!(config, :max_items),
             max_bytes: Keyword.fetch!(config, :max_bytes),
             max_items_per_key: Keyword.fetch!(config, :max_items_per_key),
             job_timeout_ms: Keyword.get(config, :job_timeout_ms, @default_job_timeout_ms),
             coalesce: Keyword.get(config, :coalesce, false)
           ]},
          id: {KeyedQueue, class}
        )
      end

    Supervisor.init([{Task.Supervisor, name: @task_supervisor} | queues], strategy: :one_for_all)
  end

  defp class_config(class) do
    overrides =
      :serviceradar_core
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(class, [])

    Keyword.merge(Map.fetch!(@defaults, class), overrides)
  end
end
