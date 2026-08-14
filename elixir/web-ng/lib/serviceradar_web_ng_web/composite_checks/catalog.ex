defmodule ServiceRadarWebNGWeb.CompositeChecks.Catalog do
  @moduledoc """
  Enabled composite checks and the verdict slugs they can produce.

  Two surfaces need this list: the SRQL catalog, which turns it into
  `composite.<slug>` filter fields with known values, and the device list, which
  turns it into a verdict picker. They must offer the same vocabulary — a picker
  showing a verdict the query language cannot express, or vice versa, is a bug
  the user discovers by getting zero results.

  Verdicts come from the check's authored rules, not from recorded results: a
  verdict no device currently holds is still a legitimate thing to filter for,
  and would otherwise vanish from the list exactly when the operator most wants
  to ask "is anything in this state?".

  Only enabled checks. A draft's `composite.<slug>` matches nothing, so offering
  it would be offering a filter guaranteed to return nothing.
  """

  alias ServiceRadar.CompositeChecks.CompositeCheck
  alias ServiceRadar.CompositeChecks.CompositeCheckRule

  require Logger

  @type check :: %{
          id: Ash.UUID.t(),
          slug: String.t(),
          name: String.t(),
          verdicts: [String.t()]
        }

  @doc """
  Enabled checks with their authored verdicts, sorted by name.

  `opts` are Ash options (`scope:` or `actor:`). Failure degrades to an empty
  list rather than raising: losing composite filters is a much smaller problem
  than a catalog request or a device list that cannot render at all.
  """
  @spec enabled_with_verdicts(keyword()) :: [check()]
  def enabled_with_verdicts(opts) do
    case CompositeCheck.list_enabled(opts) do
      {:ok, checks} -> Enum.map(checks, &with_verdicts(&1, opts))
      {:error, _reason} -> []
    end
  rescue
    exception ->
      Logger.warning("composite check catalog unavailable", reason: Exception.message(exception))
      []
  end

  defp with_verdicts(check, opts) do
    verdicts =
      case CompositeCheckRule.list_by_check(check.id, opts) do
        {:ok, rules} -> rules |> Enum.map(& &1.verdict) |> Enum.uniq() |> Enum.sort()
        {:error, _reason} -> []
      end

    %{id: check.id, slug: check.slug, name: check.name, verdicts: verdicts}
  end

  @doc """
  The SRQL that filters devices to `verdict` of the check slugged `slug`.

  Built here rather than at each call site so the device list's picker and the
  query language cannot drift: this is the exact form the translator's
  `composite.<slug>` filter accepts.
  """
  @spec filter_query(String.t(), String.t()) :: String.t()
  def filter_query(slug, verdict), do: "in:devices composite.#{slug}:#{verdict}"

  @doc """
  The check slug a device-list query filters on, if any.

  Returns `nil` for a query with no composite filter, which is what makes the
  verdict column optional: there is exactly one check to report a verdict for
  when the list is already narrowed to it, and none otherwise.
  """
  # `(?![a-z0-9-])` is load-bearing, not decoration. Without it the greedy slug
  # backtracks to satisfy `(?!\.status)`: on `composite.dmz-isolation.status`
  # it matched `dmz-` — a shorter slug whose next character is not `.status` —
  # and the caller would have shown the verdict column for a check that does
  # not exist. Blocking a match that ends mid-slug removes the backtrack.
  @spec filtered_slug(String.t() | nil) :: String.t() | nil
  def filtered_slug(query) when is_binary(query) do
    case Regex.run(~r/\bcomposite\.([a-z0-9][a-z0-9-]*)(?![a-z0-9-])(?!\.status)/i, query) do
      [_match, slug] -> String.downcase(slug)
      _no_match -> nil
    end
  end

  def filtered_slug(_query), do: nil
end
