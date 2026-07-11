defmodule ServiceRadar.Plugins.NativeAddonImporterDBTest do
  @moduledoc """
  DB-backed end-to-end coverage of `NativeAddonImporter.import_entry/4`: verify the
  per-arch signatures, mirror (faked), and persist a real staged `AddonPackage`
  whose `artifacts` map `AgentConfigGenerator` reads. Run against the srql-fixtures
  scratch DB (see the srql-fixtures-db-tests skill).
  """
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadar.Plugins.NativeAddonImporter, as: Importer

  @moduletag :integration

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
    actor = %{id: Ash.UUID.generate(), email: "test@serviceradar.local", role: :admin}
    {:ok, actor: actor, uid: :erlang.unique_integer([:positive])}
  end

  defp sign(priv, data), do: :crypto.sign(:eddsa, :none, data, [priv, :ed25519])
  defp sha(data), do: :sha256 |> :crypto.hash(data) |> Base.encode16(case: :lower)

  defp manifest(addon_id, uid) do
    %{
      "id" => addon_id,
      "name" => "Netprobe #{uid}",
      "version" => "0.1.0",
      "kind" => "native",
      "delivery" => "pushed-artifact",
      "supervision" => "systemd-service",
      "capabilities" => ["host-network-visibility"],
      "requires" => %{
        "base_agent" => ">=1.2.0",
        "platforms" => ["linux"],
        "os_capabilities" => ["CAP_NET_RAW", "CAP_NET_ADMIN", "CAP_BPF", "CAP_PERFMON"]
      },
      "exec" => %{
        "binary" => "serviceradar-netprobe",
        "install_path" => "/usr/local/lib/serviceradar/bin"
      }
    }
  end

  test "verifies, mirrors, and persists a staged AddonPackage with the per-arch artifacts map",
       %{actor: actor, uid: uid} do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    addon_id = "netprobe-#{uid}"

    entry = %{
      "addon_id" => addon_id,
      "oci_ref" => "registry.carverauto.dev/serviceradar/serviceradar-addon-netprobe:sha-#{uid}",
      "oci_digest" => "sha256:deadbeef"
    }

    artifacts =
      for arch <- ["amd64", "arm64"] do
        tarball = "tarball-#{arch}-#{uid}"

        %{
          os: "linux",
          arch: arch,
          tarball: tarball,
          sha256: sha(tarball),
          signature: Base.encode16(sign(priv, tarball), case: :lower)
        }
      end

    mirror = fn os, arch, _bytes -> {:ok, "native-addons/#{addon_id}/0.1.0/#{os}-#{arch}/obj"} end

    assert {:ok, package} =
             Importer.import_entry(manifest(addon_id, uid), entry, artifacts,
               public_key: pub,
               mirror: mirror,
               actor: actor,
               release_tag: "sha-#{uid}"
             )

    assert package.status == :staged
    assert package.addon_id == addon_id
    assert package.delivery == :pushed_artifact
    assert package.supervision == :systemd_service
    assert package.binary == "serviceradar-netprobe"

    assert package.artifacts["linux/amd64"]["object_key"] ==
             "native-addons/#{addon_id}/0.1.0/linux-amd64/obj"

    assert package.artifacts["linux/arm64"]["signature"] ==
             Enum.find(artifacts, &(&1.arch == "arm64")).signature

    # Persisted + readable back out of the DB.
    {:ok, reread} = Ash.get(AddonPackage, package.id, actor: actor)
    assert reread.status == :staged
    assert map_size(reread.artifacts) == 2
    assert reread.source_release_tag == "sha-#{uid}"
  end

  test "restages an approved package when replacing its verified artifacts",
       %{actor: actor, uid: uid} do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    addon_id = "netprobe-seeded-#{uid}"

    {:ok, seeded} =
      AddonPackage
      |> Ash.Changeset.for_create(
        :create,
        %{
          addon_id: addon_id,
          version: "0.1.0",
          name: "Seeded placeholder #{uid}",
          delivery: :pushed_artifact,
          supervision: :systemd_service,
          binary: "serviceradar-netprobe",
          capabilities: ["host-network-visibility"],
          artifacts: %{},
          verification_status: "seeded",
          verification_error: "artifact mirror was incomplete"
        },
        actor: actor
      )
      |> Ash.create()

    {:ok, seeded} =
      seeded
      |> Ash.Changeset.for_update(
        :approve,
        %{approved_capabilities: ["host-network-visibility"], approved_by: "test"},
        actor: actor
      )
      |> Ash.update()

    tarball = "tarball-#{uid}"

    artifacts = [
      %{
        os: "linux",
        arch: "amd64",
        tarball: tarball,
        sha256: sha(tarball),
        signature: Base.encode16(sign(priv, tarball), case: :lower)
      }
    ]

    mirror = fn os, arch, _bytes -> {:ok, "native-addons/#{addon_id}/0.1.0/#{os}-#{arch}/obj"} end

    assert {:ok, package} =
             Importer.import_entry(manifest(addon_id, uid), %{"addon_id" => addon_id}, artifacts,
               public_key: pub,
               mirror: mirror,
               actor: actor,
               release_tag: "sha-#{uid}"
             )

    assert package.id == seeded.id
    assert package.status == :staged
    assert package.verification_status == "verified"
    assert is_nil(package.verification_error)
    assert is_nil(package.approved_by)
    assert is_nil(package.approved_at)
    assert package.approved_capabilities == []
    assert package.source_release_tag == "sha-#{uid}"

    assert package.artifacts["linux/amd64"]["object_key"] ==
             "native-addons/#{addon_id}/0.1.0/linux-amd64/obj"
  end

  test "fails closed and persists nothing on a bad per-arch signature", %{actor: actor, uid: uid} do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    addon_id = "netprobe-bad-#{uid}"
    bad = Base.encode16(sign(priv, "something-else"), case: :lower)

    artifacts = [
      %{os: "linux", arch: "amd64", tarball: "real", sha256: sha("real"), signature: bad}
    ]

    assert {:error, :invalid_signature} =
             Importer.import_entry(manifest(addon_id, uid), %{"addon_id" => addon_id}, artifacts,
               public_key: pub,
               mirror: fn _os, _arch, _bytes -> {:ok, "k"} end,
               actor: actor
             )

    assert {:ok, []} =
             AddonPackage
             |> Ash.Query.for_read(:by_addon_id, %{addon_id: addon_id}, actor: actor)
             |> Ash.read()
  end
end
