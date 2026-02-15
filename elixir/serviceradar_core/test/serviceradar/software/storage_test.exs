defmodule ServiceRadar.Software.StorageTest do
  @moduledoc """
  Unit tests for the Software.Storage module (local filesystem backend).

  These tests don't require a database — they operate on temp directories.
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.Software.Storage

  @moduletag :unit

  setup do
    # Create a temp directory for each test
    tmp_dir = Path.join(System.tmp_dir!(), "storage_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    # Configure local storage to use the temp directory
    prev = Application.get_env(:serviceradar_core, :software_storage)
    Application.put_env(:serviceradar_core, :software_storage, mode: :local, local_path: tmp_dir)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)

      if prev do
        Application.put_env(:serviceradar_core, :software_storage, prev)
      else
        Application.delete_env(:serviceradar_core, :software_storage)
      end
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  describe "put/2" do
    test "stores a file in local storage", %{tmp_dir: tmp_dir} do
      # Create a source file
      source = Path.join(tmp_dir, "source.bin")
      File.write!(source, "hello world")

      assert {:ok, "images/test.bin"} = Storage.put("images/test.bin", source)

      # Verify the file exists at the expected path
      stored_path = Path.join(tmp_dir, "images/test.bin")
      assert File.exists?(stored_path)
      assert File.read!(stored_path) == "hello world"
    end

    test "creates nested directories", %{tmp_dir: tmp_dir} do
      source = Path.join(tmp_dir, "source.bin")
      File.write!(source, "data")

      assert {:ok, _} = Storage.put("a/b/c/deep.bin", source)
      assert File.exists?(Path.join(tmp_dir, "a/b/c/deep.bin"))
    end

    test "returns error for missing source file" do
      assert {:error, :enoent} = Storage.put("test.bin", "/nonexistent/file.bin")
    end
  end

  describe "get/2" do
    test "retrieves a stored file", %{tmp_dir: tmp_dir} do
      # Manually place a file in storage
      File.mkdir_p!(Path.join(tmp_dir, "images"))
      File.write!(Path.join(tmp_dir, "images/firmware.bin"), "firmware data")

      dest = Path.join(tmp_dir, "retrieved.bin")
      assert :ok = Storage.get("images/firmware.bin", dest)
      assert File.read!(dest) == "firmware data"
    end

    test "returns error for missing file", %{tmp_dir: tmp_dir} do
      dest = Path.join(tmp_dir, "nope.bin")
      assert {:error, :enoent} = Storage.get("nonexistent.bin", dest)
    end
  end

  describe "delete/1" do
    test "deletes a stored file", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "to_delete.bin")
      File.write!(file_path, "delete me")

      assert :ok = Storage.delete("to_delete.bin")
      refute File.exists?(file_path)
    end

    test "succeeds for already-deleted file" do
      assert :ok = Storage.delete("already_gone.bin")
    end
  end

  describe "list/1" do
    test "lists all files", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "images"))
      File.write!(Path.join(tmp_dir, "images/a.bin"), "a")
      File.write!(Path.join(tmp_dir, "images/b.bin"), "b")
      File.write!(Path.join(tmp_dir, "config.txt"), "c")

      assert {:ok, files} = Storage.list()
      assert length(files) == 3
      assert "images/a.bin" in files
      assert "images/b.bin" in files
      assert "config.txt" in files
    end

    test "lists files with prefix", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "images"))
      File.mkdir_p!(Path.join(tmp_dir, "backups"))
      File.write!(Path.join(tmp_dir, "images/a.bin"), "a")
      File.write!(Path.join(tmp_dir, "backups/b.bin"), "b")

      assert {:ok, files} = Storage.list("images")
      assert length(files) == 1
      assert "images/a.bin" in files
    end

    test "returns empty list for nonexistent prefix", %{tmp_dir: _tmp_dir} do
      assert {:ok, []} = Storage.list("nonexistent")
    end

    test "returns empty list when storage dir doesn't exist" do
      Application.put_env(:serviceradar_core, :software_storage,
        mode: :local,
        local_path: "/tmp/nonexistent_storage_#{System.unique_integer([:positive])}"
      )

      assert {:ok, []} = Storage.list()
    end
  end

  describe "sha256/1" do
    test "computes correct SHA-256 hash", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "hash_test.bin")
      File.write!(file_path, "hello")

      expected =
        :crypto.hash(:sha256, "hello")
        |> Base.encode16(case: :lower)

      assert {:ok, ^expected} = Storage.sha256(file_path)
    end

    test "returns error for missing file" do
      assert {:error, :enoent} = Storage.sha256("/nonexistent/file.bin")
    end
  end

  describe "verify_hash/2" do
    test "succeeds when hash matches", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "verify.bin")
      File.write!(file_path, "content")

      {:ok, hash} = Storage.sha256(file_path)
      assert :ok = Storage.verify_hash(file_path, hash)
    end

    test "fails when hash doesn't match", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "verify.bin")
      File.write!(file_path, "content")

      assert {:error, :hash_mismatch} = Storage.verify_hash(file_path, "0000000000000000")
    end
  end

  describe "round-trip" do
    test "put then get preserves file content", %{tmp_dir: tmp_dir} do
      content = :crypto.strong_rand_bytes(1024)
      source = Path.join(tmp_dir, "source.bin")
      File.write!(source, content)

      assert {:ok, _} = Storage.put("round_trip.bin", source)

      dest = Path.join(tmp_dir, "dest.bin")
      assert :ok = Storage.get("round_trip.bin", dest)
      assert File.read!(dest) == content
    end
  end
end
