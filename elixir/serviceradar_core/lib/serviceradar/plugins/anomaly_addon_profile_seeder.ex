defmodule ServiceRadar.Plugins.AnomalyAddonProfileSeeder do
  @moduledoc """
  Seeds the default profile for the edge anomaly native add-on.

  The add-on consumes the local metric-feed stream, so the default profile keeps
  targeting broad (`in:agents`) while limiting feed sources to sysmon and SNMP
  in assignment params. That avoids starting analysis for every possible local
  add-on feed and keeps future SRQL targeting improvements independent from the
  source subscription contract.

  Targeting the `agents` entity (rather than `devices`) is deliberate: the
  reconciler materializes profile assignments per enrolled agent, and the
  `agents` projection carries a usable `uid` for every enrolled agent. The
  `devices` projection only carries a denormalized `agent_id` on the subset of
  device rows that happen to have one, so an `in:devices` default silently drops
  every device without an `agent_id` as `no_enrolled_agent`.

  Scalar detector knobs such as `window_size`, `min_samples`, `n_sigma`, and
  `confirm_slots` are intentionally not seeded here. Operators tune those on
  the add-on profile or assignment params; omitted fields keep the
  `anomaly-addon` package schema and native detector defaults.
  """

  use ServiceRadar.DelayedSeeder, callback: :seed_defaults

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadar.Plugins.AddonProfile

  require Ash.Query
  require Logger

  @addon_id "anomaly"
  @profile_name "Default Edge Anomaly Detection"
  @target_query "in:agents"
  @seeded_by "ServiceRadar.Plugins.AnomalyAddonProfileSeeder"
  @default_params %{"metric_feed" => %{"sources" => ["sysmon", "snmp"]}}
  @removed_profile_param_keys ~w(cusum_enabled)

  @doc """
  The default profile params seeded for the edge anomaly add-on.

  Exposed so the add-on package `config_schema` (the source of truth shipped in
  the bundle's `config.schema.json`) can be validated against the exact params
  this seeder writes — guarding against a schema regression that would reject the
  legitimate `metric_feed` selection and freeze reconcile.

  This default pins feed ownership only. It does not freeze detector scalar
  defaults into every seeded profile.
  """
  @spec default_params() :: map()
  def default_params, do: @default_params

  @doc "The add-on id this seeder manages (`\"anomaly\"`)."
  @spec addon_id() :: String.t()
  def addon_id, do: @addon_id

  @doc false
  @spec sanitize_profile_params(map() | term()) :: map()
  def sanitize_profile_params(params) when is_map(params) do
    params
    |> stringify_keys()
    |> Map.drop(@removed_profile_param_keys)
    |> Map.put_new("metric_feed", @default_params["metric_feed"])
  end

  def sanitize_profile_params(_params), do: @default_params

  @spec seed_defaults(keyword()) :: :ok | {:error, term()}
  def seed_defaults(opts \\ []) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:anomaly_addon_profile_seeder))

    with {:ok, package} <- latest_approved_package(actor),
         :ok <- ensure_schema_supports_metric_feed(package),
         {:ok, profile} <- find_seeded_profile(actor),
         :ok <- ensure_no_conflicting_enabled_profile(profile, actor),
         {:ok, _profile} <- upsert_profile(profile, package, actor) do
      :ok
    else
      :no_package ->
        Logger.debug(
          "Skipping anomaly add-on default profile seed; no approved anomaly package imported yet"
        )

        :ok

      :unsupported_schema ->
        Logger.debug(
          "Skipping anomaly add-on default profile seed; package config schema lacks metric_feed"
        )

        :ok

      {:operator_profile_exists, %AddonProfile{} = existing} ->
        Logger.info(
          "Skipping anomaly add-on default profile seed; enabled profile " <>
            "\"#{existing.name}\" (#{existing.id}) already carries the deployment config"
        )

        :ok

      {:error, reason} = error ->
        Logger.warning("Failed to seed anomaly add-on default profile: #{inspect(reason)}")
        error
    end
  end

  defp latest_approved_package(actor) do
    AddonPackage
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(addon_id == @addon_id and status == :approved)
    |> Ash.Query.sort(approved_at: :desc, imported_at: :desc, version: :desc)
    |> Ash.read(actor: actor)
    |> case do
      {:ok, [package | _]} -> {:ok, package}
      {:ok, []} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_schema_supports_metric_feed(nil), do: :no_package

  defp ensure_schema_supports_metric_feed(%AddonPackage{config_schema: schema}) do
    properties = Map.get(schema || %{}, "properties", %{})

    if Map.has_key?(properties, "metric_feed") do
      :ok
    else
      :unsupported_schema
    end
  end

  # Seeding creates the default profile enabled, and SingleEnabledAddonProfile
  # rejects a second enabled anomaly profile. When an operator already runs
  # their own enabled anomaly profile, skip seeding entirely (a disabled
  # duplicate would only confuse operators) instead of failing every boot.
  defp ensure_no_conflicting_enabled_profile(nil, actor) do
    AddonProfile
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(addon_id == @addon_id and enabled == true)
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read(actor: actor)
    |> case do
      {:ok, []} -> :ok
      {:ok, [existing | _]} -> {:operator_profile_exists, existing}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_no_conflicting_enabled_profile(%AddonProfile{}, _actor), do: :ok

  defp find_seeded_profile(actor) do
    AddonProfile
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(addon_id == @addon_id and metadata["seeded_by"] == @seeded_by)
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read_one(actor: actor)
  end

  defp upsert_profile(nil, %AddonPackage{} = package, actor) do
    AddonProfile
    |> Ash.Changeset.for_create(:create, profile_attrs(package), actor: actor)
    |> Ash.create(actor: actor)
  end

  defp upsert_profile(%AddonProfile{} = profile, %AddonPackage{} = package, actor) do
    profile
    |> Ash.Changeset.for_update(:update, update_attrs(profile, package), actor: actor)
    |> Ash.update(actor: actor)
  end

  defp profile_attrs(%AddonPackage{} = package) do
    %{
      name: @profile_name,
      description: "Default edge anomaly profile for agents with local sysmon or SNMP metrics.",
      addon_package_id: package.id,
      target_query: @target_query,
      params: @default_params,
      args: [],
      priority: 100,
      max_targets: 1_000_000,
      metadata: %{
        "seeded_by" => @seeded_by,
        "default_metric_feed_sources" => ["sysmon", "snmp"],
        "targeting_note" =>
          "SRQL does not yet expose a first-class sysmon/SNMP collector predicate; feed sources are gated in assignment params."
      },
      enabled: true
    }
  end

  defp update_attrs(%AddonProfile{} = profile, %AddonPackage{} = package) do
    %{
      addon_package_id: package.id,
      params: sanitize_profile_params(profile.params || %{}),
      metadata:
        Map.merge(profile.metadata || %{}, %{
          "seeded_by" => @seeded_by,
          "default_metric_feed_sources" => ["sysmon", "snmp"]
        })
    }
  end

  defp stringify_keys(params) when is_map(params) do
    Map.new(params, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(values) when is_list(values), do: Enum.map(values, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
