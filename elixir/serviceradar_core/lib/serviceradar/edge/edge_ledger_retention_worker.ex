defmodule ServiceRadar.Edge.EdgeLedgerRetentionWorker do
  @moduledoc """
  Prunes expired rows from the edge-record ledger and delivery-slot tables in
  bounded batches:

    * `platform.edge_sweep_batch_slots`
    * `platform.edge_sweep_projected_rows`
    * `platform.edge_delivery_slots`
    * `platform.event_ledger`

  ## Retention Horizon

  The retention horizon (`retention_horizon_seconds/1`) is derived from the
  maximum of four protocol and broker limits rather than a guessed constant:

    1. The edge-record stream `MaxAge` (`EventWriter.Config.edge_record_stream/0`
       and `EventWriter.Config.edge_record_audit_stream/0`).
    2. The dead-letter stream's retention (`EventWriter.Config.edge_record_dead_letter_stream/0`).
    3. Standing output grant validity (`OutputGrants.max_lifetime_seconds/0`).
    4. The agent spool's retry horizon: the longer of standing-grant validity
       or the sweep lease horizon ceiling (`PipelineSettings.default_max_horizon_seconds/0`
       or any higher ceiling configured in `platform.edge_pipeline_settings`)
       plus `ContractRegistry`'s 3600s lease margin and `DeliveryGrants.ttl_seconds/0`.

  ## Draining Registry Epoch Guard (#6356)

  `ServiceRadar.Edge.ContractRegistry` keeps a draining epoch in
  `state = 'draining'` while any scheduled sweep slot in
  `platform.sweep_execution_slots` inserted up to `draining_since + 3600s` still
  has an open collection window (`collection_expires > now`). Retention never
  deletes a slot or ledger row inserted during a draining epoch's window (up to
  `draining_since + 3600s`) or associated with a scheduled sweep execution slot
  whose collection window is still open.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 1800, states: [:available, :scheduled, :executing, :retryable]]

  alias ServiceRadar.Edge.DeliveryGrants
  alias ServiceRadar.Edge.OutputGrants
  alias ServiceRadar.Edge.PipelineSettings
  alias ServiceRadar.EventWriter
  alias ServiceRadar.Repo

  require Logger

  @default_batch_size 5_000
  @default_max_batches 40
  @draining_epoch_lease_margin_seconds 3_600
  @ns_per_second 1_000_000_000

  @delete_sweep_batch_slots_sql """
  DELETE FROM platform.edge_sweep_batch_slots AS target
  WHERE target.ctid IN (
    SELECT candidate.ctid
    FROM platform.edge_sweep_batch_slots AS candidate
    WHERE candidate.inserted_at < $1
      AND NOT EXISTS (
        SELECT 1
        FROM platform.edge_contract_registry_epochs AS epoch
        WHERE epoch.state = 'draining'
          AND epoch.draining_since IS NOT NULL
          AND candidate.inserted_at >= COALESCE(epoch.activated_at, epoch.created_at) - INTERVAL '300 seconds'
          AND candidate.inserted_at <= epoch.draining_since + ($3 * INTERVAL '1 second')
      )
      AND NOT EXISTS (
        SELECT 1
        FROM platform.sweep_execution_slots AS slot
        WHERE slot.id = candidate.execution_id
          AND slot.state = 'scheduled'
          AND slot.collection_expires > $2
      )
    LIMIT $4
  )
  """

  @delete_sweep_projected_rows_sql """
  DELETE FROM platform.edge_sweep_projected_rows AS target
  WHERE target.ctid IN (
    SELECT candidate.ctid
    FROM platform.edge_sweep_projected_rows AS candidate
    WHERE candidate.inserted_at < $1
      AND NOT EXISTS (
        SELECT 1
        FROM platform.edge_contract_registry_epochs AS epoch
        WHERE epoch.state = 'draining'
          AND epoch.draining_since IS NOT NULL
          AND candidate.inserted_at >= COALESCE(epoch.activated_at, epoch.created_at) - INTERVAL '300 seconds'
          AND candidate.inserted_at <= epoch.draining_since + ($2 * INTERVAL '1 second')
      )
      AND NOT EXISTS (
        SELECT 1
        FROM platform.edge_sweep_batch_slots AS batch
        WHERE batch.network_scope_id = candidate.network_scope_id
          AND batch.event_id = candidate.event_id
      )
    LIMIT $3
  )
  """

  @delete_delivery_slots_sql """
  DELETE FROM platform.edge_delivery_slots AS target
  WHERE target.ctid IN (
    SELECT candidate.ctid
    FROM platform.edge_delivery_slots AS candidate
    WHERE candidate.inserted_at < $1
      AND NOT EXISTS (
        SELECT 1
        FROM platform.edge_contract_registry_epochs AS epoch
        WHERE epoch.state = 'draining'
          AND epoch.draining_since IS NOT NULL
          AND candidate.inserted_at >= COALESCE(epoch.activated_at, epoch.created_at) - INTERVAL '300 seconds'
          AND candidate.inserted_at <= epoch.draining_since + ($2 * INTERVAL '1 second')
      )
      AND NOT EXISTS (
        SELECT 1
        FROM platform.edge_sweep_batch_slots AS batch
        WHERE batch.network_scope_id = candidate.network_scope_id
          AND batch.event_id = candidate.event_id
      )
    LIMIT $3
  )
  """

  @delete_event_ledger_sql """
  DELETE FROM platform.event_ledger AS target
  WHERE target.ctid IN (
    SELECT candidate.ctid
    FROM platform.event_ledger AS candidate
    WHERE candidate.inserted_at < $1
      AND NOT EXISTS (
        SELECT 1
        FROM platform.edge_contract_registry_epochs AS epoch
        WHERE epoch.state = 'draining'
          AND epoch.draining_since IS NOT NULL
          AND candidate.inserted_at >= COALESCE(epoch.activated_at, epoch.created_at) - INTERVAL '300 seconds'
          AND candidate.inserted_at <= epoch.draining_since + ($2 * INTERVAL '1 second')
      )
      AND NOT EXISTS (
        SELECT 1
        FROM platform.edge_sweep_batch_slots AS batch
        WHERE batch.network_scope_id = candidate.network_scope_id
          AND batch.event_id = candidate.event_id
      )
      AND NOT EXISTS (
        SELECT 1
        FROM platform.edge_delivery_slots AS slot
        WHERE slot.network_scope_id = candidate.network_scope_id
          AND slot.event_id = candidate.event_id
      )
    LIMIT $3
  )
  """

  @spec default_batch_size() :: pos_integer()
  def default_batch_size, do: @default_batch_size

  @spec default_max_batches() :: pos_integer()
  def default_max_batches, do: @default_max_batches

  @spec draining_epoch_lease_margin_seconds() :: pos_integer()
  def draining_epoch_lease_margin_seconds, do: @draining_epoch_lease_margin_seconds

  @spec retention_components(pos_integer()) :: %{
          dead_letter_retention_seconds: pos_integer(),
          output_grant_max_lifetime_seconds: pos_integer(),
          spool_retry_horizon_seconds: pos_integer()
        }
  def retention_components(
        max_sweep_horizon_seconds \\ PipelineSettings.default_max_horizon_seconds()
      )
      when is_integer(max_sweep_horizon_seconds) and max_sweep_horizon_seconds > 0 do
    # The source streams have no MaxAge: records leave on acknowledgement, so
    # there is no stream-expiry component. A ledger row must outlive every path
    # that can still need it: the dead-letter redelivery window, the
    # output-grant lifetime, and the agent spool retry horizon.
    dead_letter = EventWriter.Config.edge_record_dead_letter_stream()

    dead_letter_retention_seconds =
      div(
        max(dead_letter.stream_max_age, Map.get(dead_letter, :stream_duplicate_window, 0)),
        @ns_per_second
      )

    output_grant_max_lifetime_seconds = OutputGrants.max_lifetime_seconds()

    spool_retry_horizon_seconds =
      max(
        output_grant_max_lifetime_seconds,
        max_sweep_horizon_seconds + @draining_epoch_lease_margin_seconds
      ) + DeliveryGrants.ttl_seconds()

    %{
      dead_letter_retention_seconds: dead_letter_retention_seconds,
      output_grant_max_lifetime_seconds: output_grant_max_lifetime_seconds,
      spool_retry_horizon_seconds: spool_retry_horizon_seconds
    }
  end

  @spec retention_horizon_seconds(pos_integer()) :: pos_integer()
  def retention_horizon_seconds(
        max_sweep_horizon_seconds \\ PipelineSettings.default_max_horizon_seconds()
      ) do
    max_sweep_horizon_seconds
    |> retention_components()
    |> Map.values()
    |> Enum.max()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    config = Application.get_env(:serviceradar_core, __MODULE__, [])

    batch_size =
      resolve_positive_integer(args, "batch_size", config, :batch_size, @default_batch_size)

    max_batches =
      resolve_positive_integer(args, "max_batches", config, :max_batches, @default_max_batches)

    now = DateTime.utc_now()
    margin = @draining_epoch_lease_margin_seconds

    with {:ok, horizon_seconds} <- effective_horizon_seconds(),
         cutoff = DateTime.shift(now, second: -horizon_seconds),
         {:ok, deleted_batch_slots} <-
           delete_in_batches(
             @delete_sweep_batch_slots_sql,
             fn limit -> [cutoff, now, margin, limit] end,
             batch_size,
             max_batches
           ),
         {:ok, deleted_projected_rows} <-
           delete_in_batches(
             @delete_sweep_projected_rows_sql,
             fn limit -> [cutoff, margin, limit] end,
             batch_size,
             max_batches
           ),
         {:ok, deleted_delivery_slots} <-
           delete_in_batches(
             @delete_delivery_slots_sql,
             fn limit -> [cutoff, margin, limit] end,
             batch_size,
             max_batches
           ),
         {:ok, deleted_ledger_rows} <-
           delete_in_batches(
             @delete_event_ledger_sql,
             fn limit -> [cutoff, margin, limit] end,
             batch_size,
             max_batches
           ) do
      Logger.info(
        "Edge ledger retention completed",
        horizon_seconds: horizon_seconds,
        batch_size: batch_size,
        max_batches: max_batches,
        deleted_sweep_batch_slots: deleted_batch_slots,
        deleted_sweep_projected_rows: deleted_projected_rows,
        deleted_delivery_slots: deleted_delivery_slots,
        deleted_event_ledger: deleted_ledger_rows
      )

      :ok
    else
      {:error, reason} ->
        Logger.error("Edge ledger retention failed", reason: inspect(reason))
        {:error, reason}
    end
  end

  defp effective_horizon_seconds do
    default_ceiling = PipelineSettings.default_max_horizon_seconds()

    case Repo.query(
           """
           SELECT max(GREATEST(COALESCE(max_horizon_seconds, 0), COALESCE(horizon_seconds, 0)))
           FROM platform.edge_pipeline_settings
           """,
           []
         ) do
      {:ok, %{rows: [[value]]}} when is_integer(value) ->
        {:ok, retention_horizon_seconds(max(default_ceiling, value))}

      {:ok, %{rows: [[nil]]}} ->
        {:ok, retention_horizon_seconds(default_ceiling)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_positive_integer(args, arg_key, config, config_key, default) do
    case Map.get(args || %{}, arg_key) do
      value when is_integer(value) and value > 0 ->
        value

      _ ->
        case Keyword.get(config, config_key, default) do
          value when is_integer(value) and value > 0 -> value
          _ -> default
        end
    end
  end

  defp delete_in_batches(sql, params_fun, batch_size, max_batches) do
    delete_batches_loop(sql, params_fun, batch_size, max_batches, 0, 0)
  end

  defp delete_batches_loop(_sql, _params_fun, _batch_size, max_batches, batches, deleted_acc)
       when batches >= max_batches do
    {:ok, deleted_acc}
  end

  defp delete_batches_loop(sql, params_fun, batch_size, max_batches, batches, deleted_acc) do
    case Repo.query(sql, params_fun.(batch_size)) do
      {:ok, %{num_rows: deleted}} when deleted < batch_size ->
        {:ok, deleted_acc + deleted}

      {:ok, %{num_rows: deleted}} ->
        delete_batches_loop(
          sql,
          params_fun,
          batch_size,
          max_batches,
          batches + 1,
          deleted_acc + deleted
        )

      {:error, reason} ->
        {:error, reason}
    end
  end
end
