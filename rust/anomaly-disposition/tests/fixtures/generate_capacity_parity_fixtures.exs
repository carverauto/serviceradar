# Copyright 2026 Carver Automation Corporation.
# Licensed under the Apache License, Version 2.0.
# SPDX-License-Identifier: Apache-2.0
#
# GOLDEN-FIXTURE GENERATOR (OpenSpec add-core-causal-disposition-nif, task 7.3 / graft #4).
#
# Runs the LEGACY pure forecaster
# `ServiceRadar.Observability.CapacityForecasting.Model.forecast/2` over seeded
# CAGG-style slices and snapshots its EXACT numeric outputs to
# `capacity_parity_fixtures.json`. The committed fixture is then asserted against the
# Rust kernel (`dispose_capacity`) in `tests/capacity_parity.rs` to within 1e-9 —
# so the parity gate SURVIVES the eventual deletion of `model.ex` (task 7.5): the
# JSON is the durable oracle, not a live call into the BEAM.
#
# Regenerate (only while `model.ex` still exists) with:
#   elixirc <path>/model.ex && \
#   elixir -pa . rust/anomaly-disposition/tests/fixtures/generate_capacity_parity_fixtures.exs
#
# `model.ex` is pure (no Ash/DB/OTP deps), so this compiles and runs standalone.

alias ServiceRadar.Observability.CapacityForecasting.Model

# 2026-06-01T00:00:00Z, the anchor the model_test.exs fixtures use.
start = ~U[2026-06-01 00:00:00Z]
start_micros = DateTime.to_unix(start, :microsecond)

# Build hourly points: value_fun.(hour) -> value.
points = fn count, value_fun ->
  for hour <- 0..(count - 1) do
    %{at: DateTime.add(start, hour * 3_600, :second), value: value_fun.(hour)}
  end
end

# Encode a point list as the Rust ABI shape: {at_unix_micros, value}.
encode_points = fn pts ->
  Enum.map(pts, fn %{at: at, value: value} ->
    %{
      "at_unix_micros" => DateTime.to_unix(at, :microsecond),
      "value" => value * 1.0
    }
  end)
end

# DateTime | nil -> unix micros | nil, matching the Rust kernel's ETA encoding.
eta_micros = fn
  %DateTime{} = dt -> DateTime.to_unix(dt, :microsecond)
  nil -> nil
end

# Config defaults mirror the worker/model opts. `model` and `threshold` per-case.
base_opts = [
  min_points: 24,
  horizon_seconds: 24 * 3_600,
  seasonal_period: 24
]

# Each case: {name, points, opts}. The opts feed both Model.forecast and the Rust config.
cases = [
  # --- LINEAR ---
  {"linear_rising_eta_in_horizon", points.(48, fn h -> 10.0 + h end),
   Keyword.merge(base_opts, model: :linear, exhaustion_threshold: 80.0)},
  {"linear_half_slope_partial_horizon", points.(48, fn h -> 5.0 + h * 0.5 end),
   Keyword.merge(base_opts, model: :linear, horizon_seconds: 12 * 3_600, exhaustion_threshold: 40.0)},
  {"linear_decreasing_no_eta", points.(48, fn h -> 90.0 - h * 0.25 end),
   Keyword.merge(base_opts, model: :linear, exhaustion_threshold: 100.0)},
  {"linear_near_zero_slope_beyond_horizon", points.(48, fn h -> 10.0 + h * 0.0001 end),
   Keyword.merge(base_opts, model: :linear, exhaustion_threshold: 100.0)},
  {"linear_already_crossed_in_window", points.(48, fn h -> 150.0 + h end),
   Keyword.merge(base_opts, model: :linear, exhaustion_threshold: 100.0)},
  {"linear_no_threshold", points.(48, fn h -> 10.0 + h * 0.7 end),
   Keyword.merge(base_opts, model: :linear)},
  # Noisy linear: exercises a non-trivial RMSE / confidence / bounds.
  {"linear_noisy_rmse", points.(60, fn h -> 20.0 + h * 0.8 + :math.sin(h / 2.0) * 3.0 end),
   Keyword.merge(base_opts, model: :linear, exhaustion_threshold: 120.0)},
  # --- AUTO (autodetect) ---
  {"auto_flat_is_linear", points.(72, fn _ -> 40.0 end),
   Keyword.merge(base_opts, min_points: 48, model: :auto)},
  {"auto_seasonal_is_holt_winters",
   points.(72, fn h ->
     seasonal = if rem(h, 24) in 8..17, do: 25.0, else: -10.0
     50.0 + seasonal + h * 0.05
   end), Keyword.merge(base_opts, min_points: 48, model: :auto, exhaustion_threshold: 120.0)},
  # --- FORCED SEASONAL (Holt-Winters), incl. seasonal exhaustion ETA ---
  {"seasonal_forced_holt_winters_eta",
   points.(96, fn h ->
     seasonal = if rem(h, 24) in 9..18, do: 30.0, else: -5.0
     20.0 + seasonal + h * 0.4
   end),
   Keyword.merge(base_opts, min_points: 48, model: :seasonal, horizon_seconds: 48 * 3_600,
     exhaustion_threshold: 90.0)},
  # Seasonal forced but too little history -> falls back to linear inside the model.
  {"seasonal_forced_falls_back_to_linear", points.(30, fn h -> 10.0 + h * 0.6 end),
   Keyword.merge(base_opts, model: :seasonal, seasonal_period: 24, exhaustion_threshold: 100.0)},
  # --- INSUFFICIENT HISTORY GATE (task 7.2 / 8.2): {:skip, "insufficient_history"}. ---
  {"insufficient_history_skipped", points.(2, fn h -> 10.0 + h end),
   Keyword.merge(base_opts, min_points: 3, model: :auto)}
]

