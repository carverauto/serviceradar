defmodule ServiceRadar.Inventory.AdvisoryFeeds.UbuntuAdapterTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.AdvisoryFeeds.Parsers.Ubuntu
  alias ServiceRadar.Inventory.AdvisoryFeeds.UbuntuAdapter

  @moduletag :tmp_dir
  @fixtures Path.expand("../../../support/fixtures/advisory_feeds/ubuntu", __DIR__)
  @osv_digest String.duplicate("a", 64)
  @vex_digest String.duplicate("b", 64)

  test "compact pair helper must be an absolute regular executable" do
    acquired = %{
      osv_path: "/tmp/osv.tar.xz",
      vex_path: "/tmp/vex.tar.xz",
      prepared_dir: "/tmp/prepared"
    }

    assert {:error, :helper_must_be_absolute} =
             UbuntuAdapter.prepare_pair(acquired, helper: "ubuntu-feed-merge")
  end

  test "v2 packet replay validates projected records and the self-accounting terminal", %{
    tmp_dir: tmp_dir
  } do
    acquired = acquired(tmp_dir)
    manifest = manifest_fixture()
    record = projected_fixture()
    record_frame = record_payload(record)
    terminal_frame = terminal_payload(record, manifest)

    {helper, helper_args_prefix} =
      helper!(tmp_dir, packet(record_frame) <> packet(terminal_frame))

    assert {:ok, snapshot} =
             UbuntuAdapter.prepare_pair(acquired,
               helper: helper,
               helper_args_prefix: helper_args_prefix,
               runner: manifest_runner(manifest)
             )

    assert snapshot.completeness.source_objects_seen == 1
    assert snapshot.completeness.validation["projection"]["version"] == 2

    assert [{:ok, %{advisory: %{cve_id: "CVE-2099-424242"}, assertions: assertions}}] =
             Enum.to_list(snapshot.records)

    assert Enum.find(assertions, &(&1.source_kind == "ubuntu_osv")).raw["archive_sha256"] ==
             @osv_digest

    assert Enum.find(assertions, &(&1.source_kind == "ubuntu_openvex")).raw[
             "archive_sha256"
           ] == @vex_digest
  end

  test "packet replay requires exactly one terminal followed by exit zero", %{tmp_dir: tmp_dir} do
    acquired = acquired(tmp_dir)
    manifest = manifest_fixture()
    record = projected_fixture()
    record_frame = record_payload(record)
    terminal_frame = terminal_payload(record, manifest)

    {no_terminal, no_terminal_prefix} = helper!(tmp_dir, packet(record_frame), "no-terminal")

    assert {:ok, incomplete} =
             UbuntuAdapter.prepare_pair(acquired,
               helper: no_terminal,
               helper_args_prefix: no_terminal_prefix,
               runner: manifest_runner(manifest)
             )

    assert_raise RuntimeError, ~r/exited before complete terminal frame/, fn ->
      Enum.to_list(incomplete.records)
    end

    {post_terminal, post_terminal_prefix} =
      helper!(
        tmp_dir,
        packet(record_frame) <> packet(terminal_frame) <> packet(record_frame),
        "post-terminal"
      )

    assert {:ok, invalid} =
             UbuntuAdapter.prepare_pair(
               %{acquired | prepared_dir: Path.join(tmp_dir, "prepared-post-terminal")},
               helper: post_terminal,
               helper_args_prefix: post_terminal_prefix,
               runner: manifest_runner(manifest)
             )

    assert_raise RuntimeError, ~r/protocol violation/, fn -> Enum.to_list(invalid.records) end
  end

  test "packet replay rejects projection and terminal tampering", %{tmp_dir: tmp_dir} do
    acquired = acquired(tmp_dir)
    manifest = manifest_fixture()
    record = projected_fixture()
    terminal = terminal_map(record, manifest)

    bad_record = Map.put(record, "projection_digest", String.duplicate("0", 64))

    {bad_projection, bad_projection_prefix} =
      helper!(
        tmp_dir,
        packet(record_payload(bad_record)) <> packet(control_payload(terminal)),
        "bad-projection"
      )

    assert {:ok, invalid_projection} =
             UbuntuAdapter.prepare_pair(acquired,
               helper: bad_projection,
               helper_args_prefix: bad_projection_prefix,
               runner: manifest_runner(manifest)
             )

    assert_raise RuntimeError, ~r/invalid Ubuntu projection frame/, fn ->
      Enum.to_list(invalid_projection.records)
    end

    bad_terminal = %{terminal | "assertion_count" => terminal["assertion_count"] + 1}

    {bad_control, bad_control_prefix} =
      helper!(
        tmp_dir,
        packet(record_payload(record)) <> packet(control_payload(bad_terminal)),
        "bad-control"
      )

    assert {:ok, invalid_control} =
             UbuntuAdapter.prepare_pair(
               %{acquired | prepared_dir: Path.join(tmp_dir, "prepared-bad-control")},
               helper: bad_control,
               helper_args_prefix: bad_control_prefix,
               runner: manifest_runner(manifest)
             )

    assert_raise RuntimeError, ~r/terminal mismatch/, fn ->
      Enum.to_list(invalid_control.records)
    end
  end

  test "packet replay fails on helper timeout and nonzero exit", %{tmp_dir: tmp_dir} do
    acquired = acquired(tmp_dir)
    manifest = manifest_fixture()
    {slow, slow_prefix} = script_helper!(tmp_dir, "Process.sleep(1_000)\n", "slow")

    assert {:ok, timed} =
             UbuntuAdapter.prepare_pair(acquired,
               helper: slow,
               helper_args_prefix: slow_prefix,
               runner: manifest_runner(manifest),
               port_timeout_ms: 10
             )

    assert_raise RuntimeError, ~r/timed out/, fn -> Enum.to_list(timed.records) end

    {failing, failing_prefix} = script_helper!(tmp_dir, "System.halt(7)\n", "nonzero")

    assert {:ok, failed} =
             UbuntuAdapter.prepare_pair(
               %{acquired | prepared_dir: Path.join(tmp_dir, "prepared-nonzero")},
               helper: failing,
               helper_args_prefix: failing_prefix,
               runner: manifest_runner(manifest)
             )

    assert_raise RuntimeError, ~r/exited before complete terminal frame: 7/, fn ->
      Enum.to_list(failed.records)
    end
  end

  test "prepared manifest is v2, bounded, self-accounting, and tied to acquired archives", %{
    tmp_dir: tmp_dir
  } do
    acquired = acquired(tmp_dir)
    manifest = manifest_fixture()
    {helper, prefix} = helper!(tmp_dir, "", "unused")

    invalid_manifests = [
      Map.put(manifest, :projection_version, 1),
      put_in(manifest, [:osv, :archive_sha256], String.duplicate("c", 64)),
      put_in(manifest, [:vex, :refs], [%{cve: "not-a-cve"}]),
      Map.update!(manifest, :work_bytes, &(&1 + 1)),
      Map.put(manifest, :peak_work_bytes, manifest.work_limit_bytes + 1)
    ]

    Enum.with_index(invalid_manifests, fn invalid, index ->
      assert {:error, _reason} =
               UbuntuAdapter.prepare_pair(
                 %{acquired | prepared_dir: Path.join(tmp_dir, "prepared-invalid-#{index}")},
                 helper: helper,
                 helper_args_prefix: prefix,
                 runner: manifest_runner(invalid)
               )
    end)
  end

  defp acquired(tmp_dir) do
    osv_path = Path.join(tmp_dir, "osv.tar.xz")
    vex_path = Path.join(tmp_dir, "vex.tar.xz")
    File.write!(osv_path, "o")
    File.write!(vex_path, "v")

    %{
      osv_path: osv_path,
      vex_path: vex_path,
      prepared_dir: Path.join(tmp_dir, "prepared"),
      artifacts: %{
        osv: %{sha256: @osv_digest, bytes: 1},
        vex: %{sha256: @vex_digest, bytes: 1}
      }
    }
  end

  defp projected_fixture do
    @fixtures
    |> Path.join("projected_record_v2.json")
    |> File.read!()
    |> Jason.decode!()
  end

  defp manifest_fixture do
    base = %{
      version: 2,
      projection_version: 2,
      osv: inventory("osv", "osv.spool", @osv_digest),
      vex: inventory("vex", "vex.spool", @vex_digest),
      input_bytes: 2,
      work_bytes: 0,
      peak_work_bytes: 0,
      work_limit_bytes: 1_073_741_824
    }

    converge_manifest(base)
  end

  defp inventory(kind, spool, digest) do
    %{
      kind: kind,
      spool: spool,
      refs: [%{cve: "CVE-2099-424242"}],
      count: 1,
      members: 1,
      total: 1,
      archive_bytes: 1,
      archive_sha256: digest,
      spool_bytes: byte_size("fixture"),
      initial_runs: 1,
      merge_passes: 0
    }
  end

  defp converge_manifest(manifest) do
    encoded = Jason.encode!(manifest)
    work_bytes = manifest.input_bytes + manifest.osv.spool_bytes + manifest.vex.spool_bytes
    next = %{manifest | work_bytes: work_bytes + byte_size(encoded)}
    next = %{next | peak_work_bytes: next.work_bytes}

    if next == manifest, do: manifest, else: converge_manifest(next)
  end

  defp manifest_runner(manifest) do
    fn _helper, args, _opts ->
      dir = List.last(args)
      File.mkdir!(dir)
      File.write!(Path.join(dir, "osv.spool"), "fixture")
      File.write!(Path.join(dir, "vex.spool"), "fixture")
      File.write!(Path.join(dir, "manifest.json"), Jason.encode!(manifest))
      {"", 0}
    end
  end

  defp record_payload(projected), do: <<1, Jason.encode!(projected)::binary>>

  defp terminal_payload(projected, manifest),
    do: projected |> terminal_map(manifest) |> control_payload()

  defp terminal_map(projected, manifest) do
    {:ok, _record, context, counters} =
      Ubuntu.validate_record(projected,
        source_digests: %{osv: @osv_digest, vex: @vex_digest}
      )

    base = %{
      "protocol_version" => 2,
      "cve_count" => 1,
      "record_count" => 1,
      "osv_document_count" => counters.osv_documents,
      "vex_document_count" => counters.vex_documents,
      "osv_count" => manifest.osv.count,
      "vex_count" => manifest.vex.count,
      "withdrawn_document_count" => counters.withdrawn_documents,
      "vex_tombstone_count" => counters.vex_tombstones,
      "osv_affected_entry_count" => counters.osv_affected_entries,
      "vex_statement_count" => counters.vex_statements,
      "logical_product_occurrence_count" => counters.logical_product_occurrences,
      "unique_product_count" => map_size(context.products),
      "unique_product_set_count" => map_size(context.product_sets),
      "assertion_count" => counters.assertions,
      "unscoped_product_count" => counters.unscoped_products,
      "repaired_source_purl_count" => counters.repaired_source_purls,
      "emitted_bytes" => 0,
      "emitted_frame_count" => 2,
      "max_frame_bytes" => 0,
      "osv_members" => manifest.osv.members,
      "vex_members" => manifest.vex.members,
      "osv_spool_bytes" => manifest.osv.spool_bytes,
      "vex_spool_bytes" => manifest.vex.spool_bytes,
      "peak_work_bytes" => manifest.peak_work_bytes
    }

    record_frame_bytes = byte_size(record_payload(projected))
    converge_terminal(base, 4 + record_frame_bytes, record_frame_bytes)
  end

  defp converge_terminal(terminal, prior_bytes, prior_max) do
    terminal_bytes = 1 + byte_size(Jason.encode!(terminal))

    next =
      terminal
      |> Map.put("emitted_bytes", prior_bytes + 4 + terminal_bytes)
      |> Map.put("max_frame_bytes", max(prior_max, terminal_bytes))

    if next == terminal, do: terminal, else: converge_terminal(next, prior_bytes, prior_max)
  end

  defp control_payload(terminal), do: <<2, Jason.encode!(terminal)::binary>>
  defp packet(payload), do: <<byte_size(payload)::32-big, payload::binary>>

  defp helper!(tmp_dir, output, suffix \\ "ok") do
    script_helper!(
      tmp_dir,
      ":io.setopts(:standard_io, encoding: :latin1)\n" <>
        "Base.decode64!(\"#{Base.encode64(output)}\") |> IO.binwrite()\n",
      suffix
    )
  end

  defp script_helper!(tmp_dir, body, suffix) do
    path = Path.join(tmp_dir, "helper-#{suffix}.exs")

    File.write!(path, "#!/usr/bin/env elixir\n" <> body)
    File.chmod!(path, 0o755)

    {path, []}
  end
end
