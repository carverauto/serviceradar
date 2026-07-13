defmodule ServiceRadar.Plugins.AnomalyAddonProfileSeederTest do
  @moduledoc """
  Regression coverage for the edge anomaly add-on default profile params against
  the add-on package `config_schema`.

  The "Default Edge Anomaly Detection" profile seeds
  `params = %{"metric_feed" => %{"sources" => [...]}}`. That selection is a
  legitimate config for the edge detector, and omitted scalar detector knobs
  intentionally keep the native add-on defaults. The package `config_schema`
  (shipped in the bundle's `config.schema.json` and stored on the imported
  `AddonPackage`) must therefore model both the seeded `metric_feed` object and
  the operator-tunable scalar fields. If a schema edit drops `metric_feed` while
  keeping `additionalProperties: false`, the AddonProfile reconcile worker
  rejects every assignment, freezing reconcile with a recurring "Failed to
  reconcile add-on profile" warning. These tests lock the schema, seeded params,
  and tuning ownership contract together so that regression cannot ship.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Plugins.AnomalyAddonProfileSeeder
  alias ServiceRadar.Plugins.ConfigSchema

  # The exact JSON Schema shipped in the anomaly add-on bundle and stored verbatim
  # as the imported AddonPackage `config_schema` (NativeAddonImporter does not
  # rewrite it), i.e. the schema the reconcile validator actually runs.
  @config_schema_path Path.expand(
                        "../../../../../addons/anomaly-addon/config.schema.json",
                        __DIR__
                      )
  @external_resource @config_schema_path
  @config_schema @config_schema_path |> File.read!() |> Jason.decode!()

  describe "anomaly package config_schema vs seeded profile params" do
    test "schema models metric_feed as an object with a sources string array" do
      metric_feed = get_in(@config_schema, ["properties", "metric_feed"])

      assert is_map(metric_feed),
             "anomaly config_schema must define a `metric_feed` property so the " <>
               "default profile's metric_feed params validate"

      assert metric_feed["type"] == "object"

      sources = get_in(metric_feed, ["properties", "sources"])
      assert sources["type"] == "array"
      assert get_in(sources, ["items", "type"]) == "string"

      # additionalProperties:false stays — the fix widens the schema by ONE
      # allowed property, it does not loosen the whole object.
      assert @config_schema["additionalProperties"] == false
    end

    test "the Default Edge Anomaly Detection profile params validate against the schema" do
      params = AnomalyAddonProfileSeeder.default_params()

      assert params == %{"metric_feed" => %{"sources" => ["sysmon", "snmp"]}}
      refute Map.has_key?(params, "window_size")
      refute Map.has_key?(params, "min_samples")
      refute Map.has_key?(params, "n_sigma")
      refute Map.has_key?(params, "confirm_slots")
      refute Map.has_key?(params, "max_series")
      assert :ok = ConfigSchema.validate_params(@config_schema, params)
    end

    test "sanitized existing params remove the stale 0.1.20 global cusum toggle" do
      # Negative-control input from pre-0.2.0 profile data. The value is
      # deliberately ignored; per-class drift_mode controls CUSUM now.
      params =
        AnomalyAddonProfileSeeder.sanitize_profile_params(%{
          :cusum_enabled => true,
          "metric_feed" => %{"sources" => ["sysmon"]},
          "n_sigma" => 4.0
        })

      refute Map.has_key?(params, "cusum_enabled")
      assert params["metric_feed"] == %{"sources" => ["sysmon"]}
      assert params["n_sigma"] == 4.0
      assert :ok = ConfigSchema.validate_params(@config_schema, params)
    end

    test "schema pins native defaults for omitted scalar detector knobs" do
      assert get_in(@config_schema, ["properties", "window_size", "default"]) == 300
      assert get_in(@config_schema, ["properties", "min_samples", "default"]) == 30
      assert get_in(@config_schema, ["properties", "n_sigma", "default"]) == 3.0
      assert get_in(@config_schema, ["properties", "confirm_slots", "default"]) == 5
      assert get_in(@config_schema, ["properties", "max_series", "default"]) == 50_000

      assert get_in(@config_schema, ["properties", "checkpoint_max_age_secs", "default"]) ==
               21_600
    end

    test "blank detector numeric params normalize to omission before assignment delivery" do
      params =
        ConfigSchema.normalize_params(@config_schema, %{
          "window_size" => "",
          "min_samples" => "",
          "n_sigma" => "",
          "confirm_slots" => "",
          "max_series" => "",
          "min_std_floor" => "",
          "min_cv" => "",
          "checkpoint_max_age_secs" => "",
          "metric_feed" => %{"sources" => ["sysmon", "snmp"]}
        })

      refute Map.has_key?(params, "window_size")
      refute Map.has_key?(params, "min_samples")
      refute Map.has_key?(params, "n_sigma")
      refute Map.has_key?(params, "confirm_slots")
      refute Map.has_key?(params, "max_series")
      refute Map.has_key?(params, "min_std_floor")
      refute Map.has_key?(params, "min_cv")
      refute Map.has_key?(params, "checkpoint_max_age_secs")

      assert params["metric_feed"] == %{"sources" => ["sysmon", "snmp"]}
      assert :ok = ConfigSchema.validate_params(@config_schema, params)
    end

    test "the seeded metric_feed params validate alongside every scalar detector key" do
      params =
        Map.merge(AnomalyAddonProfileSeeder.default_params(), %{
          "n_sigma" => 3.0,
          "max_series" => 50_000,
          "min_samples" => 30,
          "window_size" => 300,
          "confirm_slots" => 5,
          "checkpoint_path" => "/var/lib/serviceradar/anomaly.ckpt",
          "checkpoint_max_age_secs" => 21_600
        })

      assert :ok = ConfigSchema.validate_params(@config_schema, params)
    end

    test "additionalProperties:false still rejects an unmodelled key" do
      params =
        Map.put(AnomalyAddonProfileSeeder.default_params(), "totally_unknown_key", 1)

      assert {:error, errors} = ConfigSchema.validate_params(@config_schema, params)
      assert Enum.any?(errors, &String.contains?(&1, "totally_unknown_key"))
    end

    test "metric_feed.sources only accepts known metric sources" do
      params = %{"metric_feed" => %{"sources" => ["not-a-real-source"]}}

      assert {:error, errors} = ConfigSchema.validate_params(@config_schema, params)
      assert Enum.any?(errors, &String.contains?(&1, "metric_feed"))
    end
  end
end

defmodule ServiceRadar.Plugins.AnomalyAddonProfileSeederDbTest do
  @moduledoc """
  DB-backed coverage for the seed path itself, in particular the
  operator-profile-exists case: seeding creates the default profile enabled,
  so when an operator already runs their own enabled anomaly profile the seeder
  must skip creation (one info line) instead of tripping
  `SingleEnabledAddonProfile` on every boot.
  """

  use ServiceRadar.DataCase, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadar.Plugins.AddonProfile
  alias ServiceRadar.Plugins.AnomalyAddonProfileSeeder

  require Ash.Query
  require Logger

  @moduletag :integration

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
    actor = SystemActor.system(:anomaly_addon_profile_seeder_db_test)
    %{actor: actor}
  end

  test "seeds the enabled default profile when no anomaly profile exists", %{actor: actor} do
    approved_anomaly_package(actor)

    assert :ok = AnomalyAddonProfileSeeder.seed_defaults(actor: actor)
    assert {:ok, %AddonProfile{enabled: true}} = seeded_profile(actor)
  end

  test "skips seeding when an operator-created enabled anomaly profile exists", %{actor: actor} do
    package = approved_anomaly_package(actor)
    {:ok, operator} = create_profile(package, "Operator anomaly profile", true, actor)

    log =
      with_log_level(:info, fn ->
        capture_log([level: :info], fn ->
          assert :ok = AnomalyAddonProfileSeeder.seed_defaults(actor: actor)
        end)
      end)

    assert log =~ "Skipping anomaly add-on default profile seed"
    assert log =~ operator.name
    refute log =~ "Failed to seed anomaly add-on default profile"

    # No seeded duplicate — enabled or disabled — was created.
    assert {:ok, nil} = seeded_profile(actor)
  end

  test "a disabled operator profile does not block seeding", %{actor: actor} do
    package = approved_anomaly_package(actor)
    {:ok, _operator} = create_profile(package, "Disabled operator profile", false, actor)

    assert :ok = AnomalyAddonProfileSeeder.seed_defaults(actor: actor)
    assert {:ok, %AddonProfile{enabled: true}} = seeded_profile(actor)
  end

  defp with_log_level(level, fun) do
    previous = Logger.level()
    Logger.configure(level: level)

    try do
      fun.()
    after
      Logger.configure(level: previous)
    end
  end

  defp seeded_profile(actor) do
    seeded_by = "ServiceRadar.Plugins.AnomalyAddonProfileSeeder"

    AddonProfile
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(addon_id == "anomaly" and metadata["seeded_by"] == ^seeded_by)
    |> Ash.read_one(actor: actor)
  end

  defp approved_anomaly_package(actor) do
    unique = System.unique_integer([:positive])

    {:ok, package} =
      AddonPackage
      |> Ash.Changeset.for_create(
        :create,
        %{
          addon_id: "anomaly",
          version: "0.0.#{unique}",
          name: "anomaly package #{unique}",
          artifacts: %{"linux/amd64" => %{}},
          requires: %{},
          config_schema: %{
            "type" => "object",
            "properties" => %{
              "metric_feed" => %{
                "type" => "object",
                "properties" => %{
                  "sources" => %{"type" => "array", "items" => %{"type" => "string"}}
                }
              }
            }
          }
        },
        actor: actor
      )
      |> Ash.create()

    {:ok, package} =
      package
      |> Ash.Changeset.for_update(
        :approve,
        %{
          approved_capabilities: [],
          approved_by: "system:anomaly_addon_profile_seeder_db_test"
        },
        actor: actor
      )
      |> Ash.update()

    package
  end

  defp create_profile(package, name, enabled, actor) do
    AddonProfile
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: name,
        addon_package_id: package.id,
        target_query: "in:agents",
        enabled: enabled
      },
      actor: actor
    )
    |> Ash.create()
  end
end
