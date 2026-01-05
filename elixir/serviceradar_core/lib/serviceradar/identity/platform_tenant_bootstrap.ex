defmodule ServiceRadar.Identity.PlatformTenantBootstrap do
  @moduledoc """
  Ensures a valid platform tenant exists and records its UUID for platform services.
  """

  use GenServer

  require Logger
  require Ash.Query

  alias ServiceRadar.Identity.Tenant

  @zero_uuid "00000000-0000-0000-0000-000000000000"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    if repo_enabled?() do
      ensure_platform_tenant!()
    else
      Logger.debug("[PlatformTenantBootstrap] Repo disabled; skipping")
    end

    {:ok, %{}}
  end

  defp ensure_platform_tenant! do
    platform_slug = platform_tenant_slug()

    query =
      Tenant
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(is_platform_tenant == true)
      |> Ash.Query.select([:id, :slug, :is_platform_tenant])

    case Ash.read(query, authorize?: false) do
      {:ok, []} ->
        tenant = create_platform_tenant!(platform_slug)
        set_platform_tenant_id!(tenant.id, platform_slug)
        :ok

      {:ok, [tenant]} ->
        validate_platform_tenant!(tenant, platform_slug)
        set_platform_tenant_id!(tenant.id, platform_slug)
        :ok

      {:ok, tenants} ->
        Logger.error("[PlatformTenantBootstrap] Multiple platform tenants detected: #{length(tenants)}")
        raise "multiple platform tenants detected"

      {:error, reason} ->
        Logger.error("[PlatformTenantBootstrap] Failed to load platform tenant: #{inspect(reason)}")
        raise "failed to load platform tenant"
    end
  end

  defp create_platform_tenant!(platform_slug) do
    changeset =
      Tenant
      |> Ash.Changeset.for_create(:create, %{name: "Platform", slug: platform_slug},
        authorize?: false
      )
      |> Ash.Changeset.force_change_attribute(:is_platform_tenant, true)

    case Ash.create(changeset, authorize?: false) do
      {:ok, tenant} ->
        validate_platform_tenant!(tenant, platform_slug)
        tenant

      {:error, reason} ->
        Logger.error("[PlatformTenantBootstrap] Failed to create platform tenant: #{inspect(reason)}")
        raise "failed to create platform tenant"
    end
  end

  defp validate_platform_tenant!(tenant, platform_slug) do
    tenant_id = to_string(tenant.id)
    tenant_slug = to_string(tenant.slug)

    if tenant_id == @zero_uuid do
      Logger.error("[PlatformTenantBootstrap] Platform tenant UUID must not be the zero UUID")
      raise "invalid platform tenant id"
    end

    if tenant_slug != platform_slug do
      Logger.error(
        "[PlatformTenantBootstrap] Platform tenant slug mismatch: expected=#{platform_slug} actual=#{tenant_slug}"
      )

      raise "platform tenant slug mismatch"
    end

    :ok
  end

  defp set_platform_tenant_id!(tenant_id, tenant_slug) do
    Application.put_env(:serviceradar_core, :platform_tenant_id, tenant_id)

    Logger.info(
      "[PlatformTenantBootstrap] Platform tenant resolved: #{tenant_slug} (#{tenant_id})"
    )
  end

  defp platform_tenant_slug do
    Application.get_env(:serviceradar_core, :platform_tenant_slug, "platform")
  end

  defp repo_enabled? do
    Application.get_env(:serviceradar_core, :repo_enabled, true) &&
      Process.whereis(ServiceRadar.Repo)
  end

end
