defmodule ServiceRadar.Inventory.Remediation.ManifestTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.Remediation.Manifest

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
end
