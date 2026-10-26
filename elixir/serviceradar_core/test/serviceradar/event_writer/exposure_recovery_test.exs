defmodule ServiceRadar.EventWriter.ExposureRecoveryTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.EventWriter.ExposureRecovery
  alias ServiceRadar.EventWriter.ExposureSnapshotEnvelope, as: Snapshot
  alias ServiceRadar.TestSupport.ExposureBroker

  @moduletag :db_free
  @moduletag :tmp_dir

  test "snapshot envelopes bind their contents and order, and retain one immutable page", ctx do
    generation = %{"id" => 1, "scope" => nil, "snapshot" => "10:20:12"}
    records = Enum.map(1..500, &%{"ordinal" => &1, "value" => String.duplicate("x", 1_100)})

    assert {:ok, pages} =
             Snapshot.split(generation, "cve", Snapshot.empty_receipt(), "dimensions", records)

    assert length(pages) == 2
    assert Enum.flat_map(pages, fn {page, _, _} -> page["records"] end) == records
    [{first, body, hash}, {last, _, last_hash}] = pages
    assert byte_size(body) <= 512 * 1024

    assert {:error, :exposure_snapshot_receipt_conflict} =
             Snapshot.advance(Snapshot.empty_receipt(), last, last_hash)

    assert {:ok, receipt} = Snapshot.advance(Snapshot.empty_receipt(), first, hash)
    assert {:ok, ^receipt} = Snapshot.advance(receipt, first, hash)
    assert {:ok, %{"count" => 500, "page" => 2}} = Snapshot.advance(receipt, last, last_hash)
    corrupted = body |> Jason.decode!() |> Map.put("count", 1) |> Snapshot.canonical()
    assert {:error, :invalid_exposure_snapshot_envelope} = Snapshot.decode(corrupted)

    assert {:error, :exposure_snapshot_record_too_large} =
             Snapshot.split(generation, "cve", Snapshot.empty_receipt(), "dimensions", [
               %{"value" => String.duplicate("x", 524_288)}
             ])

    ExposureBroker.with_broker(ctx.tmp_dir, fn _conn, _port ->
      subject = Snapshot.subject(1, "cve", 1)
      assert {:ok, position} = ExposureRecovery.retain_envelope(subject, body, hash)
      assert {:ok, ^position, ^body} = ExposureRecovery.fetch_envelope(subject, hash)
      assert {:ok, ^position} = ExposureRecovery.retain_envelope(subject, body, hash)
      {:ok, changed, changed_hash} = Snapshot.encode(Map.put(first, "scope", 8))

      assert {:error, :exposure_recovery_content_conflict} =
               ExposureRecovery.retain_envelope(subject, changed, changed_hash)

      assert :ok = ExposureRecovery.delete(position)
    end)
  end

  test "retained bytes survive repeat publication and reject conflicting operation content",
       ctx do
    ExposureBroker.with_broker(ctx.tmp_dir, fn conn, _port ->
      id = Ecto.UUID.generate()
      entries = [entry(1, "original")]
      {:ok, body, hash} = ExposureRecovery.encode(3, id, entries)
      assert {:ok, position} = ExposureRecovery.retain(3, id, body, hash)
      assert {:ok, ^position} = ExposureRecovery.retain(3, id, body, hash)
      assert {:ok, ^position, ^entries} = ExposureRecovery.fetch(3, id, hash)

      {:ok, changed, changed_hash} = ExposureRecovery.encode(3, id, [entry(1, "changed")])

      assert {:error, :exposure_recovery_content_conflict} =
               ExposureRecovery.retain(3, id, changed, changed_hash)

      assert {:ok, ^position, ^entries} = ExposureRecovery.fetch(3, id, hash)

      %{"config" => config} =
        ExposureBroker.request(conn, "$JS.API.STREAM.INFO.EXPOSURE_RECOVERY", %{})

      assert config["max_age"] == 0
      assert config["max_bytes"] == 64 * 1024 * 1024

      assert %{"error" => _} =
               ExposureBroker.request(conn, "$JS.API.STREAM.PURGE.EXPOSURE_RECOVERY", %{})

      assert :ok = ExposureRecovery.delete(position)
      assert :ok = ExposureRecovery.delete(position)
      assert :missing = ExposureRecovery.fetch(3, id, hash)
    end)
  end

  test "a refused deletion leaves the exact retained bytes in place", ctx do
    ExposureBroker.with_broker(ctx.tmp_dir, fn conn, _port ->
      id = Ecto.UUID.generate()
      entries = [entry(1, "keep")]
      {:ok, body, hash} = ExposureRecovery.encode(3, id, entries)
      assert {:ok, position} = ExposureRecovery.retain(3, id, body, hash)

      %{"config" => config} =
        ExposureBroker.request(conn, "$JS.API.STREAM.INFO.EXPOSURE_RECOVERY", %{})

      updated =
        ExposureBroker.request(
          conn,
          "$JS.API.STREAM.UPDATE.EXPOSURE_RECOVERY",
          Map.put(config, "deny_delete", true)
        )

      assert updated["config"]["deny_delete"] == true

      assert {:error, {:exposure_recovery_cleanup, _}} = ExposureRecovery.delete(position)

      assert %{"message" => %{"seq" => ^position, "data" => data}} =
               ExposureBroker.request(conn, "$JS.API.STREAM.MSG.GET.EXPOSURE_RECOVERY", %{
                 seq: position
               })

      assert Base.decode64!(data) == body
      assert {:ok, ^position, ^entries} = ExposureRecovery.fetch(3, id, hash)
    end)
  end

  test "a full stream preserves an unfinished batch and cleanup restores progress", ctx do
    ExposureBroker.with_broker(ctx.tmp_dir, fn conn, _port ->
      entries = [entry(1, String.duplicate("x", 510_000))]
      id = Ecto.UUID.generate()
      {:ok, body, hash} = ExposureRecovery.encode(3, id, entries)
      assert {:ok, position} = ExposureRecovery.retain(3, id, body, hash)

      full? =
        Enum.reduce_while(1..150, false, fn n, _ ->
          {:ok, %{body: reply}} = Gnat.request(conn, "exposure.delivery.recovery.fill.#{n}", body)

          case Jason.decode!(reply) do
            %{"error" => _} -> {:halt, true}
            %{"seq" => seq} when seq > 0 -> {:cont, false}
          end
        end)

      assert full?, "stream never enforced its byte ceiling"
      next = Ecto.UUID.generate()
      {:ok, next_body, next_hash} = ExposureRecovery.encode(3, next, entries)
      assert {:error, _} = ExposureRecovery.retain(3, next, next_body, next_hash)
      assert {:ok, ^position, ^entries} = ExposureRecovery.fetch(3, id, hash)
      assert :ok = ExposureRecovery.delete(position)
      assert {:ok, _} = ExposureRecovery.retain(3, next, next_body, next_hash)
    end)
  end

  test "admission splits on both record and encoded byte bounds and rejects an oversized record" do
    assert {:ok, [first, last]} = ExposureRecovery.split(Enum.map(1..501, &entry(&1, "small")))
    assert length(first) == 500
    assert [entry] = last
    assert elem(entry, 0) == 501

    assert {:ok, [[_], [_]]} =
             ExposureRecovery.split([
               entry(1, String.duplicate("x", 300_000)),
               entry(2, String.duplicate("x", 300_000))
             ])

    assert {:error, :exposure_recovery_record_too_large} =
             ExposureRecovery.split([entry(1, String.duplicate("x", 524_288))])
  end

  defp entry(seq, data),
    do: {seq, %{data: data, metadata: %{subject: "vulnerability.assessment.transitions.3"}}}
end
