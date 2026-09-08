defmodule ServiceRadar.Plugins.PluginArtifactMirrorTest do
  @moduledoc """
  Unit tests for the plugin WASM object-storage mirror (no channel/DB): the
  injected upload function captures the metadata so we can assert the key,
  sha256, size, content-type, and attributes without a datasvc connection.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Plugins.PluginArtifactMirror, as: Mirror

  defp sha(data), do: :sha256 |> :crypto.hash(data) |> Base.encode16(case: :lower)

  describe "mirror/3" do
    test "uploads under the exact canonical key and returns it, carrying sha256 + attributes" do
      test_pid = self()

      upload_object = fn metadata, data, _opts ->
        send(test_pid, {:uploaded, metadata, byte_size(data)})
        {:ok, :stored}
      end

      key = "plugins/proxmox-console/0.1.2/6a768177-935a-4f9f-8a1f-0841c5651db7.wasm"
      data = "wasm-bytes"

      assert {:ok, ^key} =
               Mirror.mirror(key, data,
                 upload_object: upload_object,
                 attributes: %{
                   "plugin_id" => "proxmox-console",
                   "version" => "0.1.2",
                   "package_id" => "6a768177-935a-4f9f-8a1f-0841c5651db7"
                 }
               )

      assert_received {:uploaded, metadata, size}
      assert metadata.key == key
      assert metadata.sha256 == sha(data)
      assert metadata.total_size == byte_size(data)
      assert size == byte_size(data)
      assert metadata.content_type == "application/wasm"
      assert metadata.attributes["plugin_id"] == "proxmox-console"
      assert metadata.attributes["version"] == "0.1.2"
      assert metadata.attributes["package_id"] == "6a768177-935a-4f9f-8a1f-0841c5651db7"
      assert metadata.attributes["distribution_backend"] == "datasvc_object_store"
    end

    test "propagates an upload error and does not fabricate a key" do
      assert {:error, :boom} =
               Mirror.mirror("plugins/x/1.0.0/pkg.wasm", "data",
                 upload_object: fn _m, _d, _o -> {:error, :boom} end
               )
    end

    test "rejects a blank key without calling upload" do
      test_pid = self()

      upload_object = fn _m, _d, _o ->
        send(test_pid, :should_not_run)
        {:ok, :stored}
      end

      assert {:error, :invalid_key} = Mirror.mirror("   ", "data", upload_object: upload_object)
      refute_received :should_not_run
    end
  end

  describe "object_key/3" do
    test "produces the plugins/<id>/<version>/<package_id>.wasm shape" do
      assert Mirror.object_key("proxmox-console", "0.1.2", "abc") ==
               "plugins/proxmox-console/0.1.2/abc.wasm"
    end

    test "keeps crafted segments from adding path components or traversal" do
      key = Mirror.object_key("../../etc", "v/../1", "ab/cd")
      parts = String.split(key, "/")

      # Fixed shape: plugins / plugin_id / version / <package_id>.wasm.
      assert length(parts) == 4
      assert hd(parts) == "plugins"
      refute Enum.any?(parts, &(&1 in [".", ".."]))
    end

    test "neutralizes an all-dots segment to a non-traversal token" do
      assert Mirror.object_key("..", "1.0.0", "pkg") == "plugins/_/1.0.0/pkg.wasm"
    end
  end
end
