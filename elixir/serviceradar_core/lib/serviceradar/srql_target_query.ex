defmodule ServiceRadar.SRQLTargetQuery do
  @moduledoc """
  Validates an operator-written SRQL target query: the query that says which
  records a feature acts on, such as the devices a credential rule, profile,
  sweep group or composite check covers, or the agents an add-on profile
  assigns. Every resource that stores one validates it here, so a target query
  means the same thing wherever it is written.

  Readers of a target query act on its whole selection. They page through it
  with their own page limit and cursor
  (`ServiceRadar.Plugins.SRQLInputResolver.reduce_pages/4`, the device-cohort
  readers) or match records against its filters, and they act on records. A
  token that bounds or reshapes the result therefore has no effect there, and
  the query would run without it. Such tokens are refused when the query is
  saved:

    * `limit:` -- the reader's page limit replaces it, so every matching record
      is still selected.
    * `stats:`, `rollup_stats:` and `other:` -- they turn the result into
      aggregate rows, which are not records to target.
    * `bucket:` / `downsample:` -- they turn the result into time-bucketed
      series. (`agg:`, `series:` and `value_field:` only configure a bucket and
      do nothing without one.)

  `sort:` is allowed: it does not change which records match, and a paged
  reader appends its own unique tie-break after it. `time:` is a filter and is
  allowed.

  A query stored before this rule keeps working: readers still read it whole,
  and the rule applies only when a target query is written.
  """

  alias ServiceRadar.SRQLAst
  alias ServiceRadar.SRQLQuery

  @type option ::
          {:default_target, atom() | String.t()}
          | {:entity, atom() | String.t()}
          | {:parse_fn, (String.t() -> {:ok, String.t()} | {:error, term()})}

  @doc """
  Validates `query` as a target query and returns it with its entity made
  explicit.

  Options:

    * `:default_target` -- the entity prefixed to a query that names none
      (default `:devices`).
    * `:entity` -- the only entity the query may target. Without it any entity
      the parser accepts is allowed.
    * `:parse_fn` -- replaces the SRQL parser, as in `ServiceRadar.SRQLAst`.

  Returns `{:error, message}` with a message an operator can act on.
  """
  @spec validate(String.t(), [option()]) :: {:ok, String.t()} | {:error, String.t()}
  def validate(query, opts \\ []) when is_binary(query) do
    normalized = SRQLQuery.ensure_target(query, Keyword.get(opts, :default_target, :devices))

    with :ok <- check_entity(normalized, Keyword.get(opts, :entity)),
         {:ok, ast} <- parse(normalized, opts),
         :ok <- refuse_result_controls(ast) do
      {:ok, normalized}
    end
  end

  defp check_entity(_query, nil), do: :ok

  defp check_entity(query, entity) do
    expected = to_string(entity)

    case SRQLAst.entity(query) do
      ^expected ->
        :ok

      actual ->
        {:error,
         "must target #{expected} (in:#{expected}), not #{actual}. " <>
           "Add filters after in:#{expected} to narrow the set."}
    end
  end

  defp parse(query, opts) do
    case SRQLAst.parse(query, Keyword.take(opts, [:parse_fn])) do
      {:ok, ast} -> {:ok, ast}
      {:error, {:parse_error, reason}} -> {:error, "Invalid SRQL query: #{reason_text(reason)}"}
      {:error, reason} -> {:error, "Invalid SRQL query: #{reason_text(reason)}"}
    end
  end

  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason), do: inspect(reason)

  defp refuse_result_controls(ast) do
    case refused_controls(ast) do
      [] ->
        :ok

      refused ->
        {:error,
         "#{Enum.join(refused, ", ")} cannot be used in a target query. A target query " <>
           "selects every matching record: a limit is ignored, and an aggregation or " <>
           "time bucket returns rows that are not records to target. Remove " <>
           "#{if length(refused) == 1, do: "it", else: "them"} and narrow the selection " <>
           "with filters instead."}
    end
  end

  # Read from the parsed AST rather than the query text: the parser keeps only
  # the last `limit:` and folds `bucket:` and `downsample:` into one
  # `downsample` spec, so the AST is the authority on what the query asks for.
  defp refused_controls(ast) do
    Enum.filter(
      [
        ast["limit"] && "limit:#{ast["limit"]}",
        ast["stats"] && "stats:",
        ast["rollup_stats"] && "rollup_stats:#{ast["rollup_stats"]}",
        ast["downsample"] && "bucket:",
        ast["other"] == true && "other:true"
      ],
      &is_binary/1
    )
  end
end
