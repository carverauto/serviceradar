defmodule ServiceRadar.Inventory.Availability.EvidencePlanTest do
  @moduledoc """
  Owner of the evidence write rules (design Decisions 2, 4 and 7): the class comes from
  the registration and can only be lowered, up-only classes never record `down`, and a
  stored record is rewritten only for a decision-bearing change or a due lease.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.Availability.EvidencePlan
  alias ServiceRadar.Inventory.Availability.Sources

  @now ~U[2026-10-19 12:00:00.000000Z]
  @device "sr:00000000-0000-4000-8000-0000000000a1"

  defp source(kind) do
    {:ok, source} = Sources.fetch(kind)
    source
  end

  defp submission(overrides) do
    Map.merge(
      %{device_uid: @device, state: :up, observed_at: @now, source_instance: "SITE01-wlc"},
      Map.new(overrides)
    )
  end

  defp row(kind \\ "wifi_map", overrides \\ []) do
    {:ok, row} = EvidencePlan.build(submission(overrides), source(kind), @now)
    row
  end

  describe "build/3" do
    test "takes the class from the registration and lets an instance only lower it" do
      assert row().authority_class == "managing_controller"

      assert row("wifi_map", instance_class: :inventory_declared).authority_class ==
               "inventory_declared"

      assert row("mapper", instance_class: :operator_policy).authority_class ==
               "passive_observation"
    end

    test "rejects down from an up-only class and anything unregistered or malformed" do
      assert {:error, :up_only_class} =
               EvidencePlan.build(submission(state: :down), source("agent_liveness"), @now)

      assert {:error, :invalid_state} =
               EvidencePlan.build(submission(state: :unknown), source("wifi_map"), @now)

      assert {:error, :invalid_instance_class} =
               EvidencePlan.build(
                 submission(instance_class: "controller"),
                 source("wifi_map"),
                 @now
               )

      assert Sources.fetch("wifi") == :error
    end

    test "bounds the lease and the observation time by the registration" do
      wifi = source("wifi_map")
      future = DateTime.shift(@now, minute: 10)

      assert %{observed_at: @now} = row("wifi_map", observed_at: future)

      assert DateTime.diff(row("wifi_map", ttl_seconds: 1).expires_at, @now) == wifi.min_ttl
      assert DateTime.diff(row().expires_at, @now) == wifi.default_ttl

      long_ago = DateTime.shift(@now, second: -10 * wifi.max_ttl)

      assert DateTime.diff(@now, row("wifi_map", observed_at: long_ago).observed_at) ==
               wifi.max_ttl

      assert row("wifi_map", detail: %{"raw" => String.duplicate("x", 4_096)}).detail == %{
               "truncated" => true
             }
    end
  end

  describe "merge/3" do
    # The stored record was observed at @now with the default 3 h lease.
    defp stored, do: row()

    # Observed `seconds` after the stored record, and built at that time.
    defp later(seconds, overrides \\ []) do
      at = DateTime.shift(@now, second: seconds)
      submission = submission(Keyword.put(overrides, :observed_at, at))
      {:ok, row} = EvidencePlan.build(submission, source("wifi_map"), at)
      row
    end

    test "decides when to rewrite the stored record" do
      cases = [
        {"no stored record", nil, row(), :write},
        {"steady observation inside the lease", stored(), later(600), :skip},
        {"steady observation with less than half the lease left", stored(), later(5_500), :write},
        {"a replayed older observation", later(600), stored(), :skip},
        {"a state change", stored(), later(60, state: :down), :write},
        {"an eligibility change", stored(), later(60, reporter_eligible: false), :write},
        {"a lowered class", stored(), later(60, instance_class: :inventory_declared), :write},
        {"a shorter lease", stored(), later(60, ttl_seconds: 600), :write}
      ]

      for {name, existing, incoming, expected} <- cases do
        decision = existing |> EvidencePlan.merge(incoming, incoming.observed_at) |> decision()
        assert {name, decision} == {name, expected}
      end
    end

    test "keeps when the current state began while it holds, and restarts it on a change" do
      steady = later(5_500)
      assert {:write, renewed} = EvidencePlan.merge(stored(), steady, steady.observed_at)
      assert renewed.state_since == @now
      assert renewed.confirmations == 1

      flipped = later(60, state: :down)
      assert {:write, changed} = EvidencePlan.merge(stored(), flipped, flipped.observed_at)
      assert changed.state_since == flipped.observed_at
    end
  end

  describe "merge/3 coalesced flips (review finding R5)" do
    test "marks a flip to down observed within half a lease of the stored up, and only that" do
      key = EvidencePlan.coalesced_flip_key()
      stored_up = row()

      inside = later(60, state: :down)
      assert {:write, marked} = EvidencePlan.merge(stored_up, inside, inside.observed_at)

      assert marked.detail[key] == %{
               "previous_up_observed_at" => DateTime.to_iso8601(stored_up.observed_at)
             }

      # Half of the 3 h lease is 5 400 s.
      outside = later(5_460, state: :down)
      assert {:write, unmarked} = EvidencePlan.merge(stored_up, outside, outside.observed_at)
      refute Map.has_key?(unmarked.detail, key)

      recovery = later(120)
      assert {:write, recovered} = EvidencePlan.merge(marked, recovery, recovery.observed_at)
      refute Map.has_key?(recovered.detail, key)
    end
  end

  defp decision({:write, _row}), do: :write
  defp decision(:skip), do: :skip
end
