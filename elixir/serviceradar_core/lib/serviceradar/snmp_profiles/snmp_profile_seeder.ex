defmodule ServiceRadar.SNMPProfiles.SNMPProfileSeeder do
  @moduledoc """
  Seeds the default SNMP profile.

  Each instance gets a single default profile with `is_default: true` that is used
  when no explicit targeting profile matches.
  """

  use GenServer

  require Logger
  require Ash.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.SNMPProfiles.SNMPProfile

  @seed_delay_ms 5_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Process.send_after(self(), :seed, @seed_delay_ms)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:seed, state) do
    seed()
    {:noreply, state}
  end

  @spec seed() :: :ok | {:error, term()}
  def seed do
    actor = SystemActor.system(:snmp_profile_seeder)
    opts = [actor: actor]

    ensure_default_profile(opts)
  end

  defp ensure_default_profile(opts) do
    query = Ash.Query.for_read(SNMPProfile, :get_default, %{})

    case Ash.read_one(query, opts) do
      {:ok, nil} ->
        create_default_profile(opts)

      {:ok, profile} ->
        maybe_update_default_target_query(profile, opts)
        Logger.debug("Default SNMP profile already exists")
        :ok

      {:error, reason} ->
        Logger.warning("Failed to check for default SNMP profile: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp create_default_profile(opts) do
    attrs = default_profile_attrs()
    changeset = Ash.Changeset.for_create(SNMPProfile, :create, attrs, opts)

    case Ash.create(changeset) do
      {:ok, _profile} ->
        Logger.info("Created default SNMP profile")
        :ok

      {:error, reason} ->
        Logger.warning("Failed to create default SNMP profile: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp default_profile_attrs do
    %{
      name: "Default SNMP",
      description: "Default SNMP polling profile for discovered devices",
      poll_interval: 60,
      timeout: 5,
      retries: 3,
      target_query: "in:devices",
      is_default: true,
      enabled: true
    }
  end

  defp maybe_update_default_target_query(profile, opts) do
    if profile.target_query in [nil, ""] do
      changeset =
        Ash.Changeset.for_update(profile, :update, %{target_query: "in:devices"}, opts)

      case Ash.update(changeset, opts) do
        {:ok, _profile} ->
          Logger.info("Updated default SNMP profile target_query to in:devices")
          :ok

        {:error, reason} ->
          Logger.warning(
            "Failed to update default SNMP profile target_query: #{inspect(reason)}"
          )

          :ok
      end
    else
      :ok
    end
  end
end
