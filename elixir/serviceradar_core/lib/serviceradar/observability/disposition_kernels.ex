defmodule ServiceRadar.Observability.DispositionKernels do
  @moduledoc """
  Rustler NIF facade for the central disposition kernels.

  This is the BEAM-visible seam for the operator directive that moves seasonal and
  capacity statistics out of Elixir into Rust. It wraps the `anomaly_disposition_nif`
  cdylib, which calls the `serviceradar-anomaly-disposition` kernels — robust residual
  z-score (seasonal) and least-squares / Holt-Winters forecast (capacity) hosted on
  the `CausalFlow` pipeline combinator from `serviceradar-anomaly-core`. The hosting
  is plumbing; the kernels do not perform causal inference.

  ## Boundary

  `dispose_batch/2` takes a `kind` (`:seasonal | :capacity`) and a list of typed
  per-row request maps, and returns one typed result per row. The boundary is a
  typed `NifMap`/`NifTaggedEnum` ABI, **not** a JSON string (design D2): the worker
  passes plain Elixir maps and reads back tagged tuples.

  ### Seasonal request shape (`kind = :seasonal`)

  Each element of `inputs` is a tagged tuple `{:seasonal, %{config: ..., row: ...}}`
  (the typed `NifTaggedEnum` encoding of the request, NOT a bare map):

      {:seasonal,
       %{
         config: %{
           seasonal_n_sigma: 3.0,
           min_bucket_samples: 4,
           confirm_slots: 1,
           # NOTE: the NIF `RobustStatistic` NifUnitEnum decodes `P05P95` as the atom
           # `:p05p95` (no underscore — rustler's to_snake_case does not split the
           # digit-adjacent segments). Passing `:p05_p95` RAISES a decode error and
           # crashes the whole batch, so the worker normalizes to `:p05p95`.
           robust_statistic: :mean_stddev | :median_mad | :p05p95
         },
         row: %{
           series_key: "svc/cpu",
           dow: 2,
           hod: 9,
           sample_value: 805.0,
           bucket_count: 21,
           bucket_sum: 16_900.0,
           bucket_sum_sq: 13_700_000.0,
           center: 0.0,
           mad: 0.0,
           p05: 0.0,
           p95: 0.0,
           consecutive_anomalous: 0,
           baseline_excludes_latest: true
         }
       }}

  Config rides per row so a missing/invalid config short-circuits to a per-row
  `{:error, _}` result (design D2) rather than failing or unwinding the whole batch.

  ### Result shape

  One result per input row, in order:

  - `{:ok, %{series_key: ..., disposition: disposition, next_consecutive_anomalous: ..., score: ...}}`
    where `disposition` is the typed Value channel, one of:
    - `:suppress`
    - `{:seasonal_breach, %{score: 4.2}}`
    - `{:seasonal_drift, %{score: 3.1}}`
    - `:insufficient_seasonal_baseline`
    - `{:skipped, %{reason: "zero-variance seasonal bucket"}}`
  - `{:error, reason}` when the row could not be disposed (ABI/contract violation,
    an as-yet-unimplemented kernel, or — via per-row panic isolation — a contained
    kernel panic). One bad row never crashes the batch.

  `{:seasonal_breach, _}` surfaces upstream as an anomaly-open verdict. A later
  `:suppress` surfaces as a clear only when the carried counter shows the series was
  previously confirmed. The worker carries `next_consecutive_anomalous` back to
  Postgres for confirm-slot hysteresis.

  ## Capacity

  `dispose_batch(:capacity, [{:capacity, %{config: cfg, row: row}}])` runs the
  least-squares / Holt-Winters forecast in `disposition/capacity.rs` (a 1:1 port of
  the former `CapacityForecasting.Model`, parity-gated to 1e-9). It returns per row:
  - `{:capacity_ok, %{series_key: ..., disposition: disposition}}`, where `disposition` is
    `{:projected, %{slope_per_second, intercept, projected_value, projected_exhaustion_at_unix_micros, confidence, lower_bound, upper_bound, rmse, ...}}`
    or `{:skipped, %{reason: "insufficient_history"}}`
  - `{:error, reason}` on an ABI/contract violation or a contained per-row panic.

  The worker keeps all orchestration (bytes→percent, `at_risk?`/warning policy, the
  plausibility guards, Ash upsert, telemetry, `VerdictEmitter`); only the numeric fit
  lives in the NIF.
  """

  use Rustler,
    otp_app: :serviceradar_core,
    crate: "anomaly_disposition_nif"

  @typedoc "Which disposition kernel to run for the batch."
  @type kind :: :seasonal | :capacity

  @type seasonal_request ::
          {:seasonal,
           %{
             config: map(),
             row: map()
           }}

  @type capacity_request ::
          {:capacity,
           %{
             config: map(),
             row: map()
           }}

  @typedoc "The typed Value-channel disposition returned per row."
  @type disposition ::
          :suppress
          | {:seasonal_breach, %{score: float()}}
          | {:seasonal_drift, %{score: float()}}
          | :insufficient_seasonal_baseline
          | {:skipped, %{reason: String.t()}}
          | {:projected, map()}

  @typedoc "One per-row seasonal disposition result payload."
  @type seasonal_disposition :: %{
          series_key: String.t(),
          disposition: disposition(),
          next_consecutive_anomalous: non_neg_integer(),
          score: float()
        }

  @type capacity_disposition :: %{
          optional(:series_key) => String.t(),
          disposition: disposition()
        }

  @typedoc "One per-row result: a disposition or a typed error reason."
  @type result ::
          {:ok, seasonal_disposition()}
          | {:capacity_ok, capacity_disposition()}
          | {:error, String.t()}

  @doc """
  Disposes a batch of rows through the central disposition kernel selected by `kind`.

  Returns one `t:result/0` per input row, in order. Each row is evaluated under
  per-row panic isolation in Rust (design D2): one malformed row yields one
  `{:error, _}` and never crashes the batch or a scheduler thread.

  See the module doc for the per-`kind` request and result shapes.
  """
  @spec dispose_batch(kind(), [seasonal_request() | capacity_request()]) ::
          [result()]
  def dispose_batch(_kind, _inputs), do: :erlang.nif_error(:nif_not_loaded)
end
