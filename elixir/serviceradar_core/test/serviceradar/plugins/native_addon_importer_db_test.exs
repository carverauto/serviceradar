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
  @moduletag sandbox: :unboxed

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

  defp signature_digest(signature) do
    "sha256:" <>
      (:sha256 |> :crypto.hash(signature <> "\n") |> Base.encode16(case: :lower))
  end

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

  defp entry(addon_id, uid, overrides \\ %{}) do
    Map.merge(
      %{
        "addon_id" => addon_id,
        "version" => "0.1.0",
        "oci_ref" => "registry.carverauto.dev/serviceradar/#{addon_id}:sha-#{uid}",
        "oci_digest" => "sha256:#{String.pad_leading(Integer.to_string(uid, 16), 64, "0")}",
        "bundle_digest" => "sha256:#{String.pad_leading(Integer.to_string(uid + 1, 16), 64, "0")}"
      },
      overrides
    )
  end

  defp signed_artifacts(priv, uid) do
    tarball = "tarball-#{uid}"
    signature = Base.encode16(sign(priv, tarball), case: :lower)

    [
      %{
        os: "linux",
        arch: "amd64",
        tarball: tarball,
        sha256: sha(tarball),
        signature: signature,
        signature_digest: signature_digest(signature)
      }
    ]
  end

  defp mirror(addon_id) do
    fn os, arch, _bytes ->
      {:ok, "native-addons/#{addon_id}/0.1.0/#{os}-#{arch}/obj"}
    end
  end

  defp import_package(addon_id, uid, actor, pub, priv, entry_overrides \\ %{}, opts \\ []) do
    Importer.import_entry(
      manifest(addon_id, uid),
      entry(addon_id, uid, entry_overrides),
      signed_artifacts(priv, uid),
      [public_key: pub, mirror: mirror(addon_id), actor: actor, release_tag: "sha-#{uid}"] ++ opts
    )
  end

  test "verifies, mirrors, and persists a staged AddonPackage with the per-arch artifacts map",
       %{actor: actor, uid: uid} do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    addon_id = "netprobe-#{uid}"

    entry = %{
      "addon_id" => addon_id,
      "version" => "0.1.0",
      "oci_ref" => "registry.carverauto.dev/serviceradar/serviceradar-addon-netprobe:sha-#{uid}",
      "oci_digest" => "sha256:deadbeef"
    }

    artifacts =
      for arch <- ["amd64", "arm64"] do
        tarball = "tarball-#{arch}-#{uid}"
        signature = Base.encode16(sign(priv, tarball), case: :lower)

        %{
          os: "linux",
          arch: arch,
          tarball: tarball,
          sha256: sha(tarball),
          signature: signature,
          signature_digest: signature_digest(signature)
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

    assert package.artifacts["linux/arm64"]["signature_digest"] ==
             Enum.find(artifacts, &(&1.arch == "arm64")).signature_digest

    # Persisted + readable back out of the DB.
    {:ok, reread} = Ash.get(AddonPackage, package.id, actor: actor)
    assert reread.status == :staged
    assert map_size(reread.artifacts) == 2
    assert reread.source_release_tag == "sha-#{uid}"
    assert reread.source_metadata["bundle_digest"] == entry["bundle_digest"]
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
    signature = Base.encode16(sign(priv, tarball), case: :lower)

    artifacts = [
      %{
        os: "linux",
        arch: "amd64",
        tarball: tarball,
        sha256: sha(tarball),
        signature: signature,
        signature_digest: signature_digest(signature)
      }
    ]

    mirror = fn os, arch, _bytes -> {:ok, "native-addons/#{addon_id}/0.1.0/#{os}-#{arch}/obj"} end

    assert {:ok, package} =
             Importer.import_entry(
               manifest(addon_id, uid),
               %{"addon_id" => addon_id, "version" => "0.1.0"},
               artifacts,
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
             Importer.import_entry(
               manifest(addon_id, uid),
               %{"addon_id" => addon_id, "version" => "0.1.0"},
               artifacts,
               public_key: pub,
               mirror: fn _os, _arch, _bytes -> {:ok, "k"} end,
               actor: actor
             )

    assert {:ok, []} =
             AddonPackage
             |> Ash.Query.for_read(:by_addon_id, %{addon_id: addon_id}, actor: actor)
             |> Ash.read()
  end

  test "never overwrites an upload-owned addon version even when its OCI fields are nil", %{
    actor: actor,
    uid: uid
  } do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    addon_id = "upload-owned-#{uid}"

    {:ok, owned} =
      AddonPackage
      |> Ash.Changeset.for_create(
        :create,
        %{
          addon_id: addon_id,
          version: "0.1.0",
          name: "Uploaded package #{uid}",
          source_type: :upload,
          source_oci_ref: nil,
          source_oci_digest: nil,
          artifacts: %{},
          verification_status: "verified"
        },
        actor: actor
      )
      |> Ash.create()

    assert {:error,
            {:native_addon_version_source_conflict,
             %{reason: :source_type_owned, existing_source_type: :upload}}} =
             import_package(addon_id, uid, actor, pub, priv)

    {:ok, persisted} = Ash.get(AddonPackage, owned.id, actor: actor)
    assert persisted.source_type == :upload
    assert persisted.artifacts == %{}
    assert persisted.name == "Uploaded package #{uid}"
  end

  test "a stale reimport cannot overwrite an approval", %{actor: actor, uid: uid} do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    addon_id = "approve-race-#{uid}"
    {:ok, package} = import_package(addon_id, uid, actor, pub, priv)

    replacement = %{
      artifacts: %{
        "linux/amd64" => %{
          "object_key" => "replacement/#{uid}",
          "sha256" => String.duplicate("f", 64),
          "signature" => "replacement"
        }
      }
    }

    stale_reimport =
      Ash.Changeset.for_update(package, :reimport, replacement, actor: actor)

    assert {:ok, approved} =
             package
             |> Ash.Changeset.for_update(
               :approve,
               %{approved_capabilities: package.capabilities, approved_by: "race-test"},
               actor: actor
             )
             |> Ash.update()

    assert approved.status == :approved
    assert {:error, _reason} = Ash.update(stale_reimport)

    {:ok, persisted} = Ash.get(AddonPackage, package.id, actor: actor)
    assert persisted.status == :approved
    assert persisted.artifacts == package.artifacts
  end

  test "a stale approval cannot approve artifacts replaced by a reimport", %{
    actor: actor,
    uid: uid
  } do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    addon_id = "reimport-race-#{uid}"
    {:ok, package} = import_package(addon_id, uid, actor, pub, priv)

    stale_approve =
      Ash.Changeset.for_update(
        package,
        :approve,
        %{approved_capabilities: package.capabilities, approved_by: "stale-review"},
        actor: actor
      )

    replacement = %{
      "linux/amd64" => %{
        "object_key" => "replacement/#{uid}",
        "sha256" => String.duplicate("e", 64),
        "signature" => "replacement"
      }
    }

    assert {:ok, reimported} =
             package
             |> Ash.Changeset.for_update(:reimport, %{artifacts: replacement}, actor: actor)
             |> Ash.update()

    assert reimported.status == :staged
    assert reimported.artifacts == replacement
    assert {:error, _reason} = Ash.update(stale_approve)

    {:ok, persisted} = Ash.get(AddonPackage, package.id, actor: actor)
    assert persisted.status == :staged
    assert persisted.artifacts == replacement
    assert is_nil(persisted.approved_by)
  end

  test "repairs missing immutable source metadata and then reuses the converged row", %{
    actor: actor,
    uid: uid
  } do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    addon_id = "missing-source-metadata-#{uid}"
    source_entry = entry(addon_id, uid)
    artifacts = signed_artifacts(priv, uid)

    assert {:ok, package, :created} =
             Importer.import_entry_with_disposition(
               manifest(addon_id, uid),
               source_entry,
               artifacts,
               public_key: pub,
               mirror: mirror(addon_id),
               actor: actor,
               release_tag: "sha-#{uid}"
             )

    assert {:ok, approved} =
             package
             |> Ash.Changeset.for_update(
               :approve,
               %{approved_capabilities: package.capabilities, approved_by: "source-review"},
               actor: actor
             )
             |> Ash.update()

    assert {:ok, missing_source} =
             approved
             |> Ash.Changeset.for_update(
               :update,
               %{source_oci_ref: nil, source_oci_digest: nil},
               actor: actor
             )
             |> Ash.update()

    assert missing_source.status == :approved
    assert is_nil(missing_source.source_oci_ref)
    assert is_nil(missing_source.source_oci_digest)

    assert {:ok, repaired, :repaired} =
             Importer.import_entry_with_disposition(
               manifest(addon_id, uid),
               source_entry,
               artifacts,
               public_key: pub,
               mirror: mirror(addon_id),
               actor: actor,
               release_tag: "sha-#{uid}"
             )

    assert repaired.id == package.id
    assert repaired.status == :staged
    assert repaired.source_oci_ref == source_entry["oci_ref"]
    assert repaired.source_oci_digest == source_entry["oci_digest"]
    assert is_nil(repaired.approved_by)
    assert repaired.artifacts == package.artifacts

    assert {:ok, reused, :reused} =
             Importer.import_entry_with_disposition(
               manifest(addon_id, uid),
               source_entry,
               artifacts,
               public_key: pub,
               mirror: mirror(addon_id),
               actor: actor,
               release_tag: "sha-#{uid}"
             )

    assert reused.id == package.id
    assert reused.status == :staged
    assert reused.source_oci_ref == source_entry["oci_ref"]
    assert reused.source_oci_digest == source_entry["oci_digest"]
  end

  test "reuses verified package content from a later OCI envelope and preserves provenance", %{
    actor: actor,
    uid: uid
  } do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    addon_id = "repackaged-content-#{uid}"
    original_entry = entry(addon_id, uid)
    artifacts = signed_artifacts(priv, uid)

    assert {:ok, package, :created} =
             Importer.import_entry_with_disposition(
               manifest(addon_id, uid),
               original_entry,
               artifacts,
               public_key: pub,
               mirror: mirror(addon_id),
               actor: actor,
               release_tag: "v1.0.0"
             )

    assert {:ok, approved} =
             package
             |> Ash.Changeset.for_update(
               :approve,
               %{approved_capabilities: package.capabilities, approved_by: "envelope-review"},
               actor: actor
             )
             |> Ash.update()

    later_entry =
      entry(addon_id, uid, %{
        "oci_ref" => "registry.carverauto.dev/serviceradar/#{addon_id}:v1.0.1",
        "oci_digest" => "sha256:#{String.duplicate("f", 64)}"
      })

    assert {:ok, reused, :reused} =
             Importer.import_entry_with_disposition(
               manifest(addon_id, uid),
               later_entry,
               artifacts,
               public_key: pub,
               mirror: mirror(addon_id),
               actor: actor,
               release_tag: "v1.0.1"
             )

    assert reused.id == package.id
    assert reused.status == :approved
    assert reused.approved_by == "envelope-review"
    assert reused.approved_at == approved.approved_at
    assert reused.source_oci_ref == original_entry["oci_ref"]
    assert reused.source_oci_digest == original_entry["oci_digest"]
    assert reused.source_release_tag == "v1.0.0"
    assert reused.source_metadata == package.source_metadata
    assert reused.artifacts == package.artifacts
  end

  test "rejects a changed bundle digest under a later OCI envelope without mutating the package",
       %{
         actor: actor,
         uid: uid
       } do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    addon_id = "changed-bundle-digest-#{uid}"
    original_entry = entry(addon_id, uid)
    artifacts = signed_artifacts(priv, uid)

    assert {:ok, package, :created} =
             Importer.import_entry_with_disposition(
               manifest(addon_id, uid),
               original_entry,
               artifacts,
               public_key: pub,
               mirror: mirror(addon_id),
               actor: actor,
               release_tag: "v1.0.0"
             )

    changed_entry =
      entry(addon_id, uid, %{
        "oci_ref" => "registry.carverauto.dev/serviceradar/#{addon_id}:v1.0.1",
        "oci_digest" => "sha256:#{String.duplicate("e", 64)}",
        "bundle_digest" => "sha256:#{String.duplicate("d", 64)}"
      })

    assert {:error,
            {:native_addon_version_source_conflict,
             %{reason: :oci_source_mismatch, existing_source_type: :first_party}}} =
             Importer.import_entry_with_disposition(
               manifest(addon_id, uid),
               changed_entry,
               artifacts,
               public_key: pub,
               mirror: mirror(addon_id),
               actor: actor,
               release_tag: "v1.0.1"
             )

    {:ok, persisted} = Ash.get(AddonPackage, package.id, actor: actor)
    assert persisted.source_metadata == package.source_metadata
    assert persisted.source_oci_ref == original_entry["oci_ref"]
    assert persisted.source_oci_digest == original_entry["oci_digest"]
  end

  test "replace_existing restages a first-party version onto a later signed envelope", %{
    actor: actor,
    uid: uid
  } do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    addon_id = "replace-existing-#{uid}"
    original_entry = entry(addon_id, uid)
    artifacts = signed_artifacts(priv, uid)

    assert {:ok, package, :created} =
             Importer.import_entry_with_disposition(
               manifest(addon_id, uid),
               original_entry,
               artifacts,
               public_key: pub,
               mirror: mirror(addon_id),
               actor: actor,
               release_tag: "v1.0.0"
             )

    later_entry =
      entry(addon_id, uid, %{
        "oci_ref" => "registry.carverauto.dev/serviceradar/#{addon_id}:v1.0.1",
        "oci_digest" => "sha256:#{String.duplicate("e", 64)}",
        "bundle_digest" => "sha256:#{String.duplicate("d", 64)}"
      })

    assert {:ok, replaced, :repaired} =
             Importer.import_entry_with_disposition(
               manifest(addon_id, uid),
               later_entry,
               artifacts,
               public_key: pub,
               mirror: mirror(addon_id),
               actor: actor,
               release_tag: "v1.0.1",
               replace_existing: true
             )

    assert replaced.id == package.id
    assert replaced.source_oci_ref == later_entry["oci_ref"]
    assert replaced.source_oci_digest == later_entry["oci_digest"]
    assert replaced.status == :staged
  end

  test "rejects a later OCI envelope for a legacy package without bundle provenance", %{
    actor: actor,
    uid: uid
  } do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    addon_id = "missing-bundle-provenance-#{uid}"
    original_entry = entry(addon_id, uid)
    artifacts = signed_artifacts(priv, uid)

    assert {:ok, package, :created} =
             Importer.import_entry_with_disposition(
               manifest(addon_id, uid),
               original_entry,
               artifacts,
               public_key: pub,
               mirror: mirror(addon_id),
               actor: actor,
               release_tag: "v1.0.0"
             )

    assert {:ok, legacy} =
             package
             |> Ash.Changeset.for_update(:update, %{source_metadata: %{}}, actor: actor)
             |> Ash.update()

    later_entry =
      entry(addon_id, uid, %{
        "oci_ref" => "registry.carverauto.dev/serviceradar/#{addon_id}:v1.0.1",
        "oci_digest" => "sha256:#{String.duplicate("f", 64)}"
      })

    assert {:error,
            {:native_addon_version_source_conflict,
             %{reason: :oci_source_mismatch, existing_source_type: :first_party}}} =
             Importer.import_entry_with_disposition(
               manifest(addon_id, uid),
               later_entry,
               artifacts,
               public_key: pub,
               mirror: mirror(addon_id),
               actor: actor,
               release_tag: "v1.0.1"
             )

    {:ok, persisted} = Ash.get(AddonPackage, package.id, actor: actor)
    assert persisted.source_metadata == legacy.source_metadata
    assert persisted.source_oci_ref == original_entry["oci_ref"]
    assert persisted.source_oci_digest == original_entry["oci_digest"]
  end

  test "rejects changed immutable content under a new OCI envelope without mutating the package",
       %{
         actor: actor,
         uid: uid
       } do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    addon_id = "changed-content-#{uid}"
    original_entry = entry(addon_id, uid)
    artifacts = signed_artifacts(priv, uid)

    assert {:ok, package, :created} =
             Importer.import_entry_with_disposition(
               manifest(addon_id, uid),
               original_entry,
               artifacts,
               public_key: pub,
               mirror: mirror(addon_id),
               actor: actor,
               release_tag: "v1.0.0"
             )

    changed_manifest = Map.put(manifest(addon_id, uid), "name", "Changed Netprobe #{uid}")

    changed_entry =
      entry(addon_id, uid, %{
        "oci_ref" => "registry.carverauto.dev/serviceradar/#{addon_id}:v1.0.1",
        "oci_digest" => "sha256:#{String.duplicate("e", 64)}"
      })

    assert {:error,
            {:native_addon_version_source_conflict,
             %{reason: :oci_source_mismatch, existing_source_type: :first_party}}} =
             Importer.import_entry_with_disposition(
               changed_manifest,
               changed_entry,
               artifacts,
               public_key: pub,
               mirror: mirror(addon_id),
               actor: actor,
               release_tag: "v1.0.1"
             )

    {:ok, persisted} = Ash.get(AddonPackage, package.id, actor: actor)
    assert persisted.name == package.name
    assert persisted.source_oci_ref == original_entry["oci_ref"]
    assert persisted.source_oci_digest == original_entry["oci_digest"]
    assert persisted.source_release_tag == "v1.0.0"
    assert persisted.artifacts == package.artifacts
  end

  test "concurrent imports of one source converge on one package", %{
    actor: actor,
    uid: uid
  } do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    addon_id = "same-source-race-#{uid}"
    parent = self()

    blocking_mirror = fn os, arch, _bytes ->
      send(parent, {:mirror_ready, self()})

      receive do
        :continue_import -> {:ok, "native-addons/#{addon_id}/0.1.0/#{os}-#{arch}/obj"}
      after
        10_000 -> {:error, :barrier_timeout}
      end
    end

    import = fn ->
      Importer.import_entry_with_disposition(
        manifest(addon_id, uid),
        entry(addon_id, uid),
        signed_artifacts(priv, uid),
        public_key: pub,
        mirror: blocking_mirror,
        actor: actor
      )
    end

    tasks = [Task.async(import), Task.async(import)]
    release_mirror_barrier!(2)
    results = Enum.map(tasks, &Task.await(&1, 30_000))

    assert Enum.all?(results, &match?({:ok, %AddonPackage{}, _disposition}, &1))

    assert results |> Enum.map(fn {:ok, _package, disposition} -> disposition end) |> Enum.sort() ==
             [:created, :reused]

    assert results
           |> Enum.map(fn {:ok, package, _disposition} -> package.id end)
           |> Enum.uniq()
           |> length() ==
             1

    assert package_count(addon_id, actor) == 1
  end

  test "concurrent imports with different immutable content return one conflict", %{
    actor: actor,
    uid: uid
  } do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    addon_id = "different-source-race-#{uid}"
    parent = self()

    blocking_mirror = fn os, arch, _bytes ->
      send(parent, {:mirror_ready, self()})

      receive do
        :continue_import -> {:ok, "native-addons/#{addon_id}/0.1.0/#{os}-#{arch}/obj"}
      after
        10_000 -> {:error, :barrier_timeout}
      end
    end

    import = fn source_suffix ->
      manifest =
        case source_suffix do
          "a" -> manifest(addon_id, uid)
          "b" -> Map.put(manifest(addon_id, uid), "name", "Changed Netprobe #{uid}")
        end

      Importer.import_entry(
        manifest,
        entry(addon_id, uid, %{
          "oci_ref" => "registry.carverauto.dev/serviceradar/#{addon_id}:#{source_suffix}",
          "oci_digest" => "sha256:#{String.duplicate(source_suffix, 64)}"
        }),
        signed_artifacts(priv, uid),
        public_key: pub,
        mirror: blocking_mirror,
        actor: actor
      )
    end

    tasks = [Task.async(fn -> import.("a") end), Task.async(fn -> import.("b") end)]
    release_mirror_barrier!(2)
    results = Enum.map(tasks, &Task.await(&1, 30_000))

    assert Enum.count(results, &match?({:ok, %AddonPackage{}}, &1)) == 1

    assert Enum.count(results, fn
             {:error, {:native_addon_version_source_conflict, _details}} -> true
             _ -> false
           end) == 1

    assert package_count(addon_id, actor) == 1
  end

  defp release_mirror_barrier!(count) do
    pids =
      Enum.map(1..count, fn _index ->
        assert_receive {:mirror_ready, pid}, 10_000
        pid
      end)

    Enum.each(pids, &send(&1, :continue_import))
  end

  defp package_count(addon_id, actor) do
    AddonPackage
    |> Ash.Query.for_read(:by_addon_id, %{addon_id: addon_id}, actor: actor)
    |> Ash.read!(actor: actor)
    |> length()
  end
end
