defmodule ServiceRadar.EventWriter.ExposureRecoveryTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.EventWriter.ExposureRecovery
  alias ServiceRadar.TestSupport.ExposureBroker

  @moduletag :db_free
  @moduletag :tmp_dir

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
