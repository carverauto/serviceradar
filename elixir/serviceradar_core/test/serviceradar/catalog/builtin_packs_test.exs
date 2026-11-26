defmodule ServiceRadar.Catalog.BuiltinPacksTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Catalog.BuiltinPacks
  alias ServiceRadar.Catalog.PackArchive
  alias ServiceRadar.Catalog.PackManifest
  alias ServiceRadar.Catalog.Reconciler
  alias ServiceRadar.Catalog.SecretFreeValidator
  alias ServiceRadar.Catalog.SvgSanitizer
  alias ServiceRadar.DeclarativeChecks.SchemaValidator

  @moduletag :db_free

  @expected_pack_slugs [
    "http-api-and-tls-posture",
    "network-segmentation-and-wan",
    "proxmox-monitoring",
    "storage-and-nvr-health"
  ]

  @expected_pack_ids [
    "io.serviceradar.http-api-and-tls-posture",
    "io.serviceradar.network-segmentation-and-wan",
    "io.serviceradar.proxmox-monitoring",
    "io.serviceradar.storage-and-nvr-health"
  ]

  defp operator_actor do
    %{
      id: "00000000-0000-4000-8000-000000000001",
      email: "operator@example.com",
      role: :operator,
      permissions:
        MapSet.new([
          "catalog.view",
          "catalog.packs.install",
          "catalog.packs.export",
          "catalog.gitops.sync"
        ])
    }
  end

  defp start_mem_store do
    {:ok, pid} =
      Agent.start_link(fn ->
        %{packs: %{}, checks: %{}, check_bindings: %{}, rules: %{}, dashboards: %{}}
      end)

    pid
  end

  describe "built-in gallery" do
    test "list_builtin_packs/0 and load_builtin_pack/1 discover and return every built-in pack cleanly" do
      assert {:ok, packs} = BuiltinPacks.list_builtin_packs()
      assert length(packs) == length(@expected_pack_slugs)

      slugs = Enum.map(packs, & &1.manifest["slug"])
      ids = Enum.map(packs, & &1.manifest["id"])

      assert slugs == @expected_pack_slugs
      assert ids == @expected_pack_ids

      for {slug, id} <- Enum.zip(@expected_pack_slugs, @expected_pack_ids) do
        assert {:ok, by_slug} = BuiltinPacks.load_builtin_pack(slug)
        assert {:ok, by_id} = BuiltinPacks.load_builtin_pack(id)
        assert by_slug.manifest["id"] == id
        assert by_id.manifest["slug"] == slug
      end
    end

    test "every built-in pack passes PackManifest, SecretFreeValidator, SvgSanitizer, and SchemaValidator" do
      assert {:ok, packs} = BuiltinPacks.list_builtin_packs()

      for pack <- packs do
        raw_manifest = Jason.decode!(pack.files["manifest.json"])

        assert {:ok, normalized_manifest} = PackManifest.validate_manifest(raw_manifest)
        assert normalized_manifest["pack_format_version"] == 1

        assert {:ok, _validated} =
                 PackManifest.validate_pack_tree(pack.files, skip_srql_nif?: true)

        assert :ok = SecretFreeValidator.validate_pack_tree(pack.files)

        assert {:ok, _clean_icon} = SvgSanitizer.validate_svg(raw_manifest["icon"])

        assert {:ok, _clean_arch} =
                 SvgSanitizer.validate_svg(pack.files["assets/architecture.svg"])

        for {path, bytes} <- pack.files do
          assert String.valid?(bytes), "expected valid UTF-8 in #{pack.manifest["slug"]}/#{path}"

          assert Enum.all?(:binary.bin_to_list(bytes), &(&1 < 128)),
                 "expected 7-bit ASCII in #{pack.manifest["slug"]}/#{path}"
        end

        for check <- pack.checks do
          assert {:ok, _normalized_check} =
                   SchemaValidator.validate_document(check.normalized, skip_srql_nif?: true)
        end
      end
    end

    test "verifies expected check topologies, rule install states, and dashboard titles for the new packs" do
      {:ok, http_pack} = BuiltinPacks.load_builtin_pack("http-api-and-tls-posture")

      assert http_pack.manifest["categories"] == ["Synthetic HTTP", "Security & Posture"]

      assert Enum.map(http_pack.checks, & &1.normalized["slug"]) == [
               "http-api-journey-health",
               "tls-certificate-expiry-posture"
             ]

      assert Enum.all?(http_pack.checks, fn c ->
               SchemaValidator.classify_topology(c.normalized["nodes"]) == :edge_only
             end)

      assert Enum.map(http_pack.rules, & &1.normalized["install_state"]) == ["enabled", "paused"]
      assert hd(http_pack.dashboards).normalized["title"] == "Synthetic HTTP & TLS Posture"

      {:ok, net_pack} = BuiltinPacks.load_builtin_pack("network-segmentation-and-wan")

      assert net_pack.manifest["categories"] == ["Network & WAN", "Security & Posture"]

      assert Enum.map(net_pack.checks, & &1.normalized["slug"]) == [
               "multi-vantage-segmentation-isolation",
               "wan-dns-resolution-posture"
             ]

      assert Enum.map(net_pack.checks, fn c ->
               SchemaValidator.classify_topology(c.normalized["nodes"])
             end) == [:hybrid, :edge_only]

      assert length(net_pack.rules) == 2

      assert hd(net_pack.dashboards).normalized["title"] ==
               "Network Segmentation & WAN Resilience"
    end

    test "every built-in pack round-trips deterministically through PackArchive" do
      assert {:ok, packs} = BuiltinPacks.list_builtin_packs()

      for pack <- packs do
        assert {:ok, srpack_a} = PackArchive.build(pack.files)
        assert {:ok, srpack_b} = PackArchive.build(pack.files)
        assert PackManifest.sha256_hex(srpack_a) == PackManifest.sha256_hex(srpack_b)

        assert {:ok, extracted} = PackArchive.extract(srpack_a)
        assert extracted.files == pack.files
        assert extracted.manifest["id"] == pack.manifest["id"]
      end
    end

    test "every built-in pack passes Reconciler dry-run preview" do
      assert {:ok, packs} = BuiltinPacks.list_builtin_packs()
      actor = operator_actor()

      for pack <- packs do
        store = start_mem_store()

        assert {:ok, plan} =
                 Reconciler.preview(pack, %{},
                   actor: actor,
                   state_store: store,
                   skip_srql_nif?: true
                 )

        assert plan.dry_run == true
        assert length(plan.checks) == length(pack.checks)
        assert length(plan.rules) == length(pack.rules)
        assert length(plan.dashboards) == length(pack.dashboards)
        assert Enum.all?(plan.checks, &(&1.action == :create))
        assert Enum.all?(plan.rules, &(&1.action == :create))
        assert Enum.all?(plan.dashboards, &(&1.action == :create))
      end
    end
  end
end
