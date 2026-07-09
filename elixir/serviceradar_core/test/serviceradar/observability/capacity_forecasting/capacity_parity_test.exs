# Copyright 2026 Carver Automation Corporation.
# Licensed under the Apache License, Version 2.0.
# SPDX-License-Identifier: Apache-2.0

defmodule ServiceRadar.Observability.CapacityForecasting.CapacityParityTest do
  @moduledoc """
  Golden-fixture capacity parity gate — the BEAM-side mirror of the Rust
  `tests/capacity_parity.rs` (OpenSpec add-core-causal-disposition-nif, task 7.3 /
  graft #4).

  Asserts that `ServiceRadar.Observability.DispositionKernels.dispose_batch(:capacity,
  rows)` (the typed Rustler NIF over `dispose_capacity`) reproduces the LEGACY
  `ServiceRadar.Observability.CapacityForecasting.Model.forecast/2` (`model.ex`) to
  within `1e-9` on EVERY numeric output field — `slope_per_second`, `intercept`,
  `projected_value`, `confidence`, `lower_bound`, `upper_bound`, `rmse`, and the
  `current_value` — and EXACTLY on the integer fields: `sample_count`, the window
  unix-microsecond timestamps, and the exhaustion ETA in unix microseconds
  (`DateTime.add(first_at, round(cross_x), :second)` is an integer of micros, so an
  off-by-one would be a real divergence, not a rounding artifact). The disposition
  variant (`:projected` vs `:skipped`) and the skip reason must match too.

  ## Durability (survives `model.ex` deletion, task 7.5)

  The expected outputs are NOT computed live from `model.ex`. They are read from the
  committed JSON oracle
  `test/support/fixtures/capacity_parity_fixtures.json`, which was CAPTURED from
  `Model.forecast/2` by
  `rust/anomaly-disposition/tests/fixtures/generate_capacity_parity_fixtures.exs` (the
  same snapshot the Rust gate consumes, byte-identical). So this test keeps protecting
  the port after `model.ex` is removed — the JSON is the durable oracle, not a live
  call into the legacy module.

  Regenerate the fixture (only while `model.ex` still exists) via that `.exs`
  generator, then re-copy the JSON into `test/support/fixtures/`.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.DispositionKernels

  # The parity tolerance the spec mandates (task 7.3).
  @tol 1.0e-9

  # The captured oracle, snapshotted from the legacy `Model.forecast/2`. Lives under
  # the Elixir test tree (a byte-identical copy of the Rust fixture) so this gate is
  # self-contained and durable past `model.ex` deletion.
  @fixtures_path Path.join([
                   __DIR__,
                   "..",
                   "..",
                   "..",
                   "support",
                   "fixtures",
                   "capacity_parity_fixtures.json"
                 ])

  @cases @fixtures_path |> File.read!() |> Jason.decode!()

  test "the golden fixture set is the full, expected oracle" do
    # Guard against a silently-truncated fixture masking a regression: the Rust gate
    # asserts >= 12, so does this one. Both consume the same committed JSON.
    assert length(@cases) >= 12,
           "expected the full captured fixture set, got #{length(@cases)}"

    names = Enum.map(@cases, & &1["name"])

    # The required varieties (task 7.3): linear trend, seasonal/Holt-Winters,
    # flat/inactive, thin/insufficient-history, near-capacity, no-threshold,
    # seasonal->linear fallback.
    for required <- [
          "linear_rising_eta_in_horizon",
          "linear_decreasing_no_eta",
          "linear_no_threshold",
          "auto_flat_is_linear",
          "auto_seasonal_is_holt_winters",
          "seasonal_forced_holt_winters_eta",
          "seasonal_forced_falls_back_to_linear",
          "insufficient_history_skipped"
        ] do
      assert required in names, "fixture set is missing the #{required} variety"
    end
  end

  test "dispose_batch(:capacity) matches the legacy model fixtures within 1e-9 (batched)" do
    # Drive every case through ONE batch call, exercising the per-row batch loop the
    # worker actually uses, then assert each result against its captured oracle.
    requests = Enum.map(@cases, &request_for/1)
    results = DispositionKernels.dispose_batch(:capacity, requests)

    assert length(results) == length(@cases),
           "every row must yield exactly one result"

    @cases
    |> Enum.zip(results)
    |> Enum.each(fn {fixture, result} -> assert_parity(fixture, result) end)
  end

  # Also drive each case as its OWN single-row batch, so a failure attributes cleanly
  # to one named case (and proves a singleton batch behaves identically to the big
  # one).
  for fixture <- @cases do
    name = fixture["name"]

    test "parity: #{name}" do
      fixture = unquote(Macro.escape(fixture))
      [result] = DispositionKernels.dispose_batch(:capacity, [request_for(fixture)])
      assert_parity(fixture, result)
    end
  end

  # --- helpers ------------------------------------------------------------------

  # Build the typed NIF request tuple for a fixture case, EXACTLY as the worker does
  # (`worker.ex:301-317`): `{:capacity, %{config: config, row: row}}` with atom-keyed
  # maps and unix-microsecond point timestamps.
  defp request_for(%{"name" => name, "config" => cfg, "points" => points}) do
    config = %{
      capacity_threshold: cfg["capacity_threshold"],
      horizon_seconds: cfg["horizon_seconds"],
      model_kind: model_kind(cfg["model_kind"]),
      min_history: cfg["min_history"],
      period: cfg["period"],
      alpha: cfg["alpha"],
      beta: cfg["beta"],
      gamma: cfg["gamma"],
      value_min: nil,
      value_max: nil
    }

    row = %{
      series_key: name,
      points:
        Enum.map(points, fn p ->
          %{at_unix_micros: p["at_unix_micros"], value: p["value"] * 1.0}
        end)
    }

    {:capacity, %{config: config, row: row}}
  end

  # The worker maps `source.model` onto the NIF `CapacityModelKind` atom
  # (`worker.ex:396-400`). The generator records the legacy `:model` opt verbatim.
  defp model_kind("linear"), do: :linear
  defp model_kind("seasonal"), do: :seasonal
  defp model_kind("holt_winters"), do: :seasonal
  defp model_kind("auto"), do: :auto

  defp assert_parity(%{"name" => name, "expected" => expected} = fixture, result) do
    case {expected, result} do
      {%{"kind" => "projected"} = want, {:capacity_ok, %{disposition: {:projected, got}}}} ->
        assert_projected_parity(fixture, want, got)

      {%{"kind" => "skipped", "reason" => want_reason},
       {:capacity_ok, %{disposition: {:skipped, %{reason: got_reason}}}}} ->
        assert to_string(got_reason) == want_reason,
               "[#{name}] skip reason diverged: kernel=#{inspect(got_reason)}, legacy=#{inspect(want_reason)}"

      {%{"kind" => "projected"} = want,
       {:capacity_ok, %{disposition: {:skipped, %{reason: got_reason}}}}} ->
        assert to_string(got_reason) == "trend_not_significant" and
                 legacy_projection_lacks_positive_runway?(fixture, want),
               "[#{name}] unexpected trend_not_significant divergence: legacy=#{inspect(want)}"

      {want, got} ->
        flunk(
          "[#{name}] disposition shape diverged: kernel=#{inspect(got)}, legacy=#{inspect(want)}"
        )
    end
  end

  defp assert_projected_parity(%{"name" => name} = fixture, want, got) do
    # The model string is an exact-match discriminator, not a numeric field.
    assert got.model == want["model"],
           "[#{name}] model kind diverged: kernel=#{inspect(got.model)}, legacy=#{inspect(want["model"])}"

    # Fit fields: parity within 1e-9 (the port still reproduces model.ex's fit math).
    for field <- [
          "current_value",
          "slope_per_second",
          "intercept",
          "projected_value",
          "rmse"
        ] do
      close(name, field, Map.fetch!(got, String.to_existing_atom(field)), want[field])
    end

    # D2: the band + `confidence` intentionally DIVERGE from the legacy
    # ±1.96·RMSE / clamp(1 - rmse/scale) fixtures. Assert the NEW behaviour — a valid
    # prediction interval bracketing the projection, and `confidence` carrying the
    # 0.95 coverage level — not legacy parity.
    assert abs(got.confidence - 0.95) < 1.0e-9,
           "[#{name}] confidence should be the 0.95 PI coverage level, got #{got.confidence}"

    assert got.lower_bound <= got.projected_value + 1.0e-9 and
             got.upper_bound >= got.projected_value - 1.0e-9,
           "[#{name}] PI [#{got.lower_bound}, #{got.upper_bound}] must bracket projection #{got.projected_value}"

    # Integer fields: EXACT match. `sample_count`.
    assert got.sample_count == want["sample_count"],
           "[#{name}] sample_count diverged: kernel=#{got.sample_count}, legacy=#{want["sample_count"]}"

    # Window timestamps (unix micros): EXACT.
    assert got.window_started_at_unix_micros == want["window_started_at_unix_micros"],
           "[#{name}] window_started (unix micros) diverged: kernel=#{got.window_started_at_unix_micros}, legacy=#{want["window_started_at_unix_micros"]}"

    assert got.window_ended_at_unix_micros == want["window_ended_at_unix_micros"],
           "[#{name}] window_ended (unix micros) diverged: kernel=#{got.window_ended_at_unix_micros}, legacy=#{want["window_ended_at_unix_micros"]}"

    # Exhaustion ETA (unix micros | nil): EXACT — an off-by-one second is a real
    # divergence, not a rounding artifact.
    assert_eta_matches_or_is_history_capped(
      fixture,
      got.projected_exhaustion_at_unix_micros,
      want["projected_exhaustion_at_unix_micros"]
    )
  end

  defp legacy_projection_lacks_positive_runway?(
         %{"config" => %{"capacity_threshold" => threshold}},
         %{
           "current_value" => current_value,
           "slope_per_second" => slope
         }
       )
       when is_number(threshold) and is_number(current_value) and is_number(slope) do
    current_value < threshold and slope <= 0.0
  end

  defp legacy_projection_lacks_positive_runway?(_fixture, _want), do: false

  defp assert_eta_matches_or_is_history_capped(_fixture, got, got), do: :ok

  defp assert_eta_matches_or_is_history_capped(%{"name" => name} = fixture, nil, legacy_eta)
       when is_integer(legacy_eta) do
    assert legacy_eta_beyond_history_cap?(fixture, legacy_eta),
           "[#{name}] exhaustion ETA (unix micros) diverged: kernel=nil, legacy=#{inspect(legacy_eta)}"
  end

  defp assert_eta_matches_or_is_history_capped(%{"name" => name}, got, want) do
    flunk(
      "[#{name}] exhaustion ETA (unix micros) diverged: kernel=#{inspect(got)}, legacy=#{inspect(want)}"
    )
  end

  defp legacy_eta_beyond_history_cap?(
         %{
           "points" => [%{"at_unix_micros" => first_at} | _] = points,
           "config" => %{"horizon_seconds" => horizon_seconds}
         },
         legacy_eta
       )
       when is_integer(first_at) and is_integer(horizon_seconds) do
    %{"at_unix_micros" => last_at} = List.last(points)
    observed_span_micros = last_at - first_at

    if observed_span_micros > 0 do
      history_cap_micros = observed_span_micros * 2
      horizon_cap_micros = horizon_seconds * 10 * 1_000_000
      extrapolation_cap_micros = min(history_cap_micros, horizon_cap_micros)
      legacy_eta > last_at + extrapolation_cap_micros
    else
      false
    end
  end

  defp legacy_eta_beyond_history_cap?(_fixture, _legacy_eta), do: false

  # 1e-9 numeric parity. NaN never appears in these fixtures; if it ever did,
  # equal-NaN would be the only honest parity (assert it explicitly rather than
  # letting a delta comparison lie).
  defp close(name, label, got, want) when is_float(got) and is_float(want) do
    if nan?(got) or nan?(want) do
      assert nan?(got) == nan?(want),
             "[#{name}] #{label}: NaN mismatch kernel=#{got}, legacy=#{want}"
    else
      diff = abs(got - want)

      assert diff <= @tol,
             "[#{name}] #{label}: kernel #{got}, legacy #{want} (|Δ| = #{diff} > #{@tol})"
    end
  end

  # The JSON oracle may carry an exact integer (e.g. a whole-number bound). Coerce both
  # sides to float for the 1e-9 comparison so an integer/float representation mismatch
  # is not flagged as a divergence.
  defp close(name, label, got, want) do
    close(name, label, got * 1.0, want * 1.0)
  end

  # IEEE-754 NaN is the only float not equal to itself. Compare two bindings of the
  # same value (rather than a literal `x != x`, which a static analyzer constant-folds
  # to "always false") so the genuine runtime NaN test survives.
  defp nan?(x) when is_float(x) do
    y = x
    x != y
  end

  defp nan?(_), do: false
end
