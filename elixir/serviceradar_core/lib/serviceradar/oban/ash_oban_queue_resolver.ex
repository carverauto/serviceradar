defmodule ServiceRadar.Oban.AshObanQueueResolver do
  @moduledoc """
  Queue resolver for AshOban that routes jobs to tenant-specific queues.

  When used with AshOban triggers, this module determines the correct
  queue for a job based on the resource's tenant_id.

  ## Usage in Ash Resources

      defmodule MyResource do
        use Ash.Resource,
          extensions: [AshOban]

        oban do
          triggers do
            trigger :my_action do
              queue {:mfa, {ServiceRadar.Oban.AshObanQueueResolver, :resolve, [:integrations]}}
              worker MyWorker
            end
          end
        end
      end

  ## How It Works

  1. When an AshOban trigger fires, the queue can be a static atom or an MFA
  2. This resolver is called with the record and returns the tenant-specific queue
  3. The job is inserted into the correct tenant queue

  ## Queue Type Mapping

  The resolver maps AshOban trigger queues to tenant queue types:
  - `:service_checks` → tenant's service check queue
  - `:alerts` → tenant's alerts queue
  - `:notifications` → tenant's notification queue
  - `:onboarding` → tenant's onboarding queue
  - `:events` → tenant's events queue
  - `:integrations` → tenant's integrations queue
  - `:edge` → tenant's edge queue
  - `:sweeps` → tenant's sweeps queue
  - `:default` → tenant's default queue
  """

  alias ServiceRadar.Oban.TenantQueues

  require Logger

  @doc """
  Resolves the queue name for an AshOban trigger.

  Called by AshOban with the record and queue_type.
  Returns the tenant queue name for the tenant-scoped Oban instance.

  ## Parameters

    - `record` - The Ash resource record triggering the job
    - `queue_type` - The queue type atom (:service_checks, :alerts, :notifications, etc.)

  ## Returns

  The queue name atom (e.g., `:alerts`)
  """
  @spec resolve(Ash.Resource.record(), atom()) :: atom()
  def resolve(record, queue_type \\ :default) do
    tenant_id = extract_tenant_id(record)

    if tenant_id do
      TenantQueues.get_queue_name(tenant_id, queue_type)
    else
      # Fallback to global queue if no tenant
      Logger.warning("AshObanQueueResolver: No tenant_id found for #{inspect(record.__struct__)}")
      queue_type
    end
  end

  @doc """
  Extracts tenant_id from a record.

  Supports records with:
  - Direct `tenant_id` attribute
  - Nested `tenant` relationship with `id`
  - Ash context tenant
  """
  @spec extract_tenant_id(Ash.Resource.record()) :: String.t() | nil
  def extract_tenant_id(record) do
    cond do
      # Direct tenant_id attribute
      Map.has_key?(record, :tenant_id) and is_binary(record.tenant_id) ->
        record.tenant_id

      # Loaded tenant relationship
      Map.has_key?(record, :tenant) and is_map(record.tenant) and Map.has_key?(record.tenant, :id) ->
        record.tenant.id

      # Ash actor tenant context (if available in metadata)
      Map.has_key?(record, :__metadata__) and
          Map.has_key?(record.__metadata__, :tenant) ->
        record.__metadata__.tenant

      true ->
        nil
    end
  end

  @doc """
  Returns job options for AshOban with tenant metadata.

  Use this in AshOban trigger configuration to ensure tenant_id
  is passed to the worker.

  ## Example

      oban do
        triggers do
          trigger :process do
            worker MyWorker
            on_insert? true
            # Add tenant metadata to job
            extra_args &AshObanQueueResolver.job_meta/1
          end
        end
      end
  """
  @spec job_meta(Ash.Resource.record()) :: map()
  def job_meta(record) do
    tenant_id = extract_tenant_id(record)

    if tenant_id do
      %{tenant_id: tenant_id}
    else
      %{}
    end
  end

  @doc """
  Creates a queue resolver function for a specific queue type.

  Returns an MFA tuple suitable for AshOban configuration.

  ## Example

      oban do
        triggers do
          trigger :sync_config do
            queue AshObanQueueResolver.queue_for(:sync)
          end
        end
      end
  """
  @spec queue_for(atom()) :: {:mfa, {module(), atom(), [atom()]}}
  def queue_for(queue_type) when is_atom(queue_type) do
    {:mfa, {__MODULE__, :resolve, [queue_type]}}
  end
end
