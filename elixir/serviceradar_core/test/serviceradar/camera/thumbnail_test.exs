defmodule ServiceRadar.Camera.ThumbnailTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.RecordingCatalogEntry
  alias ServiceRadar.Camera.Thumbnail

  @camera_id "11111111-1111-4111-8111-111111111111"
  @entry_id "33333333-3333-4333-8333-333333333333"
  @system_actor SystemActor.system(:camera_thumbnail_test)

  @valid_jpeg <<0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, "JFIF", 0x00, 0x01, 0x01, 0x00, 0xFF, 0xD9>>

  describe "JPEG validation and base64 decoding" do
    test "accepts nil, valid JPEGs, and exact 64 KiB boundary" do
      assert {:ok, nil} = Thumbnail.validate_jpeg(nil)
      assert {:ok, @valid_jpeg} = Thumbnail.validate_jpeg(@valid_jpeg)
      assert Thumbnail.valid_jpeg?(@valid_jpeg)

      max_jpeg = <<0xFF, 0xD8>> <> :binary.copy(<<0x00>>, 65_532) <> <<0xFF, 0xD9>>
      assert byte_size(max_jpeg) == Thumbnail.max_bytes()
      assert {:ok, ^max_jpeg} = Thumbnail.validate_jpeg(max_jpeg)
      assert Thumbnail.valid_jpeg?(max_jpeg)
    end

    test "rejects oversize JPEGs (> 64 KiB) and non-JPEG bytes" do
      oversize_jpeg = <<0xFF, 0xD8>> <> :binary.copy(<<0x00>>, 65_533) <> <<0xFF, 0xD9>>
      assert byte_size(oversize_jpeg) == Thumbnail.max_bytes() + 1
      assert {:error, :thumbnail_too_large} = Thumbnail.validate_jpeg(oversize_jpeg)
      refute Thumbnail.valid_jpeg?(oversize_jpeg)

      for bad <- [
            "",
            <<0xFF, 0xD8, 0xFF>>,
            <<0x89, "PNG\r\n", 0x1A, "\n", 0xFF, 0xD9>>,
            <<0xFF, 0xD8, 0x00, 0x00>>,
            "not-a-jpeg",
            123
          ] do
        assert {:error, :invalid_thumbnail_jpeg} = Thumbnail.validate_jpeg(bad)
        refute Thumbnail.valid_jpeg?(bad)
      end
    end

    test "decodes and validates optional base64 JPEGs" do
      assert {:ok, nil} = Thumbnail.decode_base64_jpeg(nil)
      assert {:ok, @valid_jpeg} = Thumbnail.decode_base64_jpeg(Base.encode64(@valid_jpeg))
      assert {:error, :invalid_thumbnail_jpeg} = Thumbnail.decode_base64_jpeg("")
      assert {:error, :invalid_thumbnail_jpeg} = Thumbnail.decode_base64_jpeg("%%%not-b64%%%")

      assert {:error, :invalid_thumbnail_jpeg} =
               Thumbnail.decode_base64_jpeg(Base.encode64("plain text"))

      oversize_jpeg = <<0xFF, 0xD8>> <> :binary.copy(<<0x00>>, 65_533) <> <<0xFF, 0xD9>>

      assert {:error, :thumbnail_too_large} =
               Thumbnail.decode_base64_jpeg(Base.encode64(oversize_jpeg))
    end
  end

  describe "Ash changeset validation" do
    test "validates thumbnail_jpeg on RecordingCatalogEntry :set_thumbnail" do
      entry = struct(RecordingCatalogEntry, id: @entry_id)

      ok_update =
        Ash.Changeset.for_update(entry, :set_thumbnail, %{thumbnail_jpeg: @valid_jpeg},
          actor: @system_actor
        )

      assert ok_update.valid?

      clear_update =
        Ash.Changeset.for_update(entry, :set_thumbnail, %{thumbnail_jpeg: nil},
          actor: @system_actor
        )

      assert clear_update.valid?

      oversize = <<0xFF, 0xD8>> <> :binary.copy(<<0x00>>, 65_533) <> <<0xFF, 0xD9>>

      bad_size =
        Ash.Changeset.for_update(entry, :set_thumbnail, %{thumbnail_jpeg: oversize},
          actor: @system_actor
        )

      refute bad_size.valid?
      assert Enum.any?(bad_size.errors, &(&1.field == :thumbnail_jpeg))

      bad_magic =
        Ash.Changeset.for_update(entry, :set_thumbnail, %{thumbnail_jpeg: "PNGDATA"},
          actor: @system_actor
        )

      refute bad_magic.valid?
      assert Enum.any?(bad_magic.errors, &(&1.field == :thumbnail_jpeg))
    end
  end

  describe "fetch_for_camera/3 input validation" do
    test "rejects invalid camera UUID, kind, or record UUID before querying" do
      assert {:error, :invalid_camera_source_id} =
               Thumbnail.fetch_for_camera("not-a-uuid", :block, @entry_id)

      assert {:error, :invalid_id} =
               Thumbnail.fetch_for_camera(@camera_id, "unknown", @entry_id)

      assert {:error, :invalid_id} =
               Thumbnail.fetch_for_camera(@camera_id, "frame", @entry_id)

      assert {:error, :invalid_id} =
               Thumbnail.fetch_for_camera(@camera_id, :block, "not-a-uuid")
    end
  end
end
