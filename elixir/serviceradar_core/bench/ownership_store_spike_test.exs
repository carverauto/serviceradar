defmodule ServiceRadar.Bench.OwnershipStoreSpikeTest do
  @moduledoc """
  A synthetic memory floor for the streaming-attribution Phase 0 ETS proposal.

  This is an experiment, not the production shard. It measures packed keys,
  32-byte validity intervals, and an interned owner table in a fresh test VM.
  The layouts deliberately omit expiry, snapshot membership, address-presence
  indexes, owner reclamation and concurrency. The printed `memory_floor_gate`
  is the capacity verdict, and this test passes when the corpus checks pass.
  The Phase 0 preflight in
  `openspec/changes/stream-flow-attribution-via-ownership-index/design.md`
  owns that verdict.

  All workloads are invented. The mixed profile has 90% depth 1, 9% depth 4,
  and 1% depth 32. A reuse stress profile has 70% depth 1, 25% depth 4, and 5%
  depth 32. All intervals fit within a 15-minute horizon. Neither is a lab distribution.
  """
  use ExUnit.Case, async: false

  @moduletag timeout: 600_000
  @batch_size 1_000
  @lookup_count 100_000

  test "measure packed ETS histories against the memory floor" do
    count = System.get_env("OWNERSHIP_SPIKE_KEYS", "25000") |> String.to_integer()
    assert count >= 100 and rem(count, 100) == 0

    IO.puts("ownership_spike otp=#{System.otp_release()} keys=#{count} synthetic=true")

    profile =
      Map.fetch!(
        %{"single" => :single, "mixed" => :mixed, "reuse" => :reuse},
        System.fetch_env!("OWNERSHIP_SPIKE_PROFILE")
      )

    measure(profile, count)
  end

  defp measure(profile, count) do
    :erlang.garbage_collect()
    before = :erlang.memory()
    keys = :ets.new(:keys, [:set, :private])
    owners = :ets.new(:owners, [:set, :private])
    owner_ids = :ets.new(:owner_ids, [:set, :private])
    owner_count = div(count + 127, 128)

    try do
      Enum.each(1..owner_count, fn id ->
        owner = owner(id)
        :ets.insert(owners, {id, owner})
        :ets.insert(owner_ids, {owner, id})
      end)

      {apply_us, :ok} =
        :timer.tc(fn ->
          Enum.each(1..count, fn id ->
            :ets.insert(keys, {key(id), history(id, depth(profile, id), owner_count)})
          end)
        end)

      # Ref-counted binary payloads do not live in the ETS word accounting.
      # Count each history and each interned owner once, even though two tables
      # reference the owner. The known payload is a floor on the VM-wide delta.
      binary_payload = binary_payload(keys) + binary_payload(owners)
      :erlang.garbage_collect()
      after_load = :erlang.memory()
      ets_words = Enum.sum(for table <- [keys, owners, owner_ids], do: :ets.info(table, :memory))
      ets_bytes = ets_words * :erlang.system_info(:wordsize)
      binary_growth = max(after_load[:binary] - before[:binary], binary_payload)
      vm_growth = max(after_load[:total] - before[:total], 0)
      bytes_per_key = (ets_bytes + binary_growth) / count

      # These controls catch an empty, colliding or truncated benchmark corpus.
      assert :ets.info(keys, :size) == count
      assert :ets.info(owners, :size) == owner_count
      assert :ets.info(owner_ids, :size) == owner_count
      assert lookup(keys, key(count), -15) == owner_id(count, 0, owner_count)
      assert lookup(keys, key(count), 2_000) == :not_found
      assert lookup(keys, key(count + 1), -15) == :not_found

      if profile in [:mixed, :reuse] do
        assert lookup(keys, key(99), -55) == owner_id(99, 1, owner_count)
        assert lookup(keys, key(99), -795) == owner_id(99, 31, owner_count)
        assert lookup(keys, key(99), -850) == :not_found
      end

      {lookup_us, hits} =
        :timer.tc(fn ->
          1..@lookup_count
          |> Stream.chunk_every(@batch_size)
          |> Enum.reduce(0, fn batch, hits ->
            requests = Enum.map(batch, fn n -> key(rem(n * 104_729, count) + 1) end)
            hits + Enum.count(requests, &(lookup(keys, &1, -15) != :not_found))
          end)
        end)

      assert hits == @lookup_count
      histogram = Enum.frequencies_by(1..count, &depth(profile, &1))

      IO.puts(
        "ownership_spike_result " <>
          "profile=#{profile} keys=#{count} owners=#{owner_count} " <>
          "depths=#{inspect(histogram)} ets_bytes=#{ets_bytes} binary_growth=#{binary_growth} " <>
          "binary_payload=#{binary_payload} " <>
          "vm_growth=#{vm_growth} bytes_per_key=#{Float.round(bytes_per_key, 1)} " <>
          "memory_floor_gate=#{if bytes_per_key <= 200, do: "within", else: "exceeded"} " <>
          "apply_rows_per_s=#{rate(count, apply_us)} " <>
          "lookup_keys_per_s=#{rate(@lookup_count, lookup_us)} " <>
          "lookup_batch=#{@batch_size} full_shard_gate=unmeasured"
      )
    after
      Enum.each([keys, owners, owner_ids], &:ets.delete/1)
      :erlang.garbage_collect()
    end
  end

  # 80% endpoint, 15% exact-peer, 5% relaxed-peer. Partition 1 is synthetic.
  # Each address is under 2001:db8::/32; the id makes every key distinct.
  defp key(id) do
    local = <<0x20010DB8::32, id::96>>
    remote = <<0x20010DB8::32, 1::32, id::64>>
    port = 10_000 + rem(id, 50_000)

    case rem(id, 20) do
      n when n < 16 -> <<0, 1::32, 6, local::binary, port::16>>
      n when n < 19 -> <<1, 1::32, 6, local::binary, port::16, remote::binary, 443::16>>
      _ -> <<2, 1::32, 17, local::binary, remote::binary, 443::16>>
    end
  end

  defp depth(:single, _id), do: 1
  defp depth(:mixed, id) when rem(id, 100) < 90, do: 1
  defp depth(:mixed, id) when rem(id, 100) < 99, do: 4
  defp depth(:mixed, _id), do: 32
  defp depth(:reuse, id) when rem(id, 100) < 70, do: 1
  defp depth(:reuse, id) when rem(id, 100) < 95, do: 4
  defp depth(:reuse, _id), do: 32

  defp history(id, depth, owner_count) do
    for offset <- 0..(depth - 1), into: <<>> do
      first = -30 - offset * 25
      finish = if offset == 0, do: 1_800, else: first + 25
      owner = owner_id(id, offset, owner_count)
      <<first::signed-64, finish::signed-64, owner::32, 0::32, id::64>>
    end
  end

  defp lookup(table, key, time) do
    case :ets.lookup(table, key) do
      [{^key, history}] -> lookup_interval(history, time)
      [] -> :not_found
    end
  end

  defp lookup_interval(<<>>, _time), do: :not_found

  defp lookup_interval(
         <<first::signed-64, finish::signed-64, owner::32, _flags::32, _lease::64, rest::binary>>,
         time
       ) do
    if first <= time and time < finish, do: owner, else: lookup_interval(rest, time)
  end

  defp owner_id(id, offset, owner_count), do: rem(div(id - 1, 128) + offset, owner_count) + 1

  defp owner(id) do
    :erlang.term_to_binary(
      {"synthetic-agent-#{div(id, 16)}", id, 1_000, "synthetic-service",
       "synthetic-service " <> String.duplicate("x", 238), "synthetic-container-#{id}",
       "synthetic-workload-#{id}",
       {:resolved, "synthetic-package", "1.0.0", "/usr/bin/synthetic-service", id}}
    )
  end

  defp binary_payload(table) do
    :ets.foldl(
      fn {_key, value}, bytes ->
        if byte_size(value) > 64, do: bytes + byte_size(value), else: bytes
      end,
      0,
      table
    )
  end

  defp rate(count, microseconds), do: round(count * 1_000_000 / max(microseconds, 1))
end

