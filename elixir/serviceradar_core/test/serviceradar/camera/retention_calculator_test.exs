defmodule ServiceRadar.Camera.RetentionCalculatorTest do
  use ExUnit.Case, async: true

  alias Ash.Error.Forbidden
  alias ServiceRadar.Camera.RecordingArchiveSettings
  alias ServiceRadar.Camera.RetentionCalculator

  @gb 1_000_000_000
  @rel_tol 1.0e-6

  describe "calculate_object_retention/2 F5 published test vectors V1-V6" do
    test "satisfies vectors V1 through V6 within 1e-6 relative tolerance" do
      # V1: one policy rate 108 GB/day, ret 30; available 400 GB -> T = 3.703704, binds capacity
      v1 =
        RetentionCalculator.calculate_object_retention(
          [%{id: "p1", rate_bytes_per_day: 108 * @gb, retention_days: 30}],
          %{available_bytes: 400 * @gb}
        )

      assert_rel_close(v1.capacity_days, 3.703704)
      [v1_p] = v1.policies
      assert_rel_close(v1_p.effective_days, 3.703704)
      assert v1_p.binding_bound == :capacity
      assert v1.archiving_paused? == false

      # V2: as V1 with available 1,600 GB -> T = 14.814815, binds capacity
      v2 =
        RetentionCalculator.calculate_object_retention(
          [%{id: "p1", rate_bytes_per_day: 108 * @gb, retention_days: 30}],
          %{available_bytes: 1_600 * @gb}
        )

      assert_rel_close(v2.capacity_days, 14.814815)
      [v2_p] = v2.policies
      assert_rel_close(v2_p.effective_days, 14.814815)
      assert v2_p.binding_bound == :capacity

      # V3: A: rate 50 GB/day, ret 7; B: rate 20 GB/day, ret 60; available 1,000 GB
      # -> T = 32.5; A effective 7 (time); B effective 32.5 (capacity)
      v3 =
        RetentionCalculator.calculate_object_retention(
          [
            %{id: "A", rate_bytes_per_day: 50 * @gb, retention_days: 7},
            %{id: "B", rate_bytes_per_day: 20 * @gb, retention_days: 60}
          ],
          %{available_bytes: 1_000 * @gb}
        )

      assert_rel_close(v3.capacity_days, 32.5)
      [v3_a, v3_b] = v3.policies
      assert v3_a.id == "A"
      assert v3_a.effective_days == 7
      assert v3_a.binding_bound == :time
      assert v3_b.id == "B"
      assert_rel_close(v3_b.effective_days, 32.5)
      assert v3_b.binding_bound == :capacity

      # V4: one policy rate 10 GB/day, ret 30; available 1,000 GB -> T infinite; effective 30; binds time
      v4 =
        RetentionCalculator.calculate_object_retention(
          [%{id: "p1", rate_bytes_per_day: 10 * @gb, retention_days: 30}],
          %{available_bytes: 1_000 * @gb}
        )

      assert v4.capacity_days == :infinity
      [v4_p] = v4.policies
      assert v4_p.effective_days == 30
      assert v4_p.binding_bound == :time
      assert v4.archiving_paused? == false

      # V5: one policy rate 10 GB/day, ret 30; available 0 (held bytes at low water, below high water)
      # -> T = 0; effective 0; binds capacity; uploads continue until non-reapable reaches high water
      v5 =
        RetentionCalculator.calculate_object_retention(
          [%{id: "p1", rate_bytes_per_day: 10 * @gb, retention_days: 30}],
          %{
            object_budget_mode: :limited,
            hard_limit_bytes: 1_000 * @gb,
            object_low_water_percent: 80,
            object_high_water_percent: 90,
            object_capacity_policy: :reap_oldest,
            non_reapable_bytes: 800 * @gb
          }
        )

      assert v5.available_bytes == 0
      assert v5.capacity_days == 0.0
      [v5_p] = v5.policies
      assert v5_p.effective_days == 0.0
      assert v5_p.binding_bound == :capacity
      assert v5.archiving_paused? == false

      # At object high water (900 GB non-reapable), uploads pause for capacity.
      v5_high =
        RetentionCalculator.calculate_object_retention(
          [%{id: "p1", rate_bytes_per_day: 10 * @gb, retention_days: 30}],
          %{
            object_budget_mode: :limited,
            hard_limit_bytes: 1_000 * @gb,
            object_low_water_percent: 80,
            object_high_water_percent: 90,
            object_capacity_policy: :reap_oldest,
            non_reapable_bytes: 900 * @gb
          }
        )

      assert v5_high.archiving_paused? == true

      # V6: one policy rate 20 GB/day, ret unlimited; available 500 GB -> T = 25; effective 25; binds capacity
      v6 =
        RetentionCalculator.calculate_object_retention(
          [%{id: "p1", rate_bytes_per_day: 20 * @gb, retention_days: :unlimited}],
          %{available_bytes: 500 * @gb}
        )

      assert_rel_close(v6.capacity_days, 25.0)
      [v6_p] = v6.policies
      assert_rel_close(v6_p.effective_days, 25.0)
      assert v6_p.binding_bound == :capacity
    end

    test "unlimited object budget mode and 3-branch C3a days_to_capacity" do
      unlimited =
        RetentionCalculator.calculate_object_retention(
          [
            %{id: "finite", rate_bytes_per_day: 50 * @gb, retention_days: 30},
            %{id: "unlim", rate_bytes_per_day: 20 * @gb, retention_days: :unlimited}
          ],
          %{object_budget_mode: :unlimited}
        )

      assert unlimited.capacity_days == :infinity
      assert unlimited.days_to_capacity == :not_filling
      assert unlimited.archiving_paused? == false

      assert Enum.map(unlimited.policies, &{&1.id, &1.effective_days, &1.binding_bound}) == [
               {"finite", 30, :time},
               {"unlim", :unlimited, :unlimited}
             ]

      # Branch 2: reap_oldest uses (high_water_bytes - non_reapable_bytes) / non_reapable_growth
      assert RetentionCalculator.days_to_capacity(%{
               object_budget_mode: :limited,
               object_capacity_policy: :reap_oldest,
               high_water_bytes: 900 * @gb,
               non_reapable_bytes: 200 * @gb,
               non_reapable_growth_bytes_per_day: 0
             }) == :not_filling

      assert_rel_close(
        RetentionCalculator.days_to_capacity(%{
          object_budget_mode: :limited,
          object_capacity_policy: :reap_oldest,
          high_water_bytes: 900 * @gb,
          non_reapable_bytes: 200 * @gb,
          non_reapable_growth_bytes_per_day: 100 * @gb
        }),
        7.0
      )

      # Branch 3: stop_archiving or nil uses (hard_limit_bytes - usage_bytes) / total_rate
      for policy <- [:stop_archiving, nil] do
        assert_rel_close(
          RetentionCalculator.days_to_capacity(%{
            object_budget_mode: :limited,
            object_capacity_policy: policy,
            hard_limit_bytes: 1_000 * @gb,
            usage_bytes: 250 * @gb,
            total_rate_bytes_per_day: 50 * @gb
          }),
          15.0
        )
      end
    end
  end

  describe "rate_from_history_or_nominal/1 (C3a)" do
    test "uses max(24h, 7d/7) with >= 24h history, 1.02 nominal estimate below 24h, and unknown without bitrate" do
      measured =
        RetentionCalculator.rate_from_history_or_nominal(%{
          history_seconds: 86_400,
          trailing_24h_bytes: 40 * @gb,
          trailing_7d_bytes: 350 * @gb,
          nominal_bitrate_bps: 4_000_000
        })

      assert measured == %{bytes_per_day: 50.0 * @gb, basis: :measured}

      estimated =
        RetentionCalculator.rate_from_history_or_nominal(%{
          history_seconds: 3_600,
          trailing_24h_bytes: 99 * @gb,
          nominal_bitrate_bps: 4_000_000
        })

      assert estimated.basis == :estimated
      assert_rel_close(estimated.bytes_per_day, 4_000_000 * 86_400 / 8.0 * 1.02)

      assert RetentionCalculator.rate_from_history_or_nominal(%{
               history_seconds: 600,
               nominal_bitrate_bps: nil
             }) == %{bytes_per_day: 0.0, basis: :unknown}
    end
  end

  describe "calculate_pinned_bytes/1, calculate_local_window/1, and C5 time_to_full" do
    test "counts holds once across P1, P3, and P4 per design C1a holds table" do
      # Row 1: overwrite_oldest, 8 GB pending (of which 2 GB held) -> 8 GB total, not 10 GB
      r1 =
        RetentionCalculator.calculate_pinned_bytes(%{
          local_only_full_policy: :overwrite_oldest,
          p1_unarchived_bytes: 8 * @gb
        })

      assert r1.total_pinned_bytes == 8 * @gb

      # Row 2: stop_when_full, 20 GB local-only (of which 5 GB held) -> 20 GB total, not 25 GB
      r2 =
        RetentionCalculator.calculate_pinned_bytes(%{
          local_only_full_policy: :stop_when_full,
          kind_b_local_only_bytes: 20 * @gb,
          held_kind_b_bytes: 5 * @gb
        })

      assert r2.p3 == 20 * @gb
      assert r2.p4 == 0
      assert r2.total_pinned_bytes == 20 * @gb

      # Row 3: overwrite_oldest, 5 GB held local-only -> P3 = 0, P4 = 5 GB
      r3 =
        RetentionCalculator.calculate_pinned_bytes(%{
          local_only_full_policy: :overwrite_oldest,
          kind_b_local_only_bytes: 20 * @gb,
          held_kind_b_bytes: 5 * @gb
        })

      assert r3.p3 == 0
      assert r3.p4 == 5 * @gb
      assert r3.total_pinned_bytes == 5 * @gb
    end

    test "reproduces C1a mixed-member window and C5 pinned-growth time-to-full worked examples" do
      # 90.2 GB budget, 72.2 GB low water, 81.2 GB high water; 500 kB/s archived (24h age), 15 kB/s local-only
      base = %{
        effective_budget_bytes: 90_200_000_000,
        low_water_bytes: 72_200_000_000,
        high_water_bytes: 81_200_000_000,
        archived_rate_bytes_per_sec: 500_000,
        local_only_rate_bytes_per_sec: 15_000,
        max_local_age_mode: :limited,
        max_local_age_seconds: 86_400,
        local_only_max_age_mode: :unlimited,
        local_window_alert_mode: :enabled,
        local_window_alert_seconds: 3_600
      }

      # 1. overwrite_oldest, 0 pinned: archived 24h (max_age), local-only ~22.4d..29.3d (budget), not filling
      m_overwrite =
        RetentionCalculator.calculate_local_window(
          Map.merge(base, %{local_only_full_policy: :overwrite_oldest, pinned_bytes: 0})
        )

      assert m_overwrite.kinds.archived.window_low_seconds == 86_400.0
      assert m_overwrite.kinds.archived.binding_bound == :max_age
      assert m_overwrite.kinds.local_only.binding_bound == :budget
      assert_in_delta m_overwrite.kinds.local_only.window_low_seconds / 86_400, 22.376, 0.05
      assert m_overwrite.time_to_full_seconds == :not_filling

      # 2. stop_when_full, 20 GB pinned: archived 24h at both ends, TTF = (90.2 GB - 20 GB) / 15 kB/s ~= 54.17 days
      m_20gb =
        RetentionCalculator.calculate_local_window(
          Map.merge(base, %{local_only_full_policy: :stop_when_full, pinned_bytes: 20 * @gb})
        )

      assert m_20gb.kinds.archived.window_low_seconds == 86_400.0
      assert m_20gb.kinds.archived.window_high_seconds == 86_400.0
      assert m_20gb.kinds.archived.binding_bound == :max_age
      assert m_20gb.kinds.local_only.binding_bound == :pinned
      assert_in_delta m_20gb.time_to_full_seconds / 86_400, 54.166, 0.05
      assert m_20gb.below_window_alert? == false

      # 3. stop_when_full, 75 GB pinned (between low and high water): 0 to ~3.44 h, alert triggered on low=0
      m_75gb =
        RetentionCalculator.calculate_local_window(
          Map.merge(base, %{
            storage_mode: :local_and_archive,
            local_only_full_policy: :stop_when_full,
            pinned_bytes: 75 * @gb
          })
        )

      assert m_75gb.window_low_seconds == 0.0
      assert_in_delta m_75gb.window_high_seconds / 3_600, 3.444, 0.05
      assert m_75gb.below_window_alert? == true

      # 4. stop_when_full, 82.8 GB pinned (above high water): single 0, TTF ~= 5.71 days
      m_82gb =
        RetentionCalculator.calculate_local_window(
          Map.merge(base, %{
            storage_mode: :local_and_archive,
            local_only_full_policy: :stop_when_full,
            pinned_bytes: 82_800_000_000
          })
        )

      assert m_82gb.window_low_seconds == 0.0
      assert m_82gb.window_high_seconds == 0.0
      assert_in_delta m_82gb.time_to_full_seconds / 86_400, 5.709, 0.05

      # 5. C5 age ceiling stops pinned growth: stop_when_full, 7d local_only_max_age, 15 kB/s, 1.3 GB on disk
      m_capped =
        RetentionCalculator.calculate_local_window(%{
          effective_budget_bytes: 90_200_000_000,
          local_only_rate_bytes_per_sec: 15_000,
          local_only_full_policy: :stop_when_full,
          local_only_max_age_mode: :limited,
          local_only_max_age_seconds: 604_800,
          pinned_bytes: 1_300_000_000,
          current_p3_bytes: 1_300_000_000
        })

      assert m_capped.time_to_full_seconds == :not_filling
    end

    test "detects block-cap binding bound and reports rate statuses cleanly" do
      # 1 TiB volume (~840 GB budget), 120 kbit/s camera (15 kB/s, 320 blocks/day), max_blocks 131,072
      block_capped =
        RetentionCalculator.calculate_local_window(%{
          storage_mode: :local_only,
          effective_budget_bytes: 923_589_767_332,
          local_only_full_policy: :overwrite_oldest,
          local_only_max_age_mode: :unlimited,
          r15m_bytes_per_sec: 15_000,
          history_seconds: 3_600,
          max_blocks: 131_072,
          block_rate_per_sec: 320 / 86_400
        })

      assert block_capped.block_cap_binds? == true
      assert block_capped.binding_bound == :block_cap
      assert_in_delta block_capped.block_cap_seconds / 86_400, 409.6, 0.1

      # Not recording when enabled_policy_count == 0
      not_rec = RetentionCalculator.calculate_local_window(%{enabled_policy_count: 0})
      assert not_rec.status == :not_recording
      assert not_rec.binding_bound == :not_recording

      # Estimated when < 15m history with nominal bitrate
      est =
        RetentionCalculator.calculate_local_window(%{
          history_seconds: 300,
          estimated_bitrate_bps: 4_000_000,
          enabled_policy_count: 1
        })

      assert est.status == :estimated
      assert est.rate_bytes_per_sec == 500_000.0

      # No recent ingest when 15m rate is 0 but 6h rate > 0
      stale =
        RetentionCalculator.calculate_local_window(%{
          history_seconds: 7_200,
          r15m_bytes_per_sec: 0,
          r6h_bytes_per_sec: 250_000,
          enabled_policy_count: 1
        })

      assert stale.status == :no_recent_ingest
      assert stale.rate_bytes_per_sec == 250_000.0
    end
  end

  describe "usage_summary/1 authorization and loader aggregation" do
    test "enforces settings.recording.view|manage|operate and aggregates receipts and blocks" do
      unpermitted = %{id: "u-none", role: :viewer, permissions: MapSet.new()}
      assert {:error, %Forbidden{}} = RetentionCalculator.usage_summary(actor: unpermitted)

      viewer = %{
        id: "u-view",
        role: :viewer,
        permissions: MapSet.new(["settings.recording.view"])
      }

      now = ~U[2026-11-16 12:00:00Z]
      binding_id = "00000000-0000-4000-8000-000000000077"
      storage_id = "00000000-0000-4000-8000-000000000088"

      settings = %{
        RecordingArchiveSettings.default_settings()
        | active_archive_binding_id: binding_id,
          archive_enabled: true,
          archive_retention_mode: :limited,
          archive_retention_days: 1,
          max_local_age_mode: :limited,
          max_local_age_seconds: 172_800
      }

      receipts = [
        %{
          verified_at: DateTime.shift(now, hour: -2),
          objects: [%{"length" => 1_000_000}, %{"length" => 2_000_000}]
        },
        %{
          verified_at: DateTime.shift(now, day: -2),
          objects: [%{"length" => 4_000_000}]
        }
      ]

      blocks = [
        %{storage_id: storage_id, inserted_at: DateTime.shift(now, minute: -5)},
        %{storage_id: storage_id, inserted_at: DateTime.shift(now, hour: -1)}
      ]

      assert {:ok, summary} =
               RetentionCalculator.usage_summary(
                 actor: viewer,
                 now: now,
                 loaders: %{
                   settings_loader: fn -> {:ok, settings} end,
                   receipts_loader: fn ^binding_id -> {:ok, receipts} end,
                   blocks_loader: fn -> {:ok, blocks} end
                 }
               )

      assert summary.archive.archive_used_bytes == 7_000_000
      assert summary.archive.archived_block_count == 2
      assert summary.archive.archived_object_count == 3
      assert summary.archive.trailing_24h_bytes == 3_000_000
      assert summary.archive.trailing_7d_bytes == 7_000_000
      assert summary.archive.rate_basis == :measured
      assert summary.archive.measured_rate_bytes_per_day == 3_000_000.0
      assert summary.local_blocks.total_reserved_blocks == 2
      assert summary.local_blocks.trailing_15m_blocks == 1
      assert summary.local_blocks.trailing_6h_blocks == 2
      assert summary.shorter_archive_than_local? == true
      assert summary.object_retention_enforced? == false
    end
  end

  defp assert_rel_close(actual, expected) do
    assert is_number(actual)
    denom = max(abs(expected), 1.0e-12)
    assert abs(actual - expected) / denom <= @rel_tol
  end
end
