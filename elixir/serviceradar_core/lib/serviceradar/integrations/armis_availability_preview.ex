defmodule ServiceRadar.Integrations.ArmisAvailabilityPreview do
  @moduledoc """
  What adopting merged availability would change for one canonical Armis northbound
  source (`add-merged-device-availability`, design Decision 13): per linked Armis id, the
  value `legacy` semantics push against the value `merged` semantics would push, counted
  by direction with sample device uids. Read-only.

  An Armis id is pushed as the AND of its linked devices, as the runner collapses it.
  `legacy` is the compatibility value (`ArmisNorthboundRunner.canonical_availability_query/1`).
  `merged` is the canonical state: the shadow decision in `shadow` mode, and the
  device's `availability_state` from `cutover` on. The query expression also reads
  the shadow column in `legacy` mode, where no shadow rows are written, so that
  result is not a cutover forecast. Callers that forecast use `forecast_available?/1`
  and skip `legacy`. An id with any unknown or undecided device is withheld under
  `merged`.

  The source settings page shows these counts before an operator adopts merged
  semantics, and only once `forecast_available?/1` is true. The shadow divergence
  report (`ServiceRadar.Inventory.Availability.DivergenceReport`) includes the
  same counts for every canonical source.
  """

  import Ecto.Query

  alias ServiceRadar.Integrations.ArmisNorthboundRunner
  alias ServiceRadar.Inventory.Availability.Mode
  alias ServiceRadar.Inventory.Availability.ShadowDecision
  alias ServiceRadar.Repo

  @default_samples 20

  @type direction :: %{
          legacy_push: String.t(),
          merged_push: String.t(),
          count: non_neg_integer(),
          samples: [String.t()]
        }

  @type t :: %{
          linked_ids: non_neg_integer(),
          would_change: non_neg_integer(),
          withheld: non_neg_integer(),
          by_direction: [direction()]
        }

  @doc """
  Whether a merged-availability preview has a decision to count.

  True when `platform.availability_mode()` is not `legacy`. In `legacy` no shadow
  rows are written, so there is nothing to forecast. `query_opts` are passed to
  the mode read.
  """
  @spec forecast_available?(keyword()) :: boolean()
  def forecast_available?(query_opts \\ []) do
    Mode.current(query_opts) != :legacy
  end

  @doc """
  The preview for `source` (anything with an `:id`). Options: `:samples` (uids per
  direction, default #{@default_samples}) and `:query_opts` (passed to the repo).
  """
  @spec build(map(), keyword()) :: t()
  def build(source, opts \\ []) do
    samples = Keyword.get(opts, :samples, @default_samples)
    query_opts = Keyword.get(opts, :query_opts, [])

    per_device =
      from(c in subquery(ArmisNorthboundRunner.canonical_availability_query(source)),
        left_join: s in ShadowDecision,
        on: s.device_uid == c.device_id,
        select: %{
          armis_device_id: c.armis_device_id,
          device_id: c.device_id,
          legacy: c.legacy,
          merged_state:
            fragment(
              "CASE WHEN platform.availability_mode() IN ('cutover', 'authoritative') THEN ? ELSE ?::text END",
              c.state,
              s.availability_state
            )
        }
      )

    per_id =
      from(r in subquery(per_device),
        group_by: r.armis_device_id,
        select: %{
          legacy: fragment("bool_and(?)", r.legacy),
          merged:
            fragment(
              "CASE WHEN bool_or(? IS NULL OR ? = 'unknown') THEN NULL ELSE bool_and(? = 'available') END",
              r.merged_state,
              r.merged_state,
              r.merged_state
            ),
          device_id: min(r.device_id)
        }
      )

    rows =
      Repo.all(
        from(p in subquery(per_id),
          group_by: [p.legacy, p.merged],
          select:
            {p.legacy, p.merged, count(),
             fragment("(array_agg(? ORDER BY ?))[1:?]", p.device_id, p.device_id, ^samples)}
        ),
        query_opts
      )

    directions =
      Enum.map(rows, fn {legacy, merged, count, uids} ->
        %{legacy_push: push(legacy), merged_push: push(merged), count: count, samples: uids || []}
      end)

    %{
      linked_ids: sum(directions),
      would_change:
        directions
        |> Enum.filter(&(&1.merged_push != "withheld" and &1.legacy_push != &1.merged_push))
        |> sum(),
      withheld: directions |> Enum.filter(&(&1.merged_push == "withheld")) |> sum(),
      by_direction: directions
    }
  end

  defp sum(directions), do: directions |> Enum.map(& &1.count) |> Enum.sum()

  # The runner pushes `not is_available`: "true" for an unavailable device.
  defp push(true), do: "available"
  defp push(false), do: "unavailable"
  defp push(nil), do: "withheld"
end
