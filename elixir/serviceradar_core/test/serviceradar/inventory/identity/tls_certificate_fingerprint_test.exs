defmodule ServiceRadar.Inventory.Identity.TlsCertificateFingerprintTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.AgentGatewaySync
  alias ServiceRadar.Inventory.Identity.Ids

  @hex String.duplicate("0f1e2d3c", 8)
  @fingerprint "pve:sha256:" <> @hex

  defp update(source, value) do
    %{source: source, metadata: %{"tls_certificate_fingerprint" => value}}
  end

  test "the Proxmox inventory and the agent claim a node certificate fingerprint" do
    # The PVE API reports the fingerprint as colon-separated uppercase hex.
    api_form =
      "pve:sha256:" <>
        (@hex
         |> String.upcase()
         |> String.graphemes()
         |> Enum.chunk_every(2)
         |> Enum.map_join(":", &Enum.join/1))

    for source <- ["proxmox", "hypervisor_enrichment", "agent_gateway_sync"],
        value <- [@fingerprint, api_form] do
      ids = Ids.extract_strong_identifiers(update(source, value))

      assert ids.tls_certificate_fingerprint == @fingerprint
      assert Ids.has_strong_identifier?(ids)
    end
  end

  # An observer can carry a certificate it was served (a mapper probing port 8006), and a shared
  # or wildcard certificate is served by many hosts.
  test "an observer's certificate is never identity" do
    for source <- ["mapper", "sweep", "netprobe-census", "armis", nil] do
      ids = Ids.extract_strong_identifiers(update(source, @fingerprint))

      assert ids.tls_certificate_fingerprint == nil
      refute Ids.has_strong_identifier?(ids)
    end
  end

  test "a value that is not a scoped SHA-256 digest is not identity" do
    for value <- [
          @hex,
          "pve:sha256:" <> String.slice(@hex, 1..-1//1),
          "pve:sha256:" <> String.duplicate("zz", 32),
          "pve:sha1:" <> @hex,
          "",
          nil
        ] do
      assert Ids.extract_strong_identifiers(update("proxmox", value)).tls_certificate_fingerprint ==
               nil
    end
  end

  test "an agent reports its node certificate from the local pveproxy port only" do
    for {fingerprints, expected} <- [
          {[%{port: 8006, sha256: @hex}], @fingerprint},
          {[%{"port" => 8006, "sha256" => String.upcase(@hex)}], @fingerprint},
          {[%{port: 443, sha256: @hex}], nil},
          {[%{port: 8006, sha256: "not-a-digest"}], nil},
          {[], nil}
        ] do
      ids =
        "agent-certificate"
        |> AgentGatewaySync.build_device_update_from_agent(%{host_tls_fingerprints: fingerprints})
        |> Ids.extract_strong_identifiers()

      assert ids.tls_certificate_fingerprint == expected
      assert ids.agent_id == "agent-certificate"
    end
  end
end
