defmodule ServiceRadar.SysmonProfiles.SysmonProfileSeeder do
  @moduledoc """
  Seeds default sysmon profile for each tenant.

  Each tenant gets a single default profile with `is_default: true` that is used
  when no explicit device or tag assignment exists.
  """

  require Logger
  require Ash.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.Tenant
  alias ServiceRadar.SysmonProfiles.SysmonProfile

  @doc """
  Seeds the default sysmon profile for a tenant.

  Called during tenant creation via InitializeTenantInfrastructure.
  """
  @spec seed_for_tenant(Tenant.t()) :: :ok | {:error, term()}
  def seed_for_tenant(%Tenant{} = tenant) do
    # DB connection's search_path determines the schema
    actor = SystemActor.system(:sysmon_profile_seeder)
    opts = [actor: actor]

    ensure_default_profile(opts, tenant.slug)
  end

  defp ensure_default_profile(opts, tenant_slug) do
    query = Ash.Query.for_read(SysmonProfile, :get_default, %{})

    case Ash.read_one(query, opts) do
      {:ok, nil} ->
        # No default profile exists, create one
        create_default_profile(opts, tenant_slug)

      {:ok, _profile} ->
        # Default profile already exists
        Logger.debug("Default sysmon profile already exists for tenant: #{tenant_slug}")
        :ok

      {:error, reason} ->
        Logger.warning(
          "Failed to check for default sysmon profile for #{tenant_slug}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp create_default_profile(opts, tenant_slug) do
    attrs = default_profile_attrs()
    changeset = Ash.Changeset.for_create(SysmonProfile, :create, attrs, opts)

    case Ash.create(changeset) do
      {:ok, profile} ->
        Logger.info("Created default sysmon profile for tenant: #{tenant_slug}")
        {:ok, profile}

      {:error, reason} ->
        Logger.warning(
          "Failed to create default sysmon profile for #{tenant_slug}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp default_profile_attrs do
    %{
      name: "Default",
      description: "Default system monitoring profile for all devices",
      sample_interval: "10s",
      collect_cpu: true,
      collect_memory: true,
      collect_disk: true,
      collect_network: false,
      collect_processes: false,
      disk_paths: [],
      disk_exclude_paths: [],
      thresholds: %{
        "cpu_warning" => "80",
        "cpu_critical" => "95",
        "memory_warning" => "85",
        "memory_critical" => "95",
        "disk_warning" => "80",
        "disk_critical" => "95"
      },
      is_default: true,
      enabled: true
    }
  end
end
