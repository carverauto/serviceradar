defmodule ServiceRadar.Inventory.SyncIngestorQueue do
  @moduledoc """
  Buffers sync result chunks per tenant and coalesces bursts before ingestion.
  """

  use GenServer

  require Logger

  alias ServiceRadar.Cluster.TenantSchemas
  alias ServiceRadar.Integrations.IntegrationSource
  alias ServiceRadar.Inventory.SyncIngestor

  defmodule TenantQueue do
    @moduledoc false
    defstruct batches: [], chunk_count: 0, timer_ref: nil, inflight: false, ready: false
  end

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def enqueue(message, tenant_id) do
    GenServer.cast(__MODULE__, {:enqueue, tenant_id, message})
  end

  def ingest_sync_results(message, tenant_id) do
    do_ingest_results(message, tenant_id)
  end

  @impl true
  def init(_opts) do
    {:ok, %{tenants: %{}, inflight_refs: %{}, inflight_count: 0}}
  end

  @impl true
  def handle_cast({:enqueue, tenant_id, message}, state) do
    case decode_results(message) do
      {:ok, updates} ->
        {:noreply, enqueue_updates(state, tenant_id, updates)}

      {:error, reason} ->
        Logger.warning("Sync results decode failed for tenant=#{tenant_id}: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:flush, tenant_id}, state) do
    {state, tenant} = pop_tenant(state, tenant_id)

    cond do
      tenant == nil ->
        {:noreply, state}

      tenant.chunk_count == 0 ->
        {:noreply, state}

      true ->
        tenant = %{tenant | timer_ref: nil, ready: true}
        state = put_tenant(state, tenant_id, tenant)
        {:noreply, maybe_start_ready_tenants(state)}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.inflight_refs, ref) do
      {nil, _refs} ->
        {:noreply, state}

      {tenant_id, refs} ->
        state = %{state | inflight_refs: refs, inflight_count: max(state.inflight_count - 1, 0)}
        {state, tenant} = pop_tenant(state, tenant_id)

        state =
          if tenant do
            tenant = %{tenant | inflight: false}
            put_tenant(state, tenant_id, tenant)
          else
            state
          end

        if reason != :normal do
          Logger.warning("Sync ingestion task for tenant=#{tenant_id} exited: #{inspect(reason)}")
        end

        {:noreply, maybe_start_ready_tenants(state)}
    end
  end

  defp enqueue_updates(state, tenant_id, updates) do
    {state, tenant} = pop_tenant(state, tenant_id)
    tenant = tenant || %TenantQueue{}

    tenant = %{
      tenant
      | batches: [updates | tenant.batches],
        chunk_count: tenant.chunk_count + 1
    }

    {tenant, state} = maybe_schedule_flush(state, tenant_id, tenant)
    state = put_tenant(state, tenant_id, tenant)

    if force_flush?(tenant) do
      cancel_timer(tenant.timer_ref)
      send(self(), {:flush, tenant_id})
      state
    else
      state
    end
  end

  defp maybe_schedule_flush(state, tenant_id, tenant) do
    coalesce_ms = coalesce_window_ms()

    cond do
      coalesce_ms <= 0 ->
        send(self(), {:flush, tenant_id})
        {tenant, state}

      tenant.timer_ref == nil ->
        ref = Process.send_after(self(), {:flush, tenant_id}, coalesce_ms)
        {%{tenant | timer_ref: ref}, state}

      true ->
        {tenant, state}
    end
  end

  defp force_flush?(tenant) do
    max_chunks = queue_max_chunks()

    is_integer(max_chunks) and max_chunks > 0 and tenant.chunk_count >= max_chunks
  end

  defp maybe_start_ready_tenants(state) do
    max_inflight = max_inflight_chunks()

    available =
      if is_integer(max_inflight) and max_inflight > 0 do
        max_inflight - state.inflight_count
      else
        0
      end

    if available <= 0 do
      state
    else
      ready =
        state.tenants
        |> Enum.filter(fn {_tenant_id, tenant} ->
          tenant.ready and not tenant.inflight and tenant.chunk_count > 0
        end)
        |> Enum.take(available)

      Enum.reduce(ready, state, fn {tenant_id, tenant}, acc ->
        case start_ingestion_task(acc, tenant_id, tenant) do
          {:ok, updated} -> updated
          {:error, updated} -> updated
        end
      end)
    end
  end

  defp start_ingestion_task(state, tenant_id, tenant) do
    updates = tenant.batches |> Enum.reverse() |> List.flatten()

    Logger.info(
      "Coalesced #{tenant.chunk_count} sync chunks into #{length(updates)} updates for tenant=#{tenant_id}"
    )

    tenant = %{tenant | batches: [], chunk_count: 0, inflight: true, ready: false, timer_ref: nil}
    state = put_tenant(state, tenant_id, tenant)

    task_fun = fn ->
      ingest_updates(updates, tenant_id)
    end

    case start_task(task_fun) do
      {:ok, ref} ->
        state = update_inflight(state, ref, tenant_id)

        {:ok, state}

      {:error, reason} ->
        Logger.warning("Failed to start sync ingestion task for tenant=#{tenant_id}: #{inspect(reason)}")
        tenant = %{tenant | inflight: false, ready: true}
        {:error, put_tenant(state, tenant_id, tenant)}
    end
  end

  defp start_task(task_fun) do
    case Task.Supervisor.start_child(ServiceRadar.SyncIngestor.TaskSupervisor, task_fun) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        {:ok, ref}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, other}
    end
  end

  defp update_inflight(state, ref, tenant_id) do
    %{
      state
      | inflight_refs: Map.put(state.inflight_refs, ref, tenant_id),
        inflight_count: state.inflight_count + 1
    }
  end

  defp pop_tenant(state, tenant_id) do
    {tenant, tenants} = Map.pop(state.tenants, tenant_id)
    {%{state | tenants: tenants}, tenant}
  end

  defp put_tenant(state, tenant_id, tenant) do
    %{state | tenants: Map.put(state.tenants, tenant_id, tenant)}
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)

  defp coalesce_window_ms do
    Application.get_env(:serviceradar_core, :sync_ingestor_coalesce_ms, 250)
  end

  defp queue_max_chunks do
    Application.get_env(:serviceradar_core, :sync_ingestor_queue_max_chunks, 10)
  end

  defp max_inflight_chunks do
    configured = Application.get_env(:serviceradar_core, :sync_ingestor_max_inflight, 2)

    if is_integer(configured) and configured > 0 do
      configured
    else
      1
    end
  end

  defp ingest_updates(updates, tenant_id) do
    Logger.info("Processing sync results for tenant=#{tenant_id}")
    Logger.info("Decoded #{length(updates)} sync updates for tenant=#{tenant_id}")

    actor = system_actor(tenant_id)
    result = sync_ingestor().ingest_updates(updates, tenant_id, actor: actor)
    Logger.info("SyncIngestor result for tenant=#{tenant_id}: #{inspect(result)}")

    record_sync_status(updates, tenant_id, actor, result)

    result
  rescue
    error ->
      Logger.warning("Sync results ingestion failed for tenant=#{tenant_id}: #{inspect(error)}")
      {:error, error}
  end

  defp do_ingest_results(message, tenant_id) do
    case decode_results(message) do
      {:ok, updates} ->
        ingest_updates(updates, tenant_id)

      {:error, reason} ->
        Logger.warning("Sync results decode failed for tenant=#{tenant_id}: #{inspect(reason)}")
        {:error, {:invalid_sync_results, reason}}
    end
  end

  defp record_sync_status(updates, tenant_id, actor, ingest_result) do
    sync_service_id = extract_sync_service_id(updates)

    if sync_service_id do
      tenant_schema = TenantSchemas.schema_for_tenant(tenant_id)

      sync_result =
        case ingest_result do
          :ok -> :success
          {:error, _} -> :failed
        end

      case IntegrationSource.get_by_id(sync_service_id,
             tenant: tenant_schema,
             actor: actor,
             authorize?: false
           ) do
        {:ok, source} ->
          source
          |> Ash.Changeset.for_update(:record_sync, %{
            result: sync_result,
            device_count: length(updates)
          })
          |> Ash.update(tenant: tenant_schema, actor: actor, authorize?: false)
          |> case do
            {:ok, _} ->
              Logger.debug("Recorded sync status for IntegrationSource #{sync_service_id}")

            {:error, reason} ->
              Logger.warning(
                "Failed to record sync status for #{sync_service_id}: #{inspect(reason)}"
              )
          end

        {:error, reason} ->
          Logger.debug(
            "Could not find IntegrationSource #{sync_service_id} to record sync: #{inspect(reason)}"
          )
      end
    end
  rescue
    error ->
      Logger.warning("Error recording sync status: #{inspect(error)}")
  end

  defp extract_sync_service_id([update | _]) when is_map(update) do
    metadata = update["metadata"] || update[:metadata] || %{}
    metadata["sync_service_id"] || metadata[:sync_service_id]
  end

  defp extract_sync_service_id(_), do: nil

  defp decode_results(nil), do: {:ok, []}

  defp decode_results(message) when is_binary(message) do
    case Jason.decode(message) do
      {:ok, updates} when is_list(updates) -> {:ok, updates}
      {:ok, _other} -> {:error, :unexpected_payload}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_results(_message), do: {:error, :unsupported_payload}

  defp system_actor(tenant_id) do
    %{
      id: "system",
      email: "gateway@serviceradar",
      role: :admin,
      tenant_id: tenant_id
    }
  end

  defp sync_ingestor do
    Application.get_env(:serviceradar_core, :sync_ingestor, SyncIngestor)
  end
end
