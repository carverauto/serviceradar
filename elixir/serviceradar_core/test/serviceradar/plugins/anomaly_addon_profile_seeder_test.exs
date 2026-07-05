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
