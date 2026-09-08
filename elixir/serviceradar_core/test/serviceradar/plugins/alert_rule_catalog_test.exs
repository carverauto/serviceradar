defmodule ServiceRadar.Plugins.AlertRuleCatalogTest do
  @moduledoc """
  A plugin proposes alert rules; it never activates them.

  The properties asserted here are the ones whose absence would be dangerous
  rather than merely wrong: a manifest that could arm its own rule would page
  people on plugin import, and a re-sync that overwrote operator tuning would
  silently undo a threshold someone chose deliberately.

  None of this needs a database.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Plugins.Manifest

  # A MINIMAL VALID manifest, so the only errors a test sees are the ones it is
  # actually about. With an invalid base the error assertions below would pass
  # on unrelated failures -- a false pass, and the reason this fixture is
  # complete rather than sketched.
  defp manifest_map(alert_rules) do
    %{
      "id" => "aruba-controller-fabric",
      "name" => "Aruba Controller Fabric",
      "version" => "0.1.0",
      "entrypoint" => "run_check",
      "runtime" => "wasi-preview1",
      "outputs" => "serviceradar.plugin_result.v1",
      "capabilities" => ["get_config", "log", "submit_result"],
      "resources" => %{"requested_memory_mb" => 64, "requested_cpu_ms" => 500},
      "alert_rules" => alert_rules
    }
  end

  defp valid_rule(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "controller-down",
        "signal" => "metric",
        "match" => %{"metric_name" => "aruba.device.up"},
        "group_by" => ["hostname"]
      },
      overrides
    )
  end

  describe "manifest parsing" do
    test "accepts a well-formed alert rule" do
      assert {:ok, manifest} = Manifest.from_map(manifest_map([valid_rule()]))
      assert [%{"name" => "controller-down"}] = manifest.alert_rules
    end

    test "a manifest with no alert_rules is unchanged" do
      assert {:ok, manifest} = Manifest.from_map(Map.delete(manifest_map([]), "alert_rules"))
      assert manifest.alert_rules == []
    end

    # THE security property. If `enabled` were accepted, importing a plugin
    # could arm a rule that pages people, with no human in the loop.
    test "enabled is not an accepted key, so a manifest cannot arm its own rule" do
      assert {:error, errors} =
               Manifest.from_map(manifest_map([valid_rule(%{"enabled" => true})]))

      assert Enum.any?(errors, &String.contains?(&1, "enabled is not allowed"))
    end

    test "priority is not accepted either" do
      assert {:error, errors} =
               Manifest.from_map(manifest_map([valid_rule(%{"priority" => 1})]))

      assert Enum.any?(errors, &String.contains?(&1, "priority is not allowed"))
    end

    # An empty match matches EVERY record on the signal, so it would fire on the
    # first metric that arrived. Rejected rather than accepted-and-disabled,
    # because someone would eventually enable it.
    test "an empty match is rejected" do
      for empty <- [%{}, nil] do
        assert {:error, errors} =
                 Manifest.from_map(manifest_map([valid_rule(%{"match" => empty})]))

        assert Enum.any?(errors, &String.contains?(&1, "match must be a non-empty map"))
      end
    end

    test "a nameless rule is rejected" do
      assert {:error, errors} = Manifest.from_map(manifest_map([valid_rule(%{"name" => ""})]))
      assert Enum.any?(errors, &String.contains?(&1, "name must be a non-empty string"))
    end

    test "an unknown signal is rejected" do
      assert {:error, errors} =
               Manifest.from_map(manifest_map([valid_rule(%{"signal" => "telepathy"})]))

      assert Enum.any?(errors, &String.contains?(&1, "signal must be one of"))
    end

    test "an empty group_by is rejected" do
      assert {:error, errors} =
               Manifest.from_map(manifest_map([valid_rule(%{"group_by" => []})]))

      assert Enum.any?(errors, &String.contains?(&1, "group_by must be a non-empty list"))
    end

    # A typo'd key inside the block is caught. Note the LIMIT: unknown
    # TOP-LEVEL manifest keys are still silently discarded by from_map/1, so
    # `alert_rule:` (singular) would be dropped with no error. That is a
    # pre-existing gap, called out in the PR rather than fixed here, because
    # tightening it would reject manifests that validate today.
    test "an unknown key inside a rule is rejected" do
      assert {:error, errors} =
               Manifest.from_map(manifest_map([valid_rule(%{"treshold" => 5})]))

      assert Enum.any?(errors, &String.contains?(&1, "treshold is not allowed"))
    end

    test "alert_rules must be a list" do
      assert {:error, errors} = Manifest.from_map(manifest_map(%{"name" => "x"}))
      assert Enum.any?(errors, &String.contains?(&1, "alert_rules must be a list"))
    end
  end

  describe "the catalog's field ownership" do
    @catalog "lib/serviceradar/plugins/alert_rule_catalog.ex"

    test "rules are created disabled" do
      assert File.read!(@catalog) =~ "enabled: false"
    end

    # A plugin upgrade must not re-arm a rule an operator switched off, nor undo
    # a threshold they tuned. The update branch takes only the definition.
    test "re-sync cannot touch the operator's fields" do
      source = File.read!(@catalog)

      [definition] = Regex.run(~r/@definition_fields \[(.*?)\]/s, source, capture: :all_but_first)

      for operator_field <- ~w(enabled threshold window_seconds bucket_seconds
                               cooldown_seconds renotify_seconds priority) do
        refute definition =~ ":#{operator_field}",
               "#{operator_field} is operator-owned and must not be re-synced from the manifest"
      end
    end

    # RuleSeeder keys the whole rule table by name and adopts unmanaged rows
    # matching its built-in default names. Namespacing makes that collision
    # impossible rather than unlikely.
    test "package rule names are namespaced away from core's seeded defaults" do
      source = File.read!(@catalog)
      assert source =~ ~s|"plugin:\#{package.name}:\#{name}"|

      seeder = File.read!("lib/serviceradar/observability/rule_seeder.ex")

      for default <- ~w(sweep_device_unavailable falco_critical_incident) do
        assert seeder =~ default, "expected #{default} to still be a seeded default"
        refute String.contains?(default, "plugin:")
      end
    end
  end
end
