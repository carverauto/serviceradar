defmodule ServiceRadar.Plugins.NativeAddonArtifactMirrorTest do
  @moduledoc """
  Unit tests for the native add-on object-storage mirror (no channel/DB): the
  injected upload function captures the metadata so we can assert the key,
  sha256, size, and attributes without a datasvc connection.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Plugins.NativeAddonArtifactMirror, as: Mirror

  defp sha(data), do: :sha256 |> :crypto.hash(data) |> Base.encode16(case: :lower)

  describe "mirror_fun/3" do
    test "uploads under a deterministic key and returns it, carrying sha256 + attributes" do
      test_pid = self()

      upload_object = fn metadata, data, _opts ->
        send(test_pid, {:uploaded, metadata, byte_size(data)})
        {:ok, :stored}
      end

      mirror = Mirror.mirror_fun("netprobe", "0.1.0", upload_object: upload_object)
      data = "tarball-amd64-bytes"
      expected_sha = sha(data)

      assert {:ok, key} = mirror.("linux", "amd64", data)
      assert key == "native-addons/netprobe/0.1.0/linux/amd64/#{expected_sha}.tar.gz"

      assert_received {:uploaded, metadata, size}
      assert metadata.key == key
      assert metadata.sha256 == expected_sha
      assert metadata.total_size == byte_size(data)
      assert size == byte_size(data)
      assert metadata.content_type == "application/gzip"
      assert metadata.attributes["addon_id"] == "netprobe"
      assert metadata.attributes["version"] == "0.1.0"
      assert metadata.attributes["os"] == "linux"
      assert metadata.attributes["arch"] == "amd64"
    end

    test "propagates an upload error and does not fabricate a key" do
      mirror =
        Mirror.mirror_fun("x", "1.0.0", upload_object: fn _m, _d, _o -> {:error, :boom} end)

      assert {:error, :boom} = mirror.("linux", "arm64", "data")
    end
  end

  describe "object_key/5" do
    test "is stable for the same inputs" do
      assert Mirror.object_key("a", "1.0.0", "linux", "amd64", "deadbeef") ==
               Mirror.object_key("a", "1.0.0", "linux", "amd64", "deadbeef")
    end

    test "keeps crafted segments from adding path components or traversal" do
      key = Mirror.object_key("../../etc", "v/../1", "li/nux", "am/d64", "ab/cd")
      parts = String.split(key, "/")

      # Fixed shape: native-addons / addon / version / os / arch / <sha>.tar.gz.
      assert length(parts) == 6
      assert hd(parts) == "native-addons"
      # No segment is a traversal component, so the key can't escape the prefix.
      refute Enum.any?(parts, &(&1 in [".", ".."]))
    end

    test "neutralizes an all-dots segment to a non-traversal token" do
      key = Mirror.object_key("..", "1.0.0", "linux", "amd64", "deadbeef")
      assert key == "native-addons/_/1.0.0/linux/amd64/deadbeef.tar.gz"
    end
  end
end
