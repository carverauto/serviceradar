defmodule ServiceRadar.Observability.AnomalyDriftModeBackfillMigrationDbTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Repo
  alias ServiceRadar.Repo.Migrations.BackfillAnomalyDriftModeDefaults, as: Migration

  @migration_path Path.expand(
                    "../../../priv/repo/migrations/20260914120000_backfill_anomaly_drift_mode_defaults.exs",
                    __DIR__
                  )
  @external_resource @migration_path

  Code.require_file(@migration_path)

  # The settings row is seeded once and never rewritten by later chart defaults, so
  # a deployment first seeded before per-class drift_mode existed kept running
  # interfaces in the frozen-anchor drift mode. The backfill fills in only what is
  # missing and must leave every operator choice exactly as it was.

  setup do
    Repo.query!("""
    CREATE TEMP TABLE migration_anomaly_detection_configs (
      key text PRIMARY KEY,
      metric_class_overrides jsonb NOT NULL,
      updated_at timestamp NOT NULL
    ) ON COMMIT DROP
    """)

    :ok
  end

  test "fills drift_mode for classes that have none, keeping their other keys" do
    insert_row(%{
      "cpu" => %{},
      "memory" => %{},
      "disk" => %{},
      "red" => %{},
      "interface" => %{"min_cv" => 0.5, "min_std_floor" => 30.0}
    })

    assert run_backfill() == 1

    overrides = read_overrides()

    assert overrides["cpu"] == %{"drift_mode" => "deseasonalized_only"}
    assert overrides["memory"] == %{"drift_mode" => "deseasonalized_only"}
    assert overrides["disk"] == %{"drift_mode" => "off"}

    assert overrides["interface"] == %{
             "min_cv" => 0.5,
             "min_std_floor" => 30.0,
             "drift_mode" => "deseasonalized_only"
           }

    # Classes the row never had are added with only their drift_mode.
    assert overrides["icmp"] == %{"drift_mode" => "off"}
    assert overrides["other"] == %{"drift_mode" => "off"}
    # red has no drift_mode default, so it is left as it was.
    assert overrides["red"] == %{}
  end

  test "never changes a drift_mode an operator set" do
    insert_row(%{
      "cpu" => %{"drift_mode" => "off"},
      "interface" => %{"drift_mode" => "always", "min_cv" => 0.2}
    })

    run_backfill()

    overrides = read_overrides()
    assert overrides["cpu"] == %{"drift_mode" => "off"}
    assert overrides["interface"] == %{"drift_mode" => "always", "min_cv" => 0.2}
    assert overrides["memory"] == %{"drift_mode" => "deseasonalized_only"}
  end

  test "leaves a class entry that is not an object untouched" do
    insert_row(%{"cpu" => "legacy", "disk" => nil})

    run_backfill()

    overrides = read_overrides()
    assert overrides["cpu"] == "legacy"
    assert Map.has_key?(overrides, "disk") and is_nil(overrides["disk"])
    assert overrides["memory"] == %{"drift_mode" => "deseasonalized_only"}
  end

  test "is a no-op on a row that already has every default" do
    complete = %{
      "cpu" => %{"drift_mode" => "deseasonalized_only"},
      "memory" => %{"drift_mode" => "deseasonalized_only"},
      "interface" => %{"drift_mode" => "deseasonalized_only"},
      "disk" => %{"drift_mode" => "off"},
      "icmp" => %{"drift_mode" => "off"},
      "other" => %{"drift_mode" => "off"},
      "red" => %{}
    }

    insert_row(complete)

    assert run_backfill() == 0
    assert read_overrides() == complete
  end

  defp insert_row(overrides) do
    Repo.query!(
      """
      INSERT INTO migration_anomaly_detection_configs (key, metric_class_overrides, updated_at)
      VALUES ('default', $1::jsonb, '2026-07-16 05:39:57')
      """,
      [overrides]
    )
  end

  defp run_backfill do
    sql =
      String.replace(
        Migration.backfill_sql(),
        "platform.anomaly_detection_configs",
        "migration_anomaly_detection_configs"
      )

    %Postgrex.Result{num_rows: num_rows} = Repo.query!(sql)
    num_rows
  end

  defp read_overrides do
    %Postgrex.Result{rows: [[overrides]]} =
      Repo.query!(
        "SELECT metric_class_overrides FROM migration_anomaly_detection_configs WHERE key = 'default'"
      )

    overrides
  end
end
