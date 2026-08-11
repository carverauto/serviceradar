defmodule ServiceRadarWebNGWeb.Settings.NotificationsLive.Predicate do
  @moduledoc """
  The predicate builder behind the route editor: form rows in, a
  `match_expression` document out, and back again.

  ## Why the field list is not authored here

  `ServiceRadar.Notifications.MatchExpression.Fields` is the single source of
  truth for the matchable surface of a route, shared verbatim with the save-time
  validator (`MatchFieldAllowList`) and the dispatch-time evaluator. A field this
  builder offered but that list did not admit would produce a route that saves
  cleanly and matches nothing, forever, silently - the exact "why was I not
  paged?" failure the platform exists to eliminate. So the options come from
  `Fields.route_fields/0` and every submitted field is re-checked against
  `Fields.route_field?/1` server-side, because the `<select>` a browser sends
  back is operator-supplied text, not evidence of what was rendered.

  Operators come from `ServiceRadar.Notifications.MatchExpression.operators/0`
  for the same reason.

  ## No atoms, ever

  Field names, operators, and operand values arrive as strings and stay strings.
  There is no `String.to_atom/1` or `String.to_existing_atom/1` in this module;
  the document the grammar validates is a plain string-keyed map.

  ## Round-tripping is partial on purpose

  The grammar admits nesting the row-based builder cannot express (`not`,
  combinators inside combinators). `from_document/1` returns `:unsupported` for
  those rather than silently flattening them into something that means something
  else, and the editor renders the raw document read-only in that case.
  """

  alias ServiceRadar.Notifications.MatchExpression
  alias ServiceRadar.Notifications.MatchExpression.Fields

  @combinators ~w(all any)
  @operators MatchExpression.operators()

  @type row :: %{required(String.t()) => String.t()}

  @doc "The combinator keys the builder offers (`all` = AND, `any` = OR)."
  @spec combinators() :: [String.t()]
  def combinators, do: @combinators

  @doc "The operators the grammar admits, for the operator `<select>`."
  @spec operators() :: [String.t()]
  def operators, do: @operators

  @doc "The exact field paths a route may name."
  @spec field_options() :: [String.t()]
  def field_options, do: Fields.route_fields()

  @doc """
  The `alert.metadata.` style prefixes under which any continuation is matchable.

  Rendered as help text so an operator knows a free-form incident key is
  reachable even though it cannot be enumerated at compile time.
  """
  @spec field_prefixes() :: [String.t()]
  def field_prefixes, do: Fields.route_field_prefixes()

  @doc "An empty builder row."
  @spec blank_row() :: row()
  def blank_row do
    %{"field" => List.first(field_options()) || "", "operator" => "equals", "value" => ""}
  end

  @doc """
  Builds a `match_expression` document from the builder rows.

  Returns `{:error, {:unknown_field, path}}` for a field outside the allow-list
  and `{:error, {:unknown_operator, op}}` for an operator outside the grammar,
  so a crafted submission is refused with a validation error rather than saved
  as a rule that matches nothing.
  """
  @spec to_document(term(), term()) :: {:ok, map()} | {:error, term()}
  def to_document(combinator, rows) when is_list(rows) do
    with {:ok, key} <- combinator(combinator),
         {:ok, predicates} <- predicates(rows) do
      case predicates do
        [] -> {:ok, %{}}
        list -> {:ok, %{key => list}}
      end
    end
  end

  def to_document(_combinator, _rows), do: {:error, :invalid_rows}

  @doc """
  Reads a stored document back into `{combinator, rows}` for the editor.

  Returns `:unsupported` when the document nests beyond what rows express.
  """
  @spec from_document(term()) :: {:ok, {String.t(), [row()]}} | :unsupported
  def from_document(document) when is_map(document) and map_size(document) == 0 do
    {:ok, {"all", []}}
  end

  def from_document(%{} = document) do
    case Map.to_list(document) do
      [{key, list}] when key in @combinators and is_list(list) ->
        rows(list, key)

      _other ->
        case predicate_row(document) do
          {:ok, row} -> {:ok, {"all", [row]}}
          :error -> shorthand_rows(document)
        end
    end
  end

  def from_document(_document), do: :unsupported

  @doc """
  A one-line human summary of a stored document, for the route list.

  Never renders operator content as markup - the caller interpolates the string
  into escaped template text.
  """
  @spec summarize(term()) :: String.t()
  def summarize(document) when is_map(document) and map_size(document) == 0 do
    "matches every alert"
  end

  def summarize(document) do
    case from_document(document) do
      {:ok, {_combinator, []}} ->
        "matches every alert"

      {:ok, {combinator, rows}} ->
        Enum.map_join(rows, joiner(combinator), &summarize_row/1)

      :unsupported ->
        "custom expression"
    end
  end

  defp joiner("any"), do: " OR "
  defp joiner(_), do: " AND "

  defp summarize_row(%{"field" => field, "operator" => "exists", "value" => value}) do
    if value in ["false", false], do: "#{field} is absent", else: "#{field} exists"
  end

  defp summarize_row(%{"field" => field, "operator" => operator, "value" => value}) do
    "#{field} #{operator} #{value}"
  end

  defp summarize_row(_row), do: "invalid predicate"

  # --- rows -> document ------------------------------------------------------

  defp combinator(value) when value in @combinators, do: {:ok, value}
  defp combinator(_value), do: {:error, :invalid_combinator}

  defp predicates(rows) do
    rows
    |> Enum.map(&normalize_row/1)
    |> Enum.reject(&blank?/1)
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      case predicate(row) do
        {:ok, predicate} -> {:cont, {:ok, [predicate | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_row(%{} = row) do
    %{
      "field" => row |> Map.get("field", "") |> to_string() |> String.trim(),
      "operator" => row |> Map.get("operator", "equals") |> to_string() |> String.trim(),
      "value" => row |> Map.get("value", "") |> to_string()
    }
  end

  defp normalize_row(_row), do: %{"field" => "", "operator" => "equals", "value" => ""}

  defp blank?(%{"field" => ""}), do: true
  defp blank?(_row), do: false

  defp predicate(%{"field" => field, "operator" => operator, "value" => value}) do
    cond do
      not Fields.route_field?(field) -> {:error, {:unknown_field, field}}
      operator not in @operators -> {:error, {:unknown_operator, operator}}
      true -> {:ok, %{"field" => field, operator => operand(operator, value)}}
    end
  end

  # `in` takes a non-empty list; a blank entry would be a null the operator did
  # not type, so blanks are dropped rather than sent as nil.
  defp operand("in", value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&scalar/1)
  end

  defp operand("exists", value), do: truthy?(value)
  defp operand("matches", value), do: String.trim(value)
  defp operand("contains", value), do: scalar(String.trim(value))
  defp operand(_operator, value), do: scalar(String.trim(value))

  # A numeric alert attribute compared against the string "5" never matches, so
  # an unambiguous numeric or boolean literal is cast. Anything else stays a
  # string - this is a cast, not an expression evaluator.
  defp scalar("true"), do: true
  defp scalar("false"), do: false
  defp scalar("null"), do: nil

  defp scalar(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} ->
        int

      _ ->
        case Float.parse(value) do
          {float, ""} -> float
          _ -> value
        end
    end
  end

  defp scalar(value), do: value

  defp truthy?(value), do: value in [true, "true", "1", "on", "yes"]

  # --- document -> rows ------------------------------------------------------

  defp rows(list, combinator) do
    list
    |> Enum.reduce_while({:ok, []}, fn node, {:ok, acc} ->
      case predicate_row(node) do
        {:ok, row} -> {:cont, {:ok, [row | acc]}}
        :error -> {:halt, :unsupported}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, {combinator, Enum.reverse(acc)}}
      :unsupported -> :unsupported
    end
  end

  defp predicate_row(%{"field" => field} = node) when is_binary(field) do
    node
    |> Map.delete("field")
    |> Map.to_list()
    |> case do
      [{operator, operand}] when operator in @operators ->
        {:ok, %{"field" => field, "operator" => operator, "value" => display(operand)}}

      _other ->
        :error
    end
  end

  defp predicate_row(_node), do: :error

  defp shorthand_rows(%{} = document) do
    document
    |> Enum.reduce_while({:ok, []}, fn
      {path, value}, {:ok, acc} when is_binary(path) ->
        if is_map(value) or is_list(value) do
          {:halt, :unsupported}
        else
          {:cont, {:ok, [%{"field" => path, "operator" => "equals", "value" => display(value)} | acc]}}
        end

      _pair, _acc ->
        {:halt, :unsupported}
    end)
    |> case do
      {:ok, acc} -> {:ok, {"all", Enum.reverse(acc)}}
      :unsupported -> :unsupported
    end
  end

  defp display(value) when is_list(value), do: Enum.map_join(value, ", ", &display/1)
  defp display(nil), do: "null"
  defp display(value) when is_binary(value), do: value
  defp display(value), do: to_string(value)
end
