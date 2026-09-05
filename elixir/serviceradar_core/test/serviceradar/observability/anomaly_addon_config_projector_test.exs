defmodule ServiceRadar.Observability.AnomalyAddonConfigProjectorTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.AnomalyAddonConfigProjector
  alias ServiceRadar.Observability.AnomalyDetectionConfig
  alias ServiceRadar.Plugins.ConfigSchema

  @moduletag :requires_app

  test "managed params project settings and filter non-edge metric-class keys" do
    settings = %AnomalyDetectionConfig{
      n_sigma: 4.5,
      window_size: 600,
      confirm_slots: 7,
      min_samples: 45,
      metric_denylist: ["cpu.frequency_hz", " custom.metric ", "custom.metric", ""],
      emission: %{
        "cooldown_secs" => 120,
        "budget_per_tick" => 25,
        "episode_update_interval_secs" => 900,
        "reopen_cooldown_secs" => 300,
        "ignored" => true
      },
      metric_class_overrides: %{
        "interface" => %{
          "drift_mode" => :deseasonalized_only,
          "drift_min_effect" => 2.5,
          "seasonal_n_sigma" => 5.5,
          "minimum_history_points" => 120
        },
        "cpu" => %{"enabled" => true},
        "disk" => %{"warning_threshold_percent" => 80.0}
      }
    }

    managed = AnomalyAddonConfigProjector.managed_params_from_settings(settings)

    assert managed["n_sigma"] == 4.5
    assert managed["window_size"] == 600
    assert managed["confirm_slots"] == 7
    assert managed["min_samples"] == 45
    assert managed["metric_denylist"] == ["cpu.frequency_hz", "custom.metric"]

    assert managed["emission"] == %{
             "cooldown_secs" => 120,
             "budget_per_tick" => 25,
             "episode_update_interval_secs" => 900,
             "reopen_cooldown_secs" => 300
           }

    assert managed["metric_classes"]["interface"] == %{
             "drift_mode" => "deseasonalized_only",
             "drift_min_effect" => 2.5
           }

    assert managed["metric_classes"]["cpu"] == %{"enabled" => true}
    refute Map.has_key?(managed["metric_classes"], "disk")
    assert :ok = ConfigSchema.validate_params(load_addon_schema(), %{"managed" => managed})
  end

  test "reconcile writes managed params without clobbering operator or baseline params" do
    test_pid = self()

    seasonal_baseline = %{
      "centers" => List.duplicate(0.0, 168),
      "scales" => List.duplicate(1.0, 168),
      "sample_counts" => List.duplicate(30, 168)
    }

    settings = %AnomalyDetectionConfig{
      n_sigma: 4.0,
      window_size: 500,
      confirm_slots: 6,
      min_samples: 40,
      metric_denylist: ["cpu.frequency_hz"],
      emission: %{"cooldown_secs" => 300, "budget_per_tick" => 100},
      metric_class_overrides: %{"interface" => %{"drift_mode" => "deseasonalized_only"}}
    }

    profiles = [
      %{
        id: "profile-1",
        params: %{
          "cusum_enabled" => true,
          "metric_feed" => %{"sources" => ["sysmon", "snmp"]},
          "seasonal_baselines" => %{"sr:router-1|ifInOctets|1" => seasonal_baseline},
          "n_sigma" => 9.0,
          "managed" => %{"n_sigma" => 2.0}
        }
      }
    ]

    updater = fn profile, params, _actor ->
      send(test_pid, {:updated, profile.id, params})
      {:ok, Map.put(profile, :params, params)}
    end

    assert {:ok, summary} =
             AnomalyAddonConfigProjector.reconcile(
               settings_fetcher: fn _actor -> {:ok, settings} end,
               profiles_loader: fn _actor -> {:ok, profiles} end,
               profile_updater: updater
             )

    assert summary.profiles_total == 1
    assert summary.profiles_updated == 1
    assert summary.profiles_unchanged == 0

    assert summary.managed_keys ==
             ~w(confirm_slots emission metric_classes metric_denylist min_samples n_sigma window_size)

    assert_received {:updated, "profile-1", params}
    refute Map.has_key?(params, "cusum_enabled")
    assert params["metric_feed"] == %{"sources" => ["sysmon", "snmp"]}
    assert params["seasonal_baselines"] == %{"sr:router-1|ifInOctets|1" => seasonal_baseline}
    assert params["n_sigma"] == 9.0
    assert params["managed"]["n_sigma"] == 4.0
    assert params["managed"]["metric_denylist"] == ["cpu.frequency_hz"]
    assert params["managed"]["emission"] == %{"cooldown_secs" => 300, "budget_per_tick" => 100}
    assert params["managed"]["metric_classes"]["interface"]["drift_mode"] == "deseasonalized_only"
    assert :ok = ConfigSchema.validate_params(load_addon_schema(), params)
  end

  test "reconcile skips unchanged profiles" do
    managed =
      AnomalyAddonConfigProjector.managed_params_from_settings(%AnomalyDetectionConfig{
        n_sigma: 3.0,
        window_size: 300,
        confirm_slots: 5,
        min_samples: 30,
        metric_denylist: ["cpu.frequency_hz"],
        emission: %{"cooldown_secs" => 300},
        metric_class_overrides: %{}
      })

    profiles = [%{id: "profile-1", params: %{"managed" => managed}}]

    assert {:ok, summary} =
             AnomalyAddonConfigProjector.reconcile(
               settings_fetcher: fn _actor ->
                 {:ok,
                  %AnomalyDetectionConfig{
                    n_sigma: 3.0,
                    window_size: 300,
                    confirm_slots: 5,
                    min_samples: 30,
                    metric_denylist: ["cpu.frequency_hz"],
                    emission: %{"cooldown_secs" => 300},
                    metric_class_overrides: %{}
                  }}
               end,
               profiles_loader: fn _actor -> {:ok, profiles} end,
               profile_updater: fn _profile, _params, _actor -> flunk("should not update") end
             )

    assert summary.profiles_updated == 0
    assert summary.profiles_unchanged == 1
  end

  test "reconcile withholds managed keys unknown to the stored package schema" do
    test_pid = self()

    settings = %AnomalyDetectionConfig{
      metric_class_overrides: %{
        "interface" => %{"min_cv" => 0.2, "abs_effect_floor" => 1_000.0}
      }
    }

    schema = %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "managed" => %{
          "type" => "object",
          "additionalProperties" => false,
          "properties" => %{
            "metric_classes" => %{
              "type" => "object",
              "additionalProperties" => %{
                "type" => "object",
                "additionalProperties" => false,
                "properties" => %{"min_cv" => %{"type" => "number"}}
              }
            }
          }
        }
      }
    }

    profiles = [
      %{id: "profile-0.2", params: %{}, addon_package: %{config_schema: schema}}
    ]

    assert {:ok, _summary} =
             AnomalyAddonConfigProjector.reconcile(
               settings_fetcher: fn _actor -> {:ok, settings} end,
               profiles_loader: fn _actor -> {:ok, profiles} end,
               profile_updater: fn _profile, params, _actor ->
                 send(test_pid, {:updated, params})
                 {:ok, %{}}
               end
             )

    assert_received {:updated, params}
    assert params == %{"managed" => %{"metric_classes" => %{"interface" => %{"min_cv" => 0.2}}}}
    assert :ok = ConfigSchema.validate_params(schema, params)
  end

  test "legacy boolean drift_mode values coerce to the string enum" do
    # Rows seeded from unquoted Helm chart defaults (`drift_mode: off` parses
    # as YAML 1.1 boolean false) used to kill the maintenance job with
    # "Expected String but got Boolean" on AddonProfile validation.
    settings = %AnomalyDetectionConfig{
      n_sigma: 3.0,
      window_size: 300,
      confirm_slots: 5,
      min_samples: 30,
      metric_denylist: [],
      emission: %{},
      metric_class_overrides: %{
        "cpu" => %{"drift_mode" => "deseasonalized_only"},
        "disk" => %{"drift_mode" => false},
        "icmp" => %{"drift_mode" => false},
        "other" => %{"drift_mode" => false}
      }
    }

    managed = AnomalyAddonConfigProjector.managed_params_from_settings(settings)

    assert managed["metric_classes"]["disk"] == %{"drift_mode" => "off"}
    assert managed["metric_classes"]["icmp"] == %{"drift_mode" => "off"}
    assert managed["metric_classes"]["other"] == %{"drift_mode" => "off"}
    assert :ok = ConfigSchema.validate_params(load_addon_schema(), %{"managed" => managed})
  end

  test "drift_mode rejects boolean true and passes non-boolean values through" do
    settings = %AnomalyDetectionConfig{
      n_sigma: 3.0,
      window_size: 300,
      confirm_slots: 5,
      min_samples: 30,
      metric_denylist: [],
      emission: %{},
      metric_class_overrides: %{
        "disk" => %{"drift_mode" => true, "drift_min_effect" => 2.0},
        "icmp" => %{"drift_mode" => "bogus"},
        "other" => %{"drift_mode" => 42}
      }
    }

    managed = AnomalyAddonConfigProjector.managed_params_from_settings(settings)

    assert managed["metric_classes"]["disk"] == %{"drift_min_effect" => 2.0}
    assert managed["metric_classes"]["icmp"] == %{"drift_mode" => "bogus"}
    assert managed["metric_classes"]["other"] == %{"drift_mode" => 42}

    assert {:error, _} =
             ConfigSchema.validate_params(load_addon_schema(), %{"managed" => managed})
  end

  defp load_addon_schema do
    path =
      Path.expand("../../../../../addons/anomaly-addon/config.schema.json", __DIR__)

    path
    |> File.read!()
    |> Jason.decode!()
  end
end
