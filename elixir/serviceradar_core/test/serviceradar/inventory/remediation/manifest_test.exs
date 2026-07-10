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
end
