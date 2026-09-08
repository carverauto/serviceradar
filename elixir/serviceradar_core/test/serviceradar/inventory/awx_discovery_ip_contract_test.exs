defmodule ServiceRadar.Inventory.AwxDiscoveryIpContractTest do
  @moduledoc """
  AWX device-IP recovery is a CROSS-LANGUAGE contract.

  `go/cmd/wasm-plugins/awx` stamps the extracted host address on
  `metadata.awx.<key>` inside `awxHostMetadata`. The Elixir discovery ingestor
  recovers a blank device `ip` from that same key. There is no shared codegen
  for the key name, so this test is the seam.

  The 2026-07-12 metadata minimization renamed the emitted key from `variables`
  (a secret-capable JSON blob) to `ansible_host`. The ingestor kept reading
  `variables`. Nothing failed: Elixir tests used the old payload, Go tests
  asserted the new one, and IP-less AWX devices kept landing. This test reads
  the Go source directly rather than asserting a copied literal, because a copy
  would drift the same way.
  """

  use ExUnit.Case, async: true

  @awx_plugin_path Path.expand(
                     "../../../../../go/cmd/wasm-plugins/awx/main.go",
                     __DIR__
                   )

  @ingestor_path Path.expand(
                   "../../../lib/serviceradar/inventory/device_discovery_ingestor.ex",
                   __DIR__
                 )

  @external_resource @awx_plugin_path
  @external_resource @ingestor_path

  test "the ingestor recovers IP from the AWX metadata key the plugin emits" do
    plugin_src = File.read!(@awx_plugin_path)
    ingestor_src = File.read!(@ingestor_path)

    assert File.exists?(@awx_plugin_path),
           "awx plugin source missing at #{@awx_plugin_path}"

    assert [[_full, metadata_fn]] =
             Regex.scan(
               ~r/(func awxHostMetadata\([\s\S]*?\n\}\n\nfunc hostStatusString)/,
               plugin_src
             )

    assert [[_assign, emitted_key]] =
             Regex.scan(~r/"([a-z_]+)":\s*ansibleHost/, metadata_fn)

    refute metadata_fn =~ ~r/"variables":/,
           "awxHostMetadata must not reintroduce secret-capable variables into discovery metadata"

    awx_lookup_keys =
      ingestor_src
      |> then(&Regex.scan(~r/string_value\(\s*awx\s*,\s*\[([^\]]+)\]/, &1))
      |> Enum.flat_map(fn [_match, keys] -> Regex.scan(~r/"([^"]+)"/, keys) end)
      |> Enum.map(fn [_match, key] -> key end)

    assert emitted_key in awx_lookup_keys,
           """
           go/cmd/wasm-plugins/awx awxHostMetadata emits metadata.awx.#{emitted_key} \
           but DeviceDiscoveryIngestor never reads that key from the awx map \
           (looked up: #{inspect(awx_lookup_keys)}). Nested `variables` JSON does \
           not count: the plugin stopped emitting that blob on 2026-07-12.
           """
  end
end
