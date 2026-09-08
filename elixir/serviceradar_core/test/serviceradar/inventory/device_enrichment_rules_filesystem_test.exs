defmodule ServiceRadar.Inventory.DeviceEnrichmentRulesFilesystemTest do
  @moduledoc """
  Filesystem-override behaviour for `DeviceEnrichmentRules`.

  These are the only enrichment-rule tests that mutate global state: they point
  `:device_enrichment_rules_dir` at a temp directory and call `reload/0`, which
  erases the VM-wide `:persistent_term` backing the rule cache. They live apart
  from the pure classification and YAML-validation tests so a mutation that
  escapes its cleanup cannot silently change what those assert -- the failure
  mode this file was split out of was `invalid filesystem rules are skipped`
  observing the *previous* test's `Ubiquiti-Override` rule.
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.Inventory.DeviceEnrichmentRules

  @udm_update %{
    hostname: "farm01",
    source: "mapper",
    metadata: %{
      "sys_object_id" => ".1.3.6.1.4.1.8072.3.2.10",
      "sys_descr" => "Ubiquiti UniFi UDM-Pro 4.4.6 Linux 4.19.152 al324",
      "sys_name" => "farm01",
      "ip_forwarding" => "1"
    }
  }

  setup do
    original_dir = Application.get_env(:serviceradar_core, :device_enrichment_rules_dir)

    restore = fn ->
      if is_nil(original_dir) do
        Application.delete_env(:serviceradar_core, :device_enrichment_rules_dir)
      else
        Application.put_env(:serviceradar_core, :device_enrichment_rules_dir, original_dir)
      end

      DeviceEnrichmentRules.reload()
    end

    restore.()
    on_exit(restore)
  end

  # Points the loader at a temp dir holding `contents`, and guarantees both the
  # directory and the cache are cleaned up even if the test fails.
  defp with_rules_dir(filename, contents) do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "device-enrichment-rules-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    File.write!(Path.join(tmp_dir, filename), contents)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    Application.put_env(:serviceradar_core, :device_enrichment_rules_dir, tmp_dir)
    DeviceEnrichmentRules.reload()

    tmp_dir
  end

  test "filesystem override with same rule id takes precedence over built-in rule" do
    with_rules_dir("override.yaml", """
    rules:
      - id: ubiquiti-router-udm
        enabled: true
        priority: 2000
        confidence: 99
        reason: "test override"
        match:
          all:
            ip_forwarding: [1]
          any:
            sys_name: ["farm01"]
        set:
          vendor_name: "Ubiquiti-Override"
          type: "Router"
          type_id: 12
    """)

    classification = DeviceEnrichmentRules.classify(@udm_update)

    assert classification.vendor_name == "Ubiquiti-Override"
    assert classification.rule_id == "ubiquiti-router-udm"
    assert classification.source == "filesystem"
  end

  test "invalid filesystem rules are skipped and built-in defaults still apply" do
    # No `match:` key, so the rule fails normalisation and is dropped.
    with_rules_dir("invalid.yaml", """
    rules:
      - id: broken-ubiquiti
        enabled: true
        priority: 100
        confidence: 95
        set:
          vendor_name: "Broken"
    """)

    classification = DeviceEnrichmentRules.classify(@udm_update)

    assert classification.vendor_name == "Ubiquiti"
    assert classification.rule_id == "ubiquiti-router-udm"
    assert classification.source == "builtin"
  end
end
