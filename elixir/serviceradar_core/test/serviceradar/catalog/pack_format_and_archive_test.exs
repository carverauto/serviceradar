defmodule ServiceRadar.Catalog.PackFormatAndArchiveTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias ServiceRadar.Catalog.BuiltinPacks
  alias ServiceRadar.Catalog.PackArchive
  alias ServiceRadar.Catalog.PackExporter
  alias ServiceRadar.Catalog.PackManifest
  alias ServiceRadar.Catalog.SecretFreeValidator
  alias ServiceRadar.Catalog.SvgSanitizer
  alias ServiceRadar.Catalog.UploadSignature
  alias ServiceRadar.DeclarativeChecks.AlertRuleSync
  alias ServiceRadar.DeclarativeChecks.DAGEngine
  alias ServiceRadar.DeclarativeChecks.VerdictEventWriter
  alias ServiceRadar.Observability.StatefulAlertEngine.RuleMatcher

  @moduletag :db_free

  describe "Built-in Pack #1 (io.serviceradar.storage-and-nvr-health)" do
    test "loads offline from priv/solution_packs with 4 posture checks, 2 alert rules, and 1 dashboard" do
      assert {:ok, packs} = BuiltinPacks.list_packs()
      assert Enum.any?(packs, &(&1.manifest["id"] == "io.serviceradar.storage-and-nvr-health"))

      assert {:ok, pack} = BuiltinPacks.get_pack("io.serviceradar.storage-and-nvr-health")
      assert pack.manifest["slug"] == "storage-and-nvr-health"
      assert pack.manifest["pack_format_version"] == 1

      check_slugs = Enum.map(pack.checks, & &1.normalized["slug"])

      assert check_slugs == [
               "storage-entitlement-utilization",
               "storage-hold-pin-pressure",
               "storage-archive-credential-health",
               "camera-continuous-recording-silence"
             ]

      assert length(pack.rules) == 2
      assert length(pack.dashboards) == 1
      assert hd(pack.dashboards).normalized["slug"] == "storage-and-nvr-overview"
    end

    test "round-trips deterministically through PackArchive (.srpack tar.zst)" do
      {:ok, pack} = BuiltinPacks.get_pack("storage-and-nvr-health")

      assert {:ok, srpack_a} = PackArchive.build(pack.files)
      assert {:ok, srpack_b} = PackArchive.build(pack.files)

      assert <<0x28, 0xB5, 0x2F, 0xFD, _::binary>> = srpack_a
      assert PackManifest.sha256_hex(srpack_a) == PackManifest.sha256_hex(srpack_b)

      assert {:ok, extracted} = PackArchive.extract(srpack_a)
      assert extracted.files == pack.files
      assert extracted.manifest["id"] == "io.serviceradar.storage-and-nvr-health"
    end
  end

  describe "Built-in Pack (io.serviceradar.proxmox-monitoring)" do
    # The shipped check documents are evaluated by the real engine. Only the
    # inventory is stubbed: every virtualization SRQL row is one "payload"
    # column, which is the shape the checks have to read.

    test "datastore capacity follows the default 80 and 90 percent thresholds" do
      check = proxmox_check("proxmox-datastore-capacity")

      for {used_percent, status, verdict} <- [
            {72, :healthy, "datastores_have_headroom"},
            {80, :degraded, "datastore_filling"},
            {89, :degraded, "datastore_filling"},
            {90, :down, "datastore_nearly_full"},
            {100, :down, "datastore_nearly_full"}
          ] do
        rows = [%{"payload" => %{"name" => "tank01", "used_percent" => used_percent}}]

        assert {:ok, result} = evaluate_with_inventory(check, fn _query -> rows end)
        assert {result.status, result.verdict} == {status, verdict}
      end
    end

    test "datastore capacity cannot tell when no datastore was reported" do
      check = proxmox_check("proxmox-datastore-capacity")

      assert {:ok, result} = evaluate_with_inventory(check, fn _query -> [] end)
      assert {result.status, result.verdict} == {:unknown, "no_fresh_datastore_inventory"}
    end

    test "paused guests are critical and every unreadable guest state is reported unknown" do
      check = proxmox_check("proxmox-paused-guests")
      outcomes = [:zero, :some, :error]

      for fresh <- outcomes, paused <- outcomes, unreported <- outcomes do
        guests = %{fresh: fresh, paused: paused, unreported: unreported}

        assert {:ok, result} = evaluate_with_inventory(check, &guest_rows(&1, guests))

        assert {guests, {result.status, result.verdict}} ==
                 {guests, expected_paused_guest_verdict(guests)}
      end
    end

    test "inventory freshness fails when no host was reported" do
      check = proxmox_check("proxmox-inventory-freshness")
      host = [%{"payload" => %{"name" => "pve-a"}}]

      assert {:ok, current} = evaluate_with_inventory(check, fn _query -> host end)
      assert {current.status, current.verdict} == {:healthy, "inventory_current"}

      assert {:ok, stale} = evaluate_with_inventory(check, fn _query -> [] end)
      assert {stale.status, stale.verdict} == {:down, "inventory_stale"}
    end

    test "each alert has one owner: a pack rule that matches only its own check's transition" do
      {:ok, pack} = BuiltinPacks.get_pack("proxmox-monitoring")
      checks = Map.new(pack.checks, &{&1.normalized["slug"], &1.normalized})

      # The checks' own automatic rules are off, so a pack rule never doubles one.
      for {_slug, check} <- checks do
        refute AlertRuleSync.build_rule_attrs(check).enabled
      end

      expected = %{
        "proxmox_datastore_nearly_full" => {"proxmox-datastore-capacity", "down"},
        "proxmox_datastore_filling" => {"proxmox-datastore-capacity", "degraded"},
        "proxmox_guests_paused" => {"proxmox-paused-guests", "down"},
        "proxmox_guest_runtime_state_unavailable" => {"proxmox-paused-guests", "unknown"},
        "proxmox_inventory_stale" => {"proxmox-inventory-freshness", "down"}
      }

      assert expected |> Map.keys() |> Enum.sort() ==
               pack.rules |> Enum.map(& &1.normalized["name"]) |> Enum.sort()

      transitions =
        for {slug, check} <- checks, status <- ~w(healthy degraded down unknown) do
          {{slug, status}, VerdictEventWriter.event_attrs(check, %{to_status: status})}
        end

      unrelated = %{log_name: "health.agent.state_change", unmapped: %{"new_state" => "down"}}

      for rule <- pack.rules do
        match = rule.normalized["match"]
        {slug, _status} = owner = Map.fetch!(expected, rule.normalized["name"])

        matched =
          for {key, event} <- transitions, RuleMatcher.event_matches?(event, match), do: key

        assert matched == [owner]
        refute RuleMatcher.event_matches?(unrelated, match)

        recovery = VerdictEventWriter.event_attrs(checks[slug], %{to_status: "healthy"})
        assert RuleMatcher.event_matches?(recovery, match["recovery"])
      end
    end

    test "requires the plugin version that reports the runtime state" do
      {:ok, pack} = BuiltinPacks.get_pack("io.serviceradar.proxmox-monitoring")

      assert pack.manifest["plugin_dependencies"] == [
               %{"package_id" => "proxmox-inventory", "version_constraint" => ">=0.1.14"}
             ]

      assert pack.manifest["credential_slots"] == []
    end
  end

  describe "stateful alert rule match keys" do
    @state_change "declarative_check.health.state_change"

    defp stateful_rule(match) do
      %{
        "kind" => "stateful_alert_rule",
        "name" => "example_rule",
        "signal" => "event",
        "threshold" => 1,
        "window_seconds" => 300,
        "bucket_seconds" => 60,
        "match" => match
      }
    end

    test "a rule whose match keys the engine does not read is refused, because it would match every event" do
      unread = %{"check_slug" => "example-check", "status" => "down"}

      # What the refusal prevents: the engine ignores both keys.
      assert RuleMatcher.event_matches?(%{log_name: "health.agent.state_change"}, unread)

      assert {:error, diags} =
               PackManifest.validate_rule_doc(
                 stateful_rule(unread),
                 "stateful_alert_rule",
                 "rules/example.json"
               )

      assert Enum.map(diags, &{&1.code, &1.path}) == [
               {"unknown_match_key", "$.match.check_slug"},
               {"unknown_match_key", "$.match.status"}
             ]
    end

    test "an unread key inside the recovery clause is refused too" do
      match = %{"subject_prefix" => @state_change, "recovery" => %{"to_status" => "healthy"}}

      assert {:error, [diag]} =
               PackManifest.validate_rule_doc(
                 stateful_rule(match),
                 "stateful_alert_rule",
                 "rules/example.json"
               )

      assert {diag.code, diag.path} == {"unknown_match_key", "$.match.recovery.to_status"}
    end

    test "every built-in pack rule matches only its own check's transition, and nothing else opens that alert" do
      expected = %{
        "storage_entitlement_hard_cap" => {"storage-entitlement-utilization", "down"},
        "camera_continuous_recording_silence" => {"camera-continuous-recording-silence", "down"},
        "http_api_journey_down" => {"http-api-journey-health", "down"},
        "tls_certificate_expiry_warning" => {"tls-certificate-expiry-posture", "degraded"},
        "network_segmentation_breach" => {"multi-vantage-segmentation-isolation", "down"},
        "wan_dns_resolution_degraded" => {"wan-dns-resolution-posture", "degraded"}
      }

      {:ok, packs} = BuiltinPacks.list_packs()

      checks =
        for pack <- packs,
            check <- pack.checks,
            into: %{},
            do: {check.normalized["slug"], check.normalized}

      rules =
        for pack <- packs,
            rule <- pack.rules,
            into: %{},
            do: {rule.normalized["name"], rule.normalized}

      transitions =
        for {slug, check} <- checks, status <- ~w(healthy degraded down unknown) do
          {{slug, status}, VerdictEventWriter.event_attrs(check, %{to_status: status})}
        end

      for {name, {slug, status} = owner} <- expected do
        match = Map.fetch!(rules, name)["match"]

        matched =
          for {key, event} <- transitions, RuleMatcher.event_matches?(event, match), do: key

        assert matched == [owner], "#{name} matched #{inspect(matched)}"
        refute RuleMatcher.event_matches?(%{log_name: "health.agent.state_change"}, match)

        recovery = VerdictEventWriter.event_attrs(checks[slug], %{to_status: "healthy"})
        assert RuleMatcher.event_matches?(recovery, match["recovery"])

        # The check's automatic rule does not open on the same status, so the
        # condition raises one alert.
        automatic = AlertRuleSync.build_rule_attrs(checks[slug])
        automatic_statuses = List.wrap(automatic.match["attribute_equals"]["to_status"])
        refute automatic.enabled and status in automatic_statuses
      end
    end
  end

  describe "PackManifest and PackArchive fail-closed security guards" do
    test "rejects unsupported pack_format_version and mismatched file digests" do
      {:ok, pack} = BuiltinPacks.get_pack("storage-and-nvr-health")
      manifest = Jason.decode!(pack.files["manifest.json"])

      bad_version = Map.put(manifest, "pack_format_version", 99)
      assert {:error, diags} = PackManifest.validate_manifest(bad_version)
      assert Enum.any?(diags, &(&1.code == "unsupported_pack_format_version"))

      tampered_files = Map.put(pack.files, "README.md", "# tampered\n")
      assert {:error, digest_diags} = PackManifest.validate_pack_tree(tampered_files)
      assert Enum.any?(digest_diags, &(&1.code == "digest_mismatch" and &1.file == "README.md"))
    end

    test "rejects unlisted files, path traversal, symlinks, and archive bombs" do
      {:ok, pack} = BuiltinPacks.get_pack("storage-and-nvr-health")

      with_unlisted = Map.put(pack.files, "checks/unlisted-extra.json", ~s({"slug":"extra"}))
      assert {:error, unlisted_diags} = PackManifest.validate_pack_tree(with_unlisted)
      assert Enum.any?(unlisted_diags, &(&1.code == "unlisted_file"))

      traversal_zip = build_raw_zip([{"../escape.txt", "boom"}])

      assert {:error, {:unsafe_archive_path, "../escape.txt"}} =
               PackArchive.extract(traversal_zip)

      symlink_tar = build_symlink_ustar("checks/evil-link.json", "/etc/passwd")
      symlink_zst = IO.iodata_to_binary(:zstd.compress(symlink_tar, %{compressionLevel: 3}))
      assert {:error, :symlink_forbidden} = PackArchive.extract(symlink_zst)

      bomb_payload = :binary.copy(<<0>>, 200_000)
      bomb_zst = IO.iodata_to_binary(:zstd.compress(bomb_payload, %{compressionLevel: 3}))
      assert byte_size(bomb_zst) < 1_024

      assert {:error, :uncompressed_archive_too_large} =
               PackArchive.extract(bomb_zst, max_uncompressed_bytes: 32_768)

      assert {:error, :compressed_archive_too_large} =
               PackArchive.extract(bomb_zst, max_compressed_bytes: 8)
    end

    test "accepts valid .zip and tar.gz archives matching manifest.files" do
      {:ok, pack} = BuiltinPacks.get_pack("storage-and-nvr-health")

      zip_bytes =
        pack.files
        |> Enum.sort_by(&elem(&1, 0))
        |> build_raw_zip()

      assert {:ok, from_zip} = PackArchive.extract(zip_bytes)
      assert from_zip.manifest["id"] == "io.serviceradar.storage-and-nvr-health"

      {:ok, ustar} = PackArchive.encode_ustar(pack.files)
      gz_bytes = :zlib.gzip(ustar)

      assert {:ok, from_gz} = PackArchive.extract(gz_bytes)
      assert from_gz.manifest["id"] == "io.serviceradar.storage-and-nvr-health"
    end

    test "rejects overlapping dashboard panels and unbound query fields" do
      bad_dash = %{
        "version" => 1,
        "slug" => "overlap-dash",
        "title" => "Overlap",
        "panels" => [
          %{
            "title" => "A",
            "srql_query" => "in:services stats:\"count() as total\"",
            "visual_type" => "stat",
            "data_binding" => %{"value" => "total"},
            "layout" => %{"x" => 0, "y" => 0, "w" => 8, "h" => 3}
          },
          %{
            "title" => "B",
            "srql_query" => "in:services stats:\"count() as total\"",
            "visual_type" => "stat",
            "data_binding" => %{"value" => "missing_alias"},
            "layout" => %{"x" => 6, "y" => 0, "w" => 6, "h" => 3}
          }
        ]
      }

      assert {:error, errs} = PackManifest.validate_dashboard_doc(bad_dash, "dashboards/bad.json")
      assert Enum.any?(errs, &(&1.code == "unbound_query_field"))

      fixed_binding =
        put_in(bad_dash, ["panels", Access.at(1), "data_binding", "value"], "total")

      assert {:error, overlap_errs} =
               PackManifest.validate_dashboard_doc(fixed_binding, "dashboards/bad.json")

      assert Enum.any?(overlap_errs, &(&1.code == "overlapping_panels"))
    end
  end

  describe "SvgSanitizer and Markdown sanitization" do
    test "rejects and strips <script>, <foreignObject>, on* attributes, and external hrefs" do
      xss_svg = """
      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48" onload="alert(1)">
        <script>alert('xss')</script>
        <foreignObject><body xmlns="http://www.w3.org/1999/xhtml"><iframe src="https://evil.example.com"/></body></foreignObject>
        <defs><linearGradient id="g1"><stop offset="0%" stop-color="#000"/></linearGradient></defs>
        <rect x="0" y="0" width="48" height="48" fill="url(#other)" href="https://evil.example.com/track.svg" onclick="evil()"/>
        <circle cx="24" cy="24" r="10" href="#g1" fill="#38bdf8"/>
      </svg>
      """

      assert {:error, {:svg_forbidden_element, _}} = SvgSanitizer.validate_svg(xss_svg)

      assert {:ok, clean_svg} = SvgSanitizer.sanitize_svg(xss_svg)
      refute clean_svg =~ "script"
      refute clean_svg =~ "foreignObject"
      refute clean_svg =~ "onload"
      refute clean_svg =~ "onclick"
      refute clean_svg =~ "evil.example.com"
      assert clean_svg =~ ~s(href="#g1")
      assert clean_svg =~ "<circle"
    end

    test "sanitizes Markdown stripping active HTML and enforcing rel=noopener noreferrer" do
      md = """
      # Pack Docs
      <script>steal()</script>
      See <a href="https://docs.example.com" target="_blank" onclick="bad()">Guide</a>
      and [Bad](javascript:alert(1)).
      """

      assert {:ok, clean} = SvgSanitizer.sanitize_markdown(md)
      refute clean =~ "<script>"
      refute clean =~ "onclick"
      refute clean =~ "javascript:"
      assert clean =~ ~s(rel="noopener noreferrer")
    end
  end

  describe "SecretFreeValidator and PackExporter" do
    test "strips live instance UUIDs and credential bindings into abstract credential_slots" do
      live_check = %{
        id: "00000000-0000-4000-8000-000000000099",
        schema_version: 1,
        slug: "synthetic-api-probe",
        name: "Synthetic API Probe",
        state: :enabled,
        credential_secret_id: "00000000-0000-4000-8000-000000000010",
        credential_rule_id: "00000000-0000-4000-8000-000000000011",
        credential_bindings: [
          %{
            id: "00000000-0000-4000-8000-000000000012",
            slot: "target_http_api",
            credential_secret_id: "00000000-0000-4000-8000-000000000010"
          }
        ],
        credential_slots: [
          %{
            "slot" => "target_http_api",
            "provider" => "generic_http",
            "role" => "bearer_token",
            "purpose" => "Synthetic API health check",
            "required" => true
          }
        ],
        nodes: [
          %{
            "id" => "req_1",
            "kind" => "http_request",
            "label" => "GET Health",
            "config" => %{
              "method" => "GET",
              "url" => "https://api.example.com/healthz",
              "credential_slot" => "target_http_api"
            }
          },
          %{
            "id" => "assert_1",
            "kind" => "threshold_assert",
            "label" => "HTTP Status OK",
            "config" => %{
              "field" => "status_code",
              "crit" => %{"op" => ">=", "value" => 500}
            }
          },
          %{
            "id" => "out_1",
            "kind" => "alert_output",
            "label" => "Verdict",
            "config" => %{}
          }
        ],
        edges: [
          %{
            "id" => "e1",
            "source" => "req_1",
            "source_handle" => "signal",
            "target" => "assert_1",
            "target_handle" => "in"
          },
          %{
            "id" => "e2",
            "source" => "assert_1",
            "source_handle" => "verdict",
            "target" => "out_1",
            "target_handle" => "in"
          }
        ]
      }

      live_dash = %{
        id: "00000000-0000-4000-8000-000000000088",
        dashboard_ref: 7_654_321,
        owner_id: "00000000-0000-4000-8000-000000000077",
        slug: "synthetic-api-overview",
        title: "Synthetic API Overview",
        panels: [
          %{
            id: "00000000-0000-4000-8000-000000000066",
            dashboard_id: "00000000-0000-4000-8000-000000000088",
            title: "Checks",
            srql_query: "in:services stats:\"count() as total\"",
            visual_type: :stat,
            data_binding: %{"value" => "total"},
            layout: %{"x" => 0, "y" => 0, "w" => 6, "h" => 3},
            position: 0
          }
        ]
      }

      assert {:ok, exported_tree} =
               PackExporter.export_tree(%{
                 id: "io.example.synthetic-api",
                 slug: "synthetic-api",
                 name: "Synthetic API Pack",
                 version: "0.1.0",
                 checks: [live_check],
                 dashboards: [live_dash]
               })

      joined = Enum.map_join(exported_tree, "\n", fn {_k, v} -> v end)
      refute joined =~ "00000000-0000-4000-8000-"
      refute joined =~ "credential_secret_id"
      refute joined =~ "credential_rule_id"
      refute joined =~ "7654321"

      manifest = Jason.decode!(exported_tree["manifest.json"])
      assert [%{"slot" => "target_http_api", "required" => true}] = manifest["credential_slots"]
    end

    test "fails closed on secret keys and PAT/key literals with exact file and JSON path" do
      github_token = "ghp_" <> String.duplicate("a", 24)
      gitlab_token = "glpat-" <> String.duplicate("b", 16)

      leaked_tree = %{
        "manifest.json" => ~s({"pack_format_version":1}),
        "checks/leak.json" =>
          Jason.encode!(%{
            "slug" => "leak",
            "config" => %{
              "community_string" => "synthetic-snmp",
              "note" => "embedded #{github_token}"
            }
          }),
        "README.md" => "Do not commit #{gitlab_token}\n"
      }

      assert {:error, violations} = SecretFreeValidator.validate_pack_tree(leaked_tree)

      assert Enum.any?(
               violations,
               &(&1.file == "checks/leak.json" and &1.path == "$.config.community_string" and
                   &1.code == "forbidden_secret_key")
             )

      assert Enum.any?(
               violations,
               &(&1.file == "checks/leak.json" and &1.path == "$.config.note" and
                   &1.code == "github_pat")
             )

      assert Enum.any?(
               violations,
               &(&1.file == "README.md" and &1.code == "gitlab_pat")
             )
    end
  end

  describe "UploadSignature cross-language canonical JSON & Ed25519 conformance" do
    test "matches shared CLI and Go conformance vector byte-for-byte" do
      manifest = %{
        "pack_format_version" => 1,
        "id" => "io.example.conformance-pack",
        "slug" => "conformance-pack",
        "name" => "Conformance <Pack>",
        "version" => "0.1.0",
        "categories" => ["Storage & NVR"],
        "config" => [],
        "credential_slots" => [],
        "plugin_dependencies" => [],
        "resources" => %{"checks" => [], "rules" => [], "dashboards" => []},
        "files" => %{"README.md" => String.duplicate("cd", 32)}
      }

      content_hash = String.duplicate("ab", 32)

      expected_payload =
        ~s({"content_hash":"abababababababababababababababababababababababababababababababab","manifest":{"categories":["Storage & NVR"],"config":[],"credential_slots":[],"files":{"README.md":"cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd"},"id":"io.example.conformance-pack","name":"Conformance <Pack>","pack_format_version":1,"plugin_dependencies":[],"resources":{"checks":[],"dashboards":[],"rules":[]},"slug":"conformance-pack","version":"0.1.0"}})

      assert UploadSignature.verification_payload(manifest, String.upcase(content_hash)) ==
               expected_payload

      sig_doc = %{
        "algorithm" => "ed25519",
        "key_id" => "conformance-key-1",
        "content_hash" => content_hash,
        "signature" =>
          "xeLs96BmT+/ac+HgPnQ7LMXyXe0olbpQjW4BgdWgWvhHnr7L3ZJPYlVObW2FxCL5YCcTEBYY+OGLas/xQaKMDw=="
      }

      expected_pub_b64 = "0EqyMnQrtKs6E2i9RhXk5t" <> "AiSrcaAWuvhSCjMsl3hzc="
      trusted = %{"conformance-key-1" => expected_pub_b64}
      assert :ok = UploadSignature.verify(sig_doc, manifest, content_hash, trusted)

      seed = :binary.copy(<<0x11>>, 32)

      assert {:ok, signed} =
               UploadSignature.sign(manifest, content_hash, seed, key_id: "conformance-key-1")

      assert signed["signature"] == sig_doc["signature"]
    end
  end

  defp build_raw_zip(entries) do
    charlist_entries =
      Enum.map(entries, fn {name, content} ->
        {String.to_charlist(name), content}
      end)

    {:ok, {_filename, zip_bytes}} = :zip.create(~c"test.zip", charlist_entries, [:memory])
    zip_bytes
  end

  defp build_symlink_ustar(name, target) do
    name_pad = name <> :binary.copy(<<0>>, 100 - byte_size(name))
    mode = "0000777\0"
    uid = "0000000\0"
    gid = "0000000\0"
    size = "00000000000\0"
    mtime = "00000000000\0"
    typeflag = <<?2>>
    link_pad = target <> :binary.copy(<<0>>, 100 - byte_size(target))
    magic = "ustar\0"
    version = "00"
    tail = :binary.copy(<<0>>, 512 - 265)

    pre = name_pad <> mode <> uid <> gid <> size <> mtime
    post = typeflag <> link_pad <> magic <> version <> tail
    unsigned = pre <> "        " <> post
    sum = for <<b <- unsigned>>, reduce: 0, do: (acc -> acc + (b &&& 0xFF))
    chksum = String.pad_leading(Integer.to_string(sum, 8), 6, "0") <> <<0, 0x20>>
    pre <> chksum <> post <> :binary.copy(<<0>>, 1_024)
  end

  defp proxmox_check(slug) do
    {:ok, pack} = BuiltinPacks.get_pack("proxmox-monitoring")
    Enum.find(pack.checks, &(&1.normalized["slug"] == slug)).normalized
  end

  defp evaluate_with_inventory(check, rows_for) do
    runner = fn query, _opts ->
      case rows_for.(query) do
        {:error, _reason} = error -> error
        rows -> {:ok, %{rows: rows}}
      end
    end

    DAGEngine.evaluate_target(check, %{}, srql_runner: runner)
  end

  # A stand-in for the guest inventory: each of the check's three queries
  # returns no rows, some rows or a timeout.
  defp guest_rows(query, guests) do
    outcome =
      cond do
        String.contains?(query, "status:paused") -> guests.paused
        String.contains?(query, "runtime_state:unknown") -> guests.unreported
        true -> guests.fresh
      end

    case outcome do
      :zero -> []
      :some -> List.duplicate(%{"payload" => %{"name" => "vm-a"}}, 2)
      :error -> {:error, :timeout}
    end
  end

  # The paused-guest precedence, first match wins: an observed pause, then
  # each query failure or missing inventory, then old agents, then healthy.
  defp expected_paused_guest_verdict(%{paused: :some}), do: {:down, "guests_paused"}

  defp expected_paused_guest_verdict(%{paused: :error}),
    do: {:unknown, "paused_guest_query_failed"}

  defp expected_paused_guest_verdict(%{fresh: fresh}) when fresh in [:zero, :error],
    do: {:unknown, "no_fresh_guest_inventory"}

  defp expected_paused_guest_verdict(%{unreported: :error}),
    do: {:unknown, "runtime_state_query_failed"}

  defp expected_paused_guest_verdict(%{unreported: :some}),
    do: {:unknown, "runtime_state_not_reported"}

  defp expected_paused_guest_verdict(%{fresh: :some, paused: :zero, unreported: :zero}),
    do: {:healthy, "no_paused_guests"}

  defp expected_paused_guest_verdict(_guests), do: {:unknown, "paused_guest_state_unknown"}
end