encoded =
  Enum.map(cases, fn {name, pts, opts} ->
    result = Model.forecast(pts, opts)

    expected =
      case result do
        {:ok, f} ->
          %{
            "kind" => "projected",
            "model" => f.model,
            "current_value" => f.current_value,
            "slope_per_second" => f.slope_per_second,
            "intercept" => f.intercept,
            "projected_value" => f.projected_value,
            "projected_exhaustion_at_unix_micros" => eta_micros.(f.projected_exhaustion_at),
            "confidence" => f.confidence,
            "lower_bound" => f.lower_bound,
            "upper_bound" => f.upper_bound,
            "rmse" => Map.fetch!(f.diagnostics, "rmse"),
            "sample_count" => f.sample_count,
            "window_started_at_unix_micros" => DateTime.to_unix(f.window_started_at, :microsecond),
            "window_ended_at_unix_micros" => DateTime.to_unix(f.window_ended_at, :microsecond)
          }

        {:skip, reason, _diagnostics} ->
          %{"kind" => "skipped", "reason" => reason}
      end

    %{
      "name" => name,
      "config" => %{
        "capacity_threshold" => Keyword.get(opts, :exhaustion_threshold),
        "horizon_seconds" => Keyword.fetch!(opts, :horizon_seconds),
        "model_kind" => to_string(Keyword.fetch!(opts, :model)),
        "min_history" => Keyword.fetch!(opts, :min_points),
        "period" => Keyword.fetch!(opts, :seasonal_period),
        # Holt-Winters smoothing ratios use the model defaults (not overridden here).
        "alpha" => 0.35,
        "beta" => 0.05,
        "gamma" => 0.25
      },
      "points" => encode_points.(pts),
      "expected" => expected
    }
  end)

# A minimal hand-rolled JSON encoder so the generator needs no deps (Jason is not on
# the standalone path). Handles maps, lists, strings, integers, floats, nil.
defmodule TinyJSON do
  def encode(term), do: IO.iodata_to_binary(enc(term))

  defp enc(nil), do: "null"
  defp enc(true), do: "true"
  defp enc(false), do: "false"
  defp enc(s) when is_binary(s), do: [?", escape(s), ?"]
  defp enc(i) when is_integer(i), do: Integer.to_string(i)

  defp enc(f) when is_float(f) do
    # Round-trip-exact float text: :erlang.float_to_binary(short) preserves the IEEE
    # value, so the Rust parser reconstructs the identical f64 (no parity loss).
    :erlang.float_to_binary(f, [:short])
  end

  defp enc(list) when is_list(list) do
    ["[", list |> Enum.map(&enc/1) |> Enum.intersperse(","), "]"]
  end

  defp enc(map) when is_map(map) do
    inner =
      map
      |> Enum.sort_by(fn {k, _} -> to_string(k) end)
      |> Enum.map(fn {k, v} -> [?", escape(to_string(k)), ?", ":", enc(v)] end)
      |> Enum.intersperse(",")

    ["{", inner, "}"]
  end

  defp escape(s) do
    s
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end
end

json_path = Path.join(__DIR__, "capacity_parity_fixtures.json")
File.write!(json_path, TinyJSON.encode(encoded) <> "\n")

