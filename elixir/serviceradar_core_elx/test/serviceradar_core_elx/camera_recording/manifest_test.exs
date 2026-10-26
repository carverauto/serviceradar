defmodule ServiceRadarCoreElx.CameraRecording.ManifestTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Camera.RecordingDescriptor
  alias ServiceRadar.Camera.RecordingManifest, as: Manifest
  alias ServiceRadarCoreElx.CameraRecording.Spool
  alias ServiceRadarCoreElx.CameraRecording.Storage

  @identity %{
    source_id: "00000000-0000-4000-8000-000000000037",
    profile: "invented-main",
    recorder_epoch: 3,
    block_sequence: 8,
    clock: %{clock_epoch: "invented-clock", timebase: 90_000, dts_source: :pts_no_reordering, utc_mapping: :unknown}
  }
  @receipts %{init: %{etag: ~s("invented-init")}, media: %{version_id: "invented-version"}}
  # Independently calculated from the invented v1 JSON fields in this fixture,
  # sorted by key with no whitespace. Pins wire bytes, including null receipts.
  @manifest_sha256 "5ce6ca5b1221647c1fc485860885fce041d0fbc4952582c5d653accf0bce1d67"
  @block_key "a5a5a38bcfbd45c06b6e518631ba078562e446bd32ecff9f6918b00aacc6012c"

  setup do
    root = Path.join(System.tmp_dir!(), "recording-manifest-#{System.unique_integer([:positive, :monotonic])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    # Invented storage bytes; the media and browser suites own decodability.
    {:ok, storage} = Storage.initialize(root, Ecto.UUID.generate())
    {:ok, spool} = Spool.create(storage, @identity, "invented-init")
    {:ok, spool, _} = Spool.append(spool, "abc", %{start_ns: 0, duration_ns: 2_000_000_000})

    {:ok, spool, _} =
      Spool.append(spool, "defgh", %{
        start_ns: 2_000_000_000,
        duration_ns: 1_000_000_000,
        tail_duration_source: :previous_sample
      })

    open = Spool.snapshot(spool)
    {:ok, spool} = Spool.seal(spool)
    {:ok, recovered} = Spool.recover(storage, Spool.snapshot(spool).directory, @identity)
    snapshot = Spool.snapshot(recovered)

    format = %{
      sha256: snapshot.init["sha256"],
      timescale: 90_000,
      codecs: %{avc1: %{profile: 66, compatibility: 192, level: 10}}
    }

    {:ok, descriptor} = RecordingDescriptor.from_snapshot(snapshot, format)
    persisted = descriptor |> Jason.encode!() |> Jason.decode!()

    %{open: open, snapshot: snapshot, format: format, descriptor: persisted}
  end

  test "recovered committed ranges produce a portable deterministic recovery manifest", ctx do
    assert {:ok, bytes} = Manifest.encode(ctx.snapshot, ctx.format, @receipts)
    assert {:ok, manifest} = Manifest.decode(bytes, ctx.snapshot.identity)
    assert manifest["format"] == %{"codec" => "avc1.42c00a", "timescale" => 90_000}
    assert manifest["media"]["length"] == 8
    assert manifest["media"]["sha256"] == Base.encode16(:crypto.hash(:sha256, "abcdefgh"), case: :lower)
    assert manifest["identity"]["clock"]["utc_mapping"] == "unknown"

    assert Enum.map(manifest["fragments"], &{&1["offset"], &1["length"], &1["motion"]}) ==
             [{0, 3, "unknown"}, {3, 5, "unknown"}]

    assert List.last(manifest["fragments"])["tail_duration_source"] == "previous_sample"
    refute Map.has_key?(manifest, "directory")
    assert String.starts_with?(manifest["media"]["key"], "recordings/v1/")
    assert String.ends_with?(manifest["media"]["key"], "/media.m4s")

    moved = %{ctx.snapshot | directory: "/invented/unavailable/node"}
    assert {:ok, ^bytes} = Manifest.encode(moved, ctx.format, @receipts)
    changed_clock = put_in(moved.identity["clock"]["clock_epoch"], "another-invented-clock")
    assert {:ok, changed_bytes} = Manifest.encode(changed_clock, ctx.format, @receipts)
    changed = Jason.decode!(changed_bytes)
    assert changed["media"]["key"] == manifest["media"]["key"]
    assert {:error, :invalid_manifest} = Manifest.decode(changed_bytes, ctx.snapshot.identity)

    next_epoch = put_in(moved.identity["recorder_epoch"], 4)
    assert {:ok, next_bytes} = Manifest.encode(next_epoch, ctx.format, @receipts)
    refute Jason.decode!(next_bytes)["media"]["key"] == manifest["media"]["key"]
  end

  test "persisted descriptors preserve v1 bytes, identity and receipts without a live packager", ctx do
    expected_identity = @identity |> Jason.encode!() |> Jason.decode!()
    assert {:ok, bytes} = Manifest.encode_descriptor(ctx.descriptor, @receipts)
    assert {:ok, ^bytes} = Manifest.encode(ctx.snapshot, ctx.format, @receipts)
    assert Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == @manifest_sha256
    manifest = Jason.decode!(bytes)
    assert manifest["identity"] == expected_identity
    assert manifest["init"]["key"] == "recordings/v1/#{@block_key}/init.mp4"
    assert manifest["media"]["key"] == "recordings/v1/#{@block_key}/media.m4s"
    assert manifest["init"]["etag"] == ~s("invented-init")
    assert manifest["init"]["version_id"] == nil
    assert manifest["media"]["etag"] == nil
    assert manifest["media"]["version_id"] == "invented-version"
  end

  test "open blocks, mismatched init descriptors and unbound storage identities are refused", ctx do
    assert {:error, :invalid_manifest} = Manifest.encode(ctx.open, ctx.format, @receipts)

    assert {:error, :invalid_manifest} =
             Manifest.encode(ctx.snapshot, %{ctx.format | sha256: String.duplicate("0", 64)}, @receipts)

    assert {:error, :invalid_manifest} = Manifest.encode(ctx.snapshot, ctx.format, %{init: %{}, media: %{}})

    assert {:error, :invalid_manifest} =
             Manifest.encode(ctx.snapshot, ctx.format, put_in(@receipts.media.version_id, "null"))

    assert {:error, :invalid_manifest} =
             Manifest.encode(ctx.snapshot, ctx.format, put_in(@receipts.init.etag, ~s(W/"weak")))

    assert {:error, :invalid_manifest} =
             Manifest.encode(ctx.snapshot, ctx.format, put_in(@receipts.init.etag, "\"unsafe\"\n"))

    format = ctx.format

    assert {:error, :invalid_manifest} =
             Manifest.encode(ctx.snapshot, put_in(format.codecs.avc1.profile, 100), @receipts)

    for receipts <- [
          nil,
          %{},
          %{init: nil, media: []},
          %{init: %{}, media: %{}},
          put_in(@receipts.media.version_id, "null"),
          put_in(@receipts.media.version_id, String.duplicate("v", 1025)),
          put_in(@receipts.init.etag, ~s(W/"weak")),
          put_in(@receipts.init.etag, "\"unsafe\"\n")
        ] do
      assert {:error, :invalid_manifest} = Manifest.encode_descriptor(ctx.descriptor, receipts)
    end

    # Validate before decorating: a receipt must not erase an invalid input key.
    descriptor = ctx.descriptor

    for invalid <- [
          put_in(descriptor["init"]["key"], "invented-foreign-key"),
          nil,
          [],
          %{},
          Map.delete(descriptor, "init"),
          put_in(descriptor["media"], nil),
          put_in(descriptor["fragments"], [nil]),
          put_in(descriptor["version"], 2),
          Map.put(descriptor, "authorization", "invented-claim"),
          put_in(descriptor["format"]["codec"], "avc1.64000a"),
          put_in(descriptor["identity"]["clock"]["utc_mapping"], %{})
        ] do
      assert {:error, :invalid_manifest} = Manifest.encode_descriptor(invalid, @receipts)
    end
  end

  test "recovery rejects unsupported schemas, substituted paths and inconsistent fragment maps", ctx do
    {:ok, bytes} = Manifest.encode(ctx.snapshot, ctx.format, @receipts)
    manifest = Jason.decode!(bytes)

    assert {:error, :unsupported_manifest_version} =
             Manifest.decode(Jason.encode!(%{manifest | "version" => 2}), ctx.snapshot.identity)

    mutations = [
      put_in(manifest["media"]["key"], "https://example.invalid/foreign-object"),
      put_in(manifest["media"]["key"], nil),
      put_in(manifest["media"]["length"], 9),
      put_in(manifest["media"]["sha256"], manifest["media"]["sha256"] <> "\n"),
      Map.put(manifest, "authorization", "invented-claim"),
      update_in(manifest["fragments"], &Enum.reverse/1),
      update_in(manifest["fragments"], fn [first, last] -> [first, %{last | "offset" => 2}] end),
      update_in(manifest["fragments"], fn [first, last] -> [first, %{last | "start_ns" => 3_000_000_000}] end),
      update_in(manifest["fragments"], fn [first, last] -> [first, Map.put(last, "extra", true)] end),
      update_in(manifest["fragments"], fn [first, last] -> [first, %{last | "motion" => "none"}] end)
    ]

    for invalid <- mutations do
      assert {:error, :invalid_manifest} = Manifest.decode(Jason.encode!(invalid), ctx.snapshot.identity)
    end

    assert {:error, :invalid_manifest} = Manifest.decode(bytes, %{})
    assert {:error, :invalid_manifest} = Manifest.decode(bytes <> String.duplicate(" ", 2_097_152), ctx.snapshot.identity)
  end

  test "remote metadata must obey fragment count, byte and time bounds independently of local spool admission", ctx do
    {:ok, bytes} = Manifest.encode(ctx.snapshot, ctx.format, @receipts)
    manifest = Jason.decode!(bytes)
    first = hd(manifest["fragments"])

    # Keep every other field internally consistent so another validation rule
    # cannot mask a missing bound on metadata recovered from an archive.
    single = %{
      manifest
      | "fragments" => [first],
        "media" => %{manifest["media"] | "length" => first["length"], "sha256" => first["sha256"]}
    }

    assert {:ok, _} = Manifest.decode(Jason.encode!(single), ctx.snapshot.identity)

    excessive =
      Enum.map(0..4096, fn sequence ->
        %{first | "sequence" => sequence, "offset" => sequence, "length" => 1, "start_ns" => sequence, "duration_ns" => 1}
      end)

    mutations = [
      %{single | "fragments" => []},
      %{single | "fragments" => excessive, "media" => %{single["media"] | "length" => 4097}},
      %{
        single
        | "fragments" => [%{first | "length" => 33_554_433}],
          "media" => %{single["media"] | "length" => 33_554_433}
      },
      %{single | "fragments" => [%{first | "duration_ns" => 0}]},
      %{single | "fragments" => [%{first | "duration_ns" => -1}]},
      %{single | "fragments" => [%{first | "duration_ns" => 60_000_000_001}]},
      %{single | "fragments" => [%{first | "start_ns" => 9_223_372_036_854_775_807, "duration_ns" => 1}]}
    ]

    for invalid <- mutations do
      assert {:error, :invalid_manifest} = Manifest.decode(Jason.encode!(invalid), ctx.snapshot.identity)

      descriptor =
        invalid
        |> Map.update!("init", &Map.take(&1, ~w(length sha256)))
        |> Map.update!("media", &Map.take(&1, ~w(length sha256)))

      assert {:error, :invalid_manifest} = Manifest.encode_descriptor(descriptor, @receipts)
    end
  end
end
