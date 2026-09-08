defmodule ServiceRadar.CompositeChecks.SRQLValidation do
  @moduledoc """
  Validates composite check references in an SRQL query before it runs.

  The Rust translator is a pure query compiler with no database connection, so
  it cannot know which check slugs exist. It does guarantee the half that
  matters for safety: because the compiled predicate joins `composite_checks` on
  slug, an unknown slug matches nothing and the filter returns zero devices
  rather than degrading into "match everything".

  What it cannot do is tell the caller *why* they got nothing back. That is this
  module's job, and it belongs here because this is where a database is
  available.

  This is a string scan, deliberately not a parser. SRQL is parsed in Rust and
  duplicating that grammar in Elixir would give two things to keep in step. The
  scan only needs to find `composite.<slug>` tokens, and over-matching is
  harmless — a slug that exists validates fine wherever it appeared.
  """

  alias ServiceRadar.CompositeChecks.CompositeCheck

  # Matches the field token only: `composite.` followed by a slug, optionally
  # suffixed with `.status`. Anchored on a non-word boundary so it does not fire
  # inside a longer identifier.
  @composite_field ~r/\bcomposite\.([a-z0-9][a-z0-9-]*)(\.status)?\b/i

  @type error :: {:unknown_composite_check, String.t()}

  @doc """
  Returns `:ok` when every composite slug referenced by the query exists.

  Slugs are lowercased before lookup, matching `normalize_field_name` in the
  translator: every field outside the `tags`/`metadata` namespaces is
  lowercased, and check slugs are lowercase by construction.
  """
  @spec validate_composite_slugs(String.t(), keyword()) :: :ok | {:error, error()}
  def validate_composite_slugs(query, opts \\ [])

  def validate_composite_slugs(query, opts) when is_binary(query) do
    query
    |> referenced_slugs()
    |> Enum.reduce_while(:ok, fn slug, :ok ->
      case CompositeCheck.get_by_slug(slug, opts) do
        {:ok, _check} -> {:cont, :ok}
        {:error, _reason} -> {:halt, {:error, {:unknown_composite_check, slug}}}
      end
    end)
  end

  def validate_composite_slugs(_query, _opts), do: :ok

  @doc """
  Extracts the distinct composite slugs a query references, in order of first
  appearance.
  """
  @spec referenced_slugs(String.t()) :: [String.t()]
  def referenced_slugs(query) when is_binary(query) do
    @composite_field
    |> Regex.scan(query, capture: :all_but_first)
    |> Enum.map(fn
      [slug | _rest] -> String.downcase(slug)
    end)
    |> Enum.uniq()
  end

  def referenced_slugs(_query), do: []
end
