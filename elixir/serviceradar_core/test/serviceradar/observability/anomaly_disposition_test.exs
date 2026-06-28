defmodule ServiceRadar.Observability.AnomalyDispositionTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.AnomalyDisposition, as: D

  # a robust hour-of-week PEAK profile: this hour normally peaks ~55 with spread ~4.
  @profile %{center: 55.0, scale: 4.0, sample_count: 8}

  test "suppresses a spike whose peak matches the hour-of-week peak profile (recurring)" do
    # the nightly-backup case: the edge fires, but this hour normally peaks here.
    assert {:suppress, reason} = D.dispose(%{peak_value: 56.0}, @profile)
    assert reason =~ "recurring"
  end

  test "escalates a spike whose peak is novel for this hour" do
    assert {:escalate, _} = D.dispose(%{peak_value: 90.0}, @profile)
  end

  test "downgrades a moderately elevated peak" do
    # z = (63 - 55)/4 = 2.0, between suppress(1.0) and escalate(3.0)
    assert {:downgrade, _} = D.dispose(%{peak_value: 63.0}, @profile)
  end

  test "passes through when the peak profile is too thin (below min_samples)" do
    assert {:pass_through, _} =
             D.dispose(%{peak_value: 90.0}, %{center: 55.0, scale: 4.0, sample_count: 2})
  end

  test "passes through when the edge finding carries no peak" do
    assert {:pass_through, _} = D.dispose(%{}, @profile)
  end

  test "a zero-variance profile escalates any above-center peak" do
    assert {:escalate, _} =
             D.dispose(%{peak_value: 60.0}, %{center: 55.0, scale: 0.0, sample_count: 8})

    assert {:suppress, _} =
             D.dispose(%{peak_value: 55.0}, %{center: 55.0, scale: 0.0, sample_count: 8})
  end

  test "accepts string keys (the on-the-wire payload shape)" do
    assert {:escalate, _} =
             D.dispose(%{"peak_value" => 90.0}, %{
               "center" => 55.0,
               "scale" => 4.0,
               "sample_count" => 8
             })
  end

  test "thresholds are operator-tunable via opts" do
    # with a stricter escalate threshold the same peak now only downgrades
    assert {:escalate, _} = D.dispose(%{peak_value: 70.0}, @profile, escalate_sigma: 3.0)
    assert {:downgrade, _} = D.dispose(%{peak_value: 70.0}, @profile, escalate_sigma: 5.0)
  end

  describe "for_finding/3 (on-demand disposition orchestration, 1.11)" do
    @finding %{
      "source_identity" => %{
        "metric_class" => "sysmon.cpu",
        "metric_name" => "cpu.usage_percent",
        "partition" => "prod-east",
        "device_id" => "sr:ns03"
      },
      "episode_peak_value" => 92.0,
      "episode_peak_at_unix_nano" => DateTime.to_unix(~U[2026-06-16 09:00:00Z], :nanosecond)
    }

    test "re-keys the finding, fetches its hour-of-week peak profile, and disposes" do
      parent = self()

      fetch = fn ctx ->
        send(parent, {:fetched, ctx})
        %{center: 55.0, scale: 4.0, sample_count: 8}
      end

      result = D.for_finding(@finding, fetch)

      assert result.disposition == :escalate
      assert result.peak_value == 92.0
      assert is_binary(result.series_key)

      expected_dow = rem(Date.day_of_week(~D[2026-06-16]), 7)
      assert_received {:fetched, ctx}
      assert ctx.series_key == result.series_key
      assert ctx.dow == expected_dow
      assert ctx.hod == 9
      # the fetcher receives the metric scope it needs to build the SRQL peak query
      assert ctx.metric_class == "sysmon.cpu"
      assert ctx.metric_name == "cpu.usage_percent"
    end

    test "suppresses when the central peak profile already covers this hour" do
      fetch = fn _ctx -> %{center: 90.0, scale: 5.0, sample_count: 9} end
      assert %{disposition: :suppress} = D.for_finding(@finding, fetch)
    end

    test "returns nil when the finding lacks a forwarded peak" do
      assert D.for_finding(Map.delete(@finding, "episode_peak_value"), fn _ctx -> %{} end) ==
               nil
    end

    test "returns nil when the source_identity cannot be canonically re-keyed" do
      thin = Map.put(@finding, "source_identity", %{"metric_name" => "cpu.usage_percent"})
      assert D.for_finding(thin, fn _ctx -> %{} end) == nil
    end
  end

  describe "actionable?/2 (report-only kill switch + stability gate, 1.12)" do
    test "report-only by default (suppression disabled)" do
      refute D.actionable?(@profile)
    end

    test "actionable when explicitly enabled and the peak profile is stable" do
      assert D.actionable?(@profile, suppression_enabled: true)
    end

    test "report-only when the profile is too thin even if enabled" do
      refute D.actionable?(%{center: 55.0, scale: 4.0, sample_count: 3},
               suppression_enabled: true,
               min_stable_samples: 6
             )
    end
  end
end
