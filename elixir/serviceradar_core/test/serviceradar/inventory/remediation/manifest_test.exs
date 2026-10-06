defmodule ServiceRadar.Inventory.Remediation.ManifestTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.Remediation.Manifest

  defmodule BatchProbeWriter do
    @moduledoc false

    def write_batch(_device, entries) do
      send(self(), {:manifest_batch, entries})
      :ok
    end
  end

  test "open never truncates an existing rollback manifest" do
    path =
      Path.join(
        System.tmp_dir!(),
        "dire_manifest_existing_#{System.unique_integer([:positive])}.ndjson"
      )

    original = ~s({"existing":"rollback evidence"}\n)
    File.write!(path, original, [:exclusive])
    on_exit(fn -> File.rm(path) end)

    assert_raise File.Error, fn -> Manifest.open(path, %{test: "must_not_overwrite"}) end
    assert File.read!(path) == original
  end

  test "record_batch sends every exact entry to one writer call" do
    manifest = %Manifest{device: :probe, writer: BatchProbeWriter}

    assert :ok =
             Manifest.record_batch(manifest, :armis_unmerge, [
               %{action: :create_device, table: "platform.ocsf_devices", ids: ["device-1"]},
               %{
                 action: :create_merge_audit,
                 table: "platform.merge_audit",
                 ids: ["audit-1"],
                 extra: %{phase: "prepared"}
               }
             ])

    assert_receive {:manifest_batch, [device_entry, audit_entry]}
    assert device_entry.action == "create_device"
    assert device_entry.ids == ["device-1"]
    assert audit_entry.action == "create_merge_audit"
    assert audit_entry.ids == ["audit-1"]
    assert audit_entry.phase == "prepared"
    refute_receive {:manifest_batch, _}
  end

  describe "read/1" do
    test "reads back the header and entries a run wrote, with the run's started_at" do
      path = manifest_path()
      manifest = Manifest.open(path, %{mode: "execute", steps: ["source-id-retire"]})

      assert :ok =
               Manifest.record(manifest, "source-id-retire", "retire_source_ids", "t", [7, 8], %{
                 device_id: "device-1"
               })

      assert :ok = Manifest.record(manifest, "source-id-retire", "mark_source_retired", "t", [9])
      Manifest.close(manifest)

      assert {:ok, header, [retire, mark]} = Manifest.read(path)
      assert %{"manifest" => "dire_remediation", "version" => 1, "mode" => "execute"} = header
      assert Manifest.started_at(header) == {:ok, manifest.started_at}

      assert %{"action" => "retire_source_ids", "ids" => [7, 8], "device_id" => "device-1"} =
               retire

      assert %{"step" => "source-id-retire", "action" => "mark_source_retired", "ids" => [9]} =
               mark
    end

    test "drops a last line cut short, which never committed" do
      path = write!(header_line() <> ~s({"action":"retire_source_ids","ids":[1]}\n{"action":"re))

      assert {:ok, _header, [%{"ids" => [1]}]} = Manifest.read(path)
    end

    test "refuses a line that is not a JSON object before the last" do
      path = write!(header_line() <> ~s({"ids":[1}\n{"ids":[2]}\n))

      assert Manifest.read(path) == {:error, {:invalid_manifest_line, 2}}
    end

    test "refuses a complete last line that is not a JSON object" do
      path = write!(header_line() <> ~s([1]\n))

      assert Manifest.read(path) == {:error, {:invalid_manifest_line, 2}}
    end

    test "refuses a file that is not a remediation manifest" do
      path = write!(~s({"manifest":"something_else","version":1}\n{"ids":[1]}\n))
      assert Manifest.read(path) == {:error, :not_a_remediation_manifest}

      path = write!(~s({"manifest":"dire_remediation","version":2}\n))
      assert Manifest.read(path) == {:error, :not_a_remediation_manifest}
    end

    test "refuses an empty or missing file" do
      path = write!("")
      assert Manifest.read(path) == {:error, {:manifest_empty, path}}

      missing = manifest_path()
      assert Manifest.read(missing) == {:error, {:manifest_unreadable, missing, :enoent}}
    end
  end

  test "started_at/1 parses the header's time and refuses a missing or invalid one" do
    assert Manifest.started_at(%{"started_at" => "2026-01-02T03:04:05.000006Z"}) ==
             {:ok, ~U[2026-01-02 03:04:05.000006Z]}

    assert Manifest.started_at(%{}) == {:error, :manifest_started_at_missing}
    assert Manifest.started_at(%{"started_at" => 5}) == {:error, :manifest_started_at_missing}

    assert {:error, {:invalid_manifest_started_at, _reason}} =
             Manifest.started_at(%{"started_at" => "yesterday"})
  end

  defp header_line,
    do: ~s({"manifest":"dire_remediation","version":1,"started_at":"2026-01-02T03:04:05Z"}\n)

  defp manifest_path do
    path =
      Path.join(
        System.tmp_dir!(),
        "dire_manifest_read_#{System.unique_integer([:positive])}.ndjson"
      )

    on_exit(fn -> File.rm(path) end)
    path
  end

  defp write!(contents) do
    path = manifest_path()
    File.write!(path, contents, [:exclusive])
    path
  end
end
