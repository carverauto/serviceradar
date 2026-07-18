defmodule ServiceRadar.Plugins.NativeAddonImporterTest do
  @moduledoc """
  Pure unit tests for the native add-on importer's verification + mapping core
  (no DB / no registry). The DB-backed `import_entry/4` create path is covered in
  the agent-config generator / DB-backed suite.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Plugins.NativeAddonImporter, as: Importer

  defp keypair do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    {pub, priv}
  end

  defp sign(priv, data), do: :crypto.sign(:eddsa, :none, data, [priv, :ed25519])

  defp signature_digest(signature) do
    "sha256:" <>
      (:sha256 |> :crypto.hash(signature <> "\n") |> Base.encode16(case: :lower))
  end

  describe "verify_artifact_signature/3" do
    test "accepts a valid ed25519 signature (hex and base64) over the bytes" do
      {pub, priv} = keypair()
      data = "per-arch netprobe tarball bytes"
      raw = sign(priv, data)

      assert :ok = Importer.verify_artifact_signature(data, Base.encode16(raw, case: :lower), pub)
      assert :ok = Importer.verify_artifact_signature(data, Base.encode64(raw), pub)
    end

    test "rejects a tampered payload" do
      {pub, priv} = keypair()
      raw = sign(priv, "original")

      assert {:error, :invalid_signature} =
               Importer.verify_artifact_signature("tampered", Base.encode16(raw), pub)
    end

    test "rejects the wrong key" do
      {_pub, priv} = keypair()
      {other_pub, _} = keypair()
      raw = sign(priv, "data")

      assert {:error, :invalid_signature} =
               Importer.verify_artifact_signature("data", Base.encode16(raw), other_pub)
    end

    test "rejects a malformed (non-64-byte) signature" do
      {pub, _priv} = keypair()

      assert {:error, :malformed_signature} =
               Importer.verify_artifact_signature("data", "not-a-signature!!", pub)
    end
  end

  describe "verify_sha256/2" do
    test "matches the expected digest case-insensitively" do
      data = "abc"
      hex = :sha256 |> :crypto.hash(data) |> Base.encode16(case: :lower)
      assert :ok = Importer.verify_sha256(data, hex)
      assert :ok = Importer.verify_sha256(data, String.upcase(hex))
    end

    test "fails on a mismatch" do
      assert {:error, :sha256_mismatch} = Importer.verify_sha256("abc", String.duplicate("0", 64))
    end
  end

  describe "verify_and_mirror/3" do
    test "verifies + mirrors each arch into the os/arch artifacts map" do
      {pub, priv} = keypair()

      artifacts =
        for arch <- ["amd64", "arm64"] do
          tarball = "tarball-#{arch}"
          signature = priv |> sign(tarball) |> Base.encode16(case: :lower)

          %{
            os: "linux",
            arch: arch,
            tarball: tarball,
            sha256: :sha256 |> :crypto.hash(tarball) |> Base.encode16(case: :lower),
            signature: signature,
            signature_digest: signature_digest(signature)
          }
        end

      mirror = fn os, arch, _bytes -> {:ok, "addons/netprobe/#{os}/#{arch}/obj"} end

      assert {:ok, map} = Importer.verify_and_mirror(artifacts, pub, mirror)

      assert %{
               "linux/amd64" => %{"object_key" => "addons/netprobe/linux/amd64/obj"},
               "linux/arm64" => %{"object_key" => "addons/netprobe/linux/arm64/obj"}
             } = map

      assert get_in(map, ["linux/amd64", "signature"]) ==
               Enum.find(artifacts, &(&1.arch == "amd64")).signature

      assert get_in(map, ["linux/amd64", "signature_digest"]) ==
               Enum.find(artifacts, &(&1.arch == "amd64")).signature_digest
    end

    test "rejects a signature whose declared layer digest does not match its canonical bytes" do
      {pub, priv} = keypair()
      tarball = "real"
      signature = priv |> sign(tarball) |> Base.encode16(case: :lower)

      artifact = %{
        os: "linux",
        arch: "amd64",
        tarball: tarball,
        sha256: :sha256 |> :crypto.hash(tarball) |> Base.encode16(case: :lower),
        signature: signature,
        signature_digest: "sha256:" <> String.duplicate("0", 64)
      }

      mirror = fn _os, _arch, _bytes -> flunk("must not mirror mismatched signature metadata") end

      assert {:error, :signature_digest_mismatch} =
               Importer.verify_and_mirror([artifact], pub, mirror)
    end

    test "fails closed on a bad signature and never mirrors it" do
      {pub, priv} = keypair()
      bad = priv |> sign("something-else") |> Base.encode16(case: :lower)

      artifacts = [
        %{
          os: "linux",
          arch: "amd64",
          tarball: "real",
          sha256: :sha256 |> :crypto.hash("real") |> Base.encode16(case: :lower),
          signature: bad
        }
      ]

      mirror = fn _os, _arch, _bytes -> flunk("must not mirror an unverified artifact") end
      assert {:error, :invalid_signature} = Importer.verify_and_mirror(artifacts, pub, mirror)
    end

    test "rejects duplicate normalized platforms before mirroring" do
      {pub, priv} = keypair()
      tarball = "duplicate-platform"
      signature = priv |> sign(tarball) |> Base.encode16(case: :lower)

      artifact = %{
        os: "linux",
        arch: "amd64",
        tarball: tarball,
        sha256: :sha256 |> :crypto.hash(tarball) |> Base.encode16(case: :lower),
        signature: signature,
        signature_digest: signature_digest(signature)
      }

      duplicate = %{artifact | os: " Linux ", arch: "AMD64"}

      mirror = fn _os, _arch, _bytes ->
        flunk("duplicate platforms must fail before mirroring")
      end

      assert {:error, {:duplicate_artifact_platform, "linux/amd64"}} =
               Importer.verify_and_mirror([artifact, duplicate], pub, mirror)
    end

    test "normalizes platform names before mirroring and persistence" do
      {pub, priv} = keypair()
      tarball = "canonical-platform"
      signature = priv |> sign(tarball) |> Base.encode16(case: :lower)

      artifact = %{
        os: " Linux ",
        arch: "AMD64",
        tarball: tarball,
        sha256: :sha256 |> :crypto.hash(tarball) |> Base.encode16(case: :lower),
        signature: signature,
        signature_digest: signature_digest(signature)
      }

      parent = self()

      mirror = fn os, arch, _bytes ->
        send(parent, {:mirrored_platform, os, arch})
        {:ok, "addons/netprobe/#{os}/#{arch}/obj"}
      end

      assert {:ok, map} = Importer.verify_and_mirror([artifact], pub, mirror)
      assert_receive {:mirrored_platform, "linux", "amd64"}

      assert %{
               "linux/amd64" => %{
                 "object_key" => "addons/netprobe/linux/amd64/obj"
               }
             } = map

      refute Map.has_key?(map, " Linux /AMD64")
    end
  end

  test "rejects a bundle manifest identity that differs from the selected index entry" do
    {pub, _priv} = keypair()
    entry = %{"addon_id" => "netprobe", "version" => "0.1.0"}
    mismatched_manifest = Map.put(manifest(), "id", "different-addon")

    assert {:error, {:native_addon_identity_mismatch, mismatch}} =
             Importer.import_entry(mismatched_manifest, entry, [],
               public_key: pub,
               mirror: fn _os, _arch, _bytes ->
                 flunk("identity mismatch must fail before mirroring")
               end,
               actor: %{}
             )

    assert mismatch.entry_addon_id == "netprobe"
    assert mismatch.manifest_addon_id == "different-addon"
  end

  describe "package_attrs/4" do
    defp manifest do
      %{
        "id" => "netprobe",
        "name" => "Host Network Visibility (netprobe)",
        "version" => "0.1.0",
        "kind" => "native",
        "delivery" => "pushed-artifact",
        "supervision" => "systemd-service",
        "capabilities" => ["host-network-visibility"],
        "requires" => %{
          "base_agent" => ">=1.2.0",
          "platforms" => ["linux"],
          "agent_capabilities" => ["host-network-visibility"],
          "os_capabilities" => ["CAP_NET_RAW", "CAP_NET_ADMIN", "CAP_BPF", "CAP_PERFMON"]
        },
        "resources" => %{
          "cpu_max_percent" => 50,
          "memory_max_bytes" => 268_435_456,
          "memory_high_bytes" => 201_326_592,
          "tasks_max" => 32,
          "slice" => "serviceradar-addons.slice"
        },
        "exec" => %{
          "binary" => "serviceradar-netprobe",
          "install_path" => "/usr/local/lib/serviceradar/bin"
        },
        "signal_schemas" => [
          %{
            "id" => "com.carverauto.netprobe.flow",
            "version" => "1.0.0",
            "signal_type" => "event",
            "payload_kind" => "ocsf_event",
            "payload_schema" => "schemas/flow.schema.json",
            "display_contract" => "display/flow.display.json",
            "display_contract_id" => "com.carverauto.netprobe.flow.display",
            "display_contract_version" => "1.0.0"
          }
        ]
      }
    end

    test "maps the manifest + index entry into create attrs (enum atoms, source refs)" do
      entry = %{
        "addon_id" => "netprobe",
        "version" => "0.1.0",
        "oci_ref" => "registry.carverauto.dev/serviceradar/serviceradar-addon-netprobe:sha-abc",
        "oci_digest" => "sha256:deadbeef",
        "bundle_digest" => "sha256:#{String.duplicate("a", 64)}"
      }

      artifacts = %{
        "linux/amd64" => %{"object_key" => "k", "sha256" => "s", "signature" => "sig"}
      }

      assert {:ok, attrs} =
               Importer.package_attrs(manifest(), entry, artifacts, release_tag: "sha-abc")

      assert attrs.addon_id == "netprobe"
      assert attrs.version == "0.1.0"
      assert attrs.kind == :native
      assert attrs.delivery == :pushed_artifact
      assert attrs.supervision == :systemd_service
      assert attrs.binary == "serviceradar-netprobe"
      assert attrs.install_path == "/usr/local/lib/serviceradar/bin"
      assert attrs.capabilities == ["host-network-visibility"]
      assert [signal_schema] = attrs.signal_schemas
      assert signal_schema["id"] == "com.carverauto.netprobe.flow"
      assert signal_schema["display_contract"] == "display/flow.display.json"
      assert attrs.artifacts == artifacts
      assert attrs.requires["agent_capabilities"] == ["host-network-visibility"]

      assert attrs.requires["os_capabilities"] == [
               "CAP_NET_RAW",
               "CAP_NET_ADMIN",
               "CAP_BPF",
               "CAP_PERFMON"
             ]

      assert attrs.resources["cpu_max_percent"] == 50
      assert attrs.resources["memory_max_bytes"] == 268_435_456
      assert attrs.resources["slice"] == "serviceradar-addons.slice"

      assert attrs.source_oci_ref =~ "serviceradar-addon-netprobe"
      assert attrs.source_oci_digest == "sha256:deadbeef"
      assert attrs.source_metadata == %{"bundle_digest" => "sha256:#{String.duplicate("a", 64)}"}
      assert attrs.source_release_tag == "sha-abc"
      assert attrs.source_type == :first_party
      assert attrs.verification_status == "verified"
      assert is_nil(attrs.verification_error)
    end

    test "defaults resources to an empty map when the manifest omits it" do
      m = Map.delete(manifest(), "resources")
      assert {:ok, attrs} = Importer.package_attrs(m, %{}, %{})
      assert attrs.resources == %{}
    end

    test "fails closed on an unknown delivery model" do
      bad = Map.put(manifest(), "delivery", "carrier-pigeon")

      assert {:error, {:invalid_enum, :delivery, "carrier-pigeon"}} =
               Importer.package_attrs(bad, %{}, %{})
    end

    test "defaults install_path when the manifest omits it" do
      m = Map.put(manifest(), "exec", %{"binary" => "x"})
      assert {:ok, attrs} = Importer.package_attrs(m, %{}, %{})
      assert attrs.install_path == "/usr/local/lib/serviceradar/bin"
    end
  end
end
