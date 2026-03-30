defmodule ServiceRadarCoreElx.CameraRelay.SecureTempCaptureTest do
  use ExUnit.Case, async: true

  alias ServiceRadarCoreElx.CameraRelay.SecureTempCapture

  test "allocates capture paths under the managed temp root" do
    path = SecureTempCapture.allocate_path!("secure-temp-capture-test", ".h264")

    assert String.starts_with?(Path.expand(path), Path.expand(SecureTempCapture.base_dir()) <> "/")
    refute File.exists?(path)
    assert File.dir?(Path.dirname(path))

    assert :ok = SecureTempCapture.cleanup_path(path)
    refute File.exists?(path)
    refute File.exists?(Path.dirname(path))
  end

  test "writes payload files and removes them after the callback" do
    payload = <<0, 1, 2, 3, 4>>
    path_holder = self()

    result =
      SecureTempCapture.with_payload_file("secure-temp-capture-test", payload, ".h264", fn path ->
        send(path_holder, {:temp_path, path})
        assert {:ok, ^payload} = File.read(path)
        :decoded
      end)

    assert result == :decoded

    assert_receive {:temp_path, path}
    refute File.exists?(path)
    refute File.exists?(Path.dirname(path))
  end
end
