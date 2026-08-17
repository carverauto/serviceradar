defmodule ServiceRadarWebNGWeb.Settings.CompositeChecksLive.FactKeys do
  @moduledoc """
  Metadata keys that are usable as a device fact, for the builder's suggestions.

  Only keys whose value is a **boolean** on at least one device. That filter is
  the whole point: `Resolvers.DeviceMetadata` casts booleans and nothing else,
  so offering a key that holds a string or a number would be offering a choice
  that resolves `unknown` forever. Observed on a live deployment, every one of
  the ~25 metadata keys present was internal bookkeeping (`sweep_*`,
  `identity_*`, `topology_*`, `rdns`) and not one was a boolean -- an
  unfiltered list would have been a menu of guaranteed-wrong answers.

  These are suggestions, not a closed set. The key an operator wants usually
  does NOT exist yet: it is the one their validator is about to start writing.
  So the builder keeps a free-text input and attaches this as a `<datalist>`,
  which is what makes it a combobox rather than a dropdown. A dropdown would
  invert the workflow and make the common case impossible.

  Raw SQL because `jsonb_object_keys` is a set-returning function in a LATERAL
  join, which Ash expressions do not model. Follows the existing
  `ServiceRadarWebNG.Repo.query/2` precedent in the dashboard data modules.
  """

  require Logger

  # A full scan of ocsf_devices' metadata. Bounded rather than unbounded:
  # this feeds a suggestion list, so a partial answer is fine and a query that
  # degrades with device count is not. The scan is capped by @scan_limit and
  # the output by @key_limit.
  @scan_limit 5_000
  @key_limit 50

  @query """
  SELECT k, count(*)::bigint AS devices
  FROM (
    SELECT metadata
    FROM platform.ocsf_devices
    WHERE deleted_at IS NULL
      AND metadata IS NOT NULL
    ORDER BY last_seen_time DESC NULLS LAST
    LIMIT $1
  ) d,
  LATERAL jsonb_object_keys(d.metadata) k
  WHERE jsonb_typeof(d.metadata -> k) = 'boolean'
  GROUP BY k
  ORDER BY devices DESC, k ASC
  LIMIT $2
  """

  @type suggestion :: %{key: String.t(), devices: non_neg_integer()}

  @doc """
  Boolean-valued metadata keys, most widely present first.

  Returns `[]` on any failure. A suggestion list is an affordance, not a
  correctness requirement -- an operator who can still type the key is only
  mildly inconvenienced, whereas a builder that will not render because a
  helper query broke is unusable.
  """
  @spec suggestions() :: [suggestion()]
  def suggestions do
    case ServiceRadarWebNG.Repo.query(@query, [@scan_limit, @key_limit]) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [key, devices] -> %{key: key, devices: devices} end)

      {:error, error} ->
        Logger.warning("[CompositeChecks] fact key suggestions unavailable: #{inspect(error)}")
        []
    end
  end
end
