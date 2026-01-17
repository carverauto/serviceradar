defmodule ServiceRadar.SysmonProfiles.SysmonProfileSeeder do
  @moduledoc """
  Seeds the default sysmon profile.

  Each instance gets a single default profile with `is_default: true` that is used
  when no explicit device or tag assignment exists.

  In single-deployment architecture, the DB connection's
  search_path determines which schema the profile is seeded into.
  """

  require Logger
  require Ash.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.SysmonProfiles.SysmonProfile

  @doc """
  Seeds the default sysmon profile for the current instance.

  Can be called during bootstrap or manually to ensure the default profile exists.
  """
  @spec seed() :: :ok | {:error, term()}
  def seed do
    actor = SystemActor.system(:sysmon_profile_seeder)
    opts = [actor: actor]

    ensure_default_profile(opts)
  end

  defp ensure_default_profile(opts) do
    query = Ash.Query.for_read(SysmonProfile, :get_default, %{})

    case Ash.read_one(query, opts) do
      {:ok, nil} ->
        # No default profile exists, create one
        create_default_profile(opts)

      {:ok, _profile} ->
        # Default profile already exists
        Logger.debug("Default sysmon profile already exists")
        :ok

      {:error, reason} ->
        Logger.warning("Failed to check for default sysmon profile: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp create_default_profile(opts) do
    attrs = default_profile_attrs()
    changeset = Ash.Changeset.for_create(SysmonProfile, :create, attrs, opts)

    case Ash.create(changeset) do
      {:ok, _profile} ->
        Logger.info("Created default sysmon profile")
        :ok

      {:error, reason} ->
        Logger.warning("Failed to create default sysmon profile: #{inspect(reason)}")
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
