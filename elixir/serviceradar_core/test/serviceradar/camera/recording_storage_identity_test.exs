defmodule ServiceRadar.Camera.RecordingStorageIdentityTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Camera.RecordingStorageIdentity, as: StorageIdentity

  @first "00000000-0000-4000-8000-000000000011"
  @second "00000000-0000-4000-8000-000000000012"

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "storage-identity-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, path: Path.join(root, "identities.json")}
  end

  test "accepts projected files and selects each member independently", %{root: root, path: path} do
    File.write!(path, Jason.encode!(document()))
    projected = Path.join(root, "projected.json")
    File.ln_s!(path, projected)

    assert StorageIdentity.resolve!(nil, projected, "camera-core-0") == @first
    assert StorageIdentity.resolve!(nil, projected, "camera-core-1") == @second

    assert_raise ArgumentError, ~r/member_not_installed/, fn ->
      StorageIdentity.resolve!(nil, projected, "camera-core-2")
    end
  end

  test "rejects duplicate keys and reused volume identities", %{path: path} do
    for bytes <- [
          ~s({"version":1,"version":1,"members":{"camera-core-0":"#{@first}"}}),
          ~s({"version":1,"members":{"camera-core-0":"#{@first}","camera-core-0":"#{@second}"}}),
          ~s({"version":1,"members":{"camera-core-0":"#{@first}","camera-core-1":"#{@first}"}})
        ] do
      assert_raise ArgumentError, ~r/invalid_document_or_member/, fn ->
        resolve_document(path, bytes)
      end
    end
  end

  test "validates the whole versioned mapping, including unselected members", %{path: path} do
    for invalid <- [
          %{},
          %{"version" => 2, "members" => document()["members"]},
          Map.put(document(), "extra", true),
          %{"version" => 1, "members" => %{}},
          %{"version" => 1, "members" => []},
          put_in(document(), ["members", "camera-core-1"], "not-a-uuid"),
          put_in(
            document(),
            ["members", "camera-core-1"],
            "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
          ),
          put_in(document(), ["members", "camera-core-1"], nil),
          put_in(document(), ["members", "../other"], "00000000-0000-4000-8000-000000000013")
        ] do
      assert_raise ArgumentError, ~r/invalid_document_or_member/, fn ->
        resolve_document(path, Jason.encode!(invalid))
      end
    end

    assert_raise ArgumentError, ~r/invalid_document_or_member/, fn ->
      resolve_document(path, "{incomplete")
    end
  end

  test "enforces byte and member budgets at their boundaries", %{path: path} do
    members =
      Map.new(0..255, fn n ->
        {"camera-core-#{n}",
         "00000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(n), 12, "0")}
      end)

    bytes = Jason.encode!(%{"version" => 1, "members" => members})
    padded = bytes <> String.duplicate(" ", 65_536 - byte_size(bytes))
    File.write!(path, padded)

    assert StorageIdentity.resolve!(nil, path, "camera-core-0") ==
             "00000000-0000-4000-8000-000000000000"

    assert_raise ArgumentError, ~r/invalid_document_or_member/, fn ->
      resolve_document(path, padded <> " ")
    end

    oversized = Map.put(members, "camera-core-256", "00000000-0000-4000-8000-000000000256")

    assert_raise ArgumentError, ~r/invalid_document_or_member/, fn ->
      resolve_document(path, Jason.encode!(%{"version" => 1, "members" => oversized}))
    end
  end

  test "refuses absent, empty and nonregular files", %{root: root, path: path} do
    for source <- [path, root, ""] do
      assert_raise ArgumentError, ~r/invalid_document_or_member/, fn ->
        StorageIdentity.resolve!(nil, source, "camera-core-0")
      end
    end

    assert_raise ArgumentError, ~r/invalid_document_or_member/, fn ->
      resolve_document(path, "")
    end
  end

  test "requires both document settings and refuses a scalar fallback", %{path: path} do
    File.write!(path, Jason.encode!(document()))

    for {scalar, file, member} <- [
          {nil, path, nil},
          {nil, nil, "camera-core-0"},
          {@first, nil, "camera-core-0"},
          {@first, path, "camera-core-0"},
          {"", path, "camera-core-0"},
          {nil, path, ""}
        ] do
      assert_raise ArgumentError, fn -> StorageIdentity.resolve!(scalar, file, member) end
    end
  end

  defp resolve_document(path, bytes) do
    File.write!(path, bytes)
    StorageIdentity.resolve!(nil, path, "camera-core-0")
  end

  defp document,
    do: %{"version" => 1, "members" => %{"camera-core-0" => @first, "camera-core-1" => @second}}
end