# --- Also emit a Rust `include!`-able source of literal fixtures. ---
# This is the DURABLE oracle the parity test consumes: no JSON parser (so a parser
# bug can never mask a parity bug), no dev-dependency on the kernel crate (which
# stays dependency-light for bazel), and the floats are Rust f64 literals produced
# by `:erlang.float_to_binary(_, [:short])` — the shortest round-tripping decimal,
# which Rust's f64 literal parser reconstructs to the identical bit pattern.
defmodule RustFixtures do
  def float(f) when is_float(f), do: :erlang.float_to_binary(f, [:short])
  # Integers that land in a f64 field are emitted with a trailing `.0`.
  def float(i) when is_integer(i), do: "#{i}.0"

  def opt_i64(nil), do: "None"
  def opt_i64(i) when is_integer(i), do: "Some(#{i})"

  def model_kind("auto"), do: "CapacityModelKind::Auto"
  def model_kind("linear"), do: "CapacityModelKind::Linear"
  def model_kind("seasonal"), do: "CapacityModelKind::Seasonal"
  def model_kind("holt_winters"), do: "CapacityModelKind::Seasonal"
  def opt_thresh(nil), do: "None"
  def opt_thresh(n), do: "Some(#{float(n)})"
end

case_src =
  Enum.map(encoded, fn c ->
    cfg = c["config"]
    pts = c["points"]

    points_src =
      pts
      |> Enum.map(fn p ->
        "        CapacityPoint { at_unix_micros: #{p["at_unix_micros"]}, value: #{RustFixtures.float(p["value"])} },"
      end)
      |> Enum.join("\n")

    expected_src =
      case c["expected"] do
        %{"kind" => "skipped", "reason" => reason} ->
          "Expected::Skipped { reason: #{inspect(reason)} }"

        %{"kind" => "projected"} = e ->
          """
          Expected::Projected(ExpectedForecast {
                  model: #{inspect(e["model"])},
                  current_value: #{RustFixtures.float(e["current_value"])},
                  slope_per_second: #{RustFixtures.float(e["slope_per_second"])},
                  intercept: #{RustFixtures.float(e["intercept"])},
                  projected_value: #{RustFixtures.float(e["projected_value"])},
                  projected_exhaustion_at_unix_micros: #{RustFixtures.opt_i64(e["projected_exhaustion_at_unix_micros"])},
                  confidence: #{RustFixtures.float(e["confidence"])},
                  lower_bound: #{RustFixtures.float(e["lower_bound"])},
                  upper_bound: #{RustFixtures.float(e["upper_bound"])},
                  rmse: #{RustFixtures.float(e["rmse"])},
                  sample_count: #{e["sample_count"]},
                  window_started_at_unix_micros: #{e["window_started_at_unix_micros"]},
                  window_ended_at_unix_micros: #{e["window_ended_at_unix_micros"]},
              })\
          """
      end

    """
    ParityCase {
        name: #{inspect(c["name"])},
        config: CapacityConfig {
            capacity_threshold: #{RustFixtures.opt_thresh(cfg["capacity_threshold"])},
            horizon_seconds: #{cfg["horizon_seconds"]},
            model_kind: #{RustFixtures.model_kind(cfg["model_kind"])},
            min_history: #{cfg["min_history"]},
            period: #{cfg["period"]},
            alpha: #{RustFixtures.float(cfg["alpha"])},
            beta: #{RustFixtures.float(cfg["beta"])},
            gamma: #{RustFixtures.float(cfg["gamma"])},
            value_min: None,
            value_max: None,
        },
        points: vec![
    #{points_src}
        ],
        expected: #{expected_src},
    },\
    """
  end)
  |> Enum.join("\n")

rust_header = """
// @generated by tests/fixtures/generate_capacity_parity_fixtures.exs — DO NOT EDIT.
//
// Golden parity fixtures captured from the LEGACY
// `ServiceRadar.Observability.CapacityForecasting.Model.forecast/2` (model.ex).
// Consumed by `tests/capacity_parity.rs`, which asserts `dispose_capacity` matches
// each `expected` within 1e-9 — the durable parity gate that survives model.ex
// deletion (task 7.3 / 7.5 / graft #4). Regenerate via the .exs generator while
// model.ex still exists.

vec![
#{case_src}
]
"""

rs_path = Path.join(__DIR__, "capacity_parity_fixtures.rs")
File.write!(rs_path, rust_header)

IO.puts("wrote #{length(encoded)} parity cases -> #{json_path}")
IO.puts("wrote #{length(encoded)} parity cases -> #{rs_path}")
