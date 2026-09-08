defmodule ServiceRadarWebNG.TempArchiveTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.TempArchive

  test "creates a gzipped tarball from in-memory files" do
    assert {:ok, tarball} =
             TempArchive.create_tar_gz("serviceradar-test", [
               {"bundle/file.txt", "hello"},
               {"bundle/other.txt", "world"}
             ])

    assert is_binary(tarball)
    assert byte_size(tarball) > 0

    assert {:ok, files} = :erl_tar.extract({:binary, tarball}, [:compressed, :memory])

    contents =
      Map.new(files, fn {path, content} ->
        {List.to_string(path), IO.iodata_to_binary(content)}
      end)

    assert contents["bundle/file.txt"] == "hello"
    assert contents["bundle/other.txt"] == "world"
  end
end
