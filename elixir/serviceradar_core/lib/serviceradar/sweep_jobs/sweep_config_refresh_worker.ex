defmodule ServiceRadar.SweepJobs.SweepConfigRefreshWorker do
  @moduledoc """
  Oban worker that periodically checks if sweep target lists have changed.

  When device inventory changes (new devices discovered, attributes updated, devices deleted),
  the target list for a sweep group may change even though the group's criteria hasn't.
  This worker detects such changes by:

  1. Computing the current target list hash for each enabled sweep group
  2. Comparing with the stored `target_hash` on the group
  3. If changed, updating the hash and invalidating the config cache

  This ensures agents receive updated configs within the refresh interval.

  ## Configuration

  The worker is typically scheduled via Oban cron:

      config :serviceradar_core, Oban,
        plugins: [
          {Oban.Plugins.Cron, crontab: [
            {"*/5 * * * *", ServiceRadar.SweepJobs.SweepConfigRefreshWorker}
          ]}
        ]
  """

  use Oban.Worker,
    queue: :config_refresh,
    max_attempts: 3,
    unique: [period: 60, states: [:available, :scheduled, :executing, :retryable]]

  alias ServiceRadar.AgentConfig.ConfigPublisher
  alias ServiceRadar.AgentConfig.Compilers.SweepCompiler
  alias ServiceRadar.Cluster.TenantSchemas
  alias ServiceRadar.SweepJobs.SweepGroup

  require Logger
  require Ash.Query

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    tenant_id = Map.get(args, "tenant_id")

    Logger.info("Running sweep config refresh check", tenant_id: tenant_id)

    case get_tenants_to_check(tenant_id) do
      {:ok, tenants} ->
        results =
          Enum.map(tenants, fn tenant ->
            check_tenant_sweep_groups(tenant)
          end)

        total_updated = Enum.sum(results)
        Logger.info("Sweep config refresh complete", updated_groups: total_updated)
        :ok

      {:error, reason} ->
        Logger.error("Failed to get tenants for sweep config refresh", reason: inspect(reason))
        {:error, reason}
    end
  end

  # Get tenants to check - either a specific tenant or all tenants
  defp get_tenants_to_check(nil) do
    ServiceRadar.Identity.Tenant
    |> Ash.read(authorize?: false)
  end

  defp get_tenants_to_check(tenant_id) when is_binary(tenant_id) do
    case Ash.get(ServiceRadar.Identity.Tenant, tenant_id, authorize?: false) do
      {:ok, tenant} -> {:ok, [tenant]}
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_tenant_sweep_groups(tenant) do
    tenant_schema = TenantSchemas.schema_for_tenant(tenant.id)
    actor = build_system_actor(tenant.id)

    case get_enabled_sweep_groups(tenant_schema, actor) do
      {:ok, groups} ->
        groups
        |> Enum.map(&check_and_update_group(&1, tenant, tenant_schema, actor))
        |> Enum.count(& &1)

      {:error, reason} ->
        Logger.warning("Failed to get sweep groups for tenant",
          tenant_id: tenant.id,
          reason: inspect(reason)
        )

        0
    end
  end

  defp get_enabled_sweep_groups(tenant_schema, actor) do
    SweepGroup
    |> Ash.Query.for_read(:enabled_groups, %{}, actor: actor, tenant: tenant_schema)
    |> Ash.read(authorize?: false)
  end

  defp check_and_update_group(group, tenant, tenant_schema, actor) do
    # Compute current target list
    targets = compile_target_list(group, tenant_schema, actor)

    # Compute hash of targets
    current_hash = compute_targets_hash(targets)

    # Check if hash changed
    if current_hash != group.target_hash do
      Logger.info("Sweep group target hash changed",
        group_id: group.id,
        group_name: group.name,
        old_hash: group.target_hash,
        new_hash: current_hash,
        target_count: length(targets)
      )

      # Update the hash on the group
      update_group_hash(group, current_hash, tenant_schema, actor)

      # Invalidate the config cache
      invalidate_config_cache(tenant.id, group)

      true
    else
      false
    end
  end

  defp compile_target_list(group, tenant_schema, actor) do
    # Use the SweepCompiler logic to get targets
    # We need to extract just the target compilation part
    criteria = group.target_criteria || %{}
    static_targets = group.static_targets || []

    criteria_targets =
      if map_size(criteria) > 0 do
        get_targets_from_criteria(criteria, tenant_schema, actor)
      else
        []
      end

    (static_targets ++ criteria_targets)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp get_targets_from_criteria(criteria, tenant_schema, actor) do
    alias ServiceRadar.Inventory.Device
    alias ServiceRadar.SweepJobs.TargetCriteria

    {ash_filters, unsupported_criteria} = TargetCriteria.to_ash_filter_with_fallback(criteria)

    query =
      Device
      |> Ash.Query.for_read(:read, %{}, actor: actor, tenant: tenant_schema)
      |> apply_ash_filters(ash_filters)

    case Ash.read(query, authorize?: false) do
      {:ok, devices} ->
        filtered_devices =
          if map_size(unsupported_criteria) > 0 do
            TargetCriteria.filter_devices(devices, unsupported_criteria)
          else
            devices
          end

        filtered_devices
        |> Enum.map(&get_device_ip/1)
        |> Enum.reject(&is_nil/1)

      {:error, reason} ->
        Logger.warning("Failed to load devices for target refresh", reason: inspect(reason))
        []
    end
  end

  defp apply_ash_filters(query, []), do: query

  defp apply_ash_filters(query, filters) when is_list(filters) do
    Ash.Query.filter(query, ^filters)
  end

  defp get_device_ip(device) do
    Map.get(device, :ip) || Map.get(device, "ip")
  end

  defp compute_targets_hash(targets) when is_list(targets) do
    targets
    |> Enum.sort()
    |> Enum.join(",")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  defp update_group_hash(group, hash, tenant_schema, actor) do
    case Ash.update(group, %{hash: hash},
           action: :update_target_hash,
           actor: actor,
           tenant: tenant_schema,
           authorize?: false
         ) do
      {:ok, _updated} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to update target hash",
          group_id: group.id,
          reason: inspect(reason)
        )

        :error
    end
  end

  defp invalidate_config_cache(tenant_id, group) do
    # Publish config invalidation event
    ConfigPublisher.publish_resource_change(
      tenant_id,
      :sweep,
      SweepGroup,
      group.id,
      :target_hash_changed
    )
  end

  defp build_system_actor(tenant_id) do
    %{
      id: "system",
      email: "sweep-config-refresh@serviceradar",
      role: :admin,
      tenant_id: tenant_id
    }
  end
end
