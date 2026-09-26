defmodule ServiceRadarWebNGWeb.Observability.ServiceFilter do
  @moduledoc """
  Reads and rewrites the OTel `service_name:` filter of an observability pane's
  SRQL query.

  "Service" is the OTel `service.name` resource attribute, not a monitored
  service check. The logs, traces and metrics panes all filter on it through a
  `service_name:` token; this module is the one place that finds that token,
  replaces it, and builds it, so the service picker, row links, tab carry and
  stat cards agree on what the current filter is.

  ## Emitting exact names

  The SRQL parser turns a *scalar* value containing `%` into a `LIKE`, and one
  starting with `<` or `>` into a comparison. List values are always exact. So
  an exact name is emitted as a quoted scalar (`service_name:"checkout"`) only
  when it is unambiguous, and otherwise -- and for more than one name -- as a
  list (`service_name:("pay%")`, `service_name:("checkout","billing")`).

  ## Mirroring the SRQL tokenizer

  Token boundaries follow `rust/srql/src/parser/tokens.rs`: whitespace splits
  tokens except inside quotes (`"`, `'`, backquote) or parentheses/brackets, and a
  backslash inside quotes escapes the next character. A list value goes
  through that escape pass twice (once when the query is tokenized, once when
  the list is split), so list items are escaped twice here.
  """

  @field "service_name"
  @max_selection 20

  @default_queries %{
    "logs" => "in:logs time:last_24h sort:timestamp:desc",
    "traces" => "in:otel_trace_summaries time:last_24h sort:timestamp:desc",
    "metrics" => "in:otel_metrics time:last_24h sort:timestamp:desc"
  }

  # Panes whose entity rejects a `%` wildcard on `service_name`. Trace
  # summaries match by array containment in `service_set`, which is exact.
  @wildcard_rejecting_tabs MapSet.new(["traces"])

  @typedoc """
  The pane's current positive `service_name:` filter.

    * `:none` -- no service filter.
    * `{:exact, names}` -- one or more exact names (a list value or a plain scalar).
    * `{:wildcard, pattern}` -- a scalar containing `%`, compiled to `ILIKE`.
    * `:unsupported` -- a comparison scalar, or more than one `service_name:`
      token; nothing here can represent it as a selection.
  """
  @type t :: :none | {:exact, [String.t()]} | {:wildcard, String.t()} | :unsupported

  @doc "Maximum number of services one filter may select."
  @spec max_selection() :: pos_integer()
  def max_selection, do: @max_selection

  @doc "The signal panes a service filter applies to."
  @spec signal_tabs() :: [String.t()]
  def signal_tabs, do: Map.keys(@default_queries)

  @doc "Default query for a signal pane, used as the base when carrying a filter."
  @spec default_query(String.t()) :: String.t() | nil
  def default_query(tab), do: Map.get(@default_queries, tab)

  @doc "Parse the positive `service_name:` filter out of an SRQL query."
  @spec parse(String.t() | nil) :: t()
  def parse(query) when is_binary(query) do
    case query |> tokenize() |> Enum.filter(&service_token?/1) do
      [] -> :none
      [token] -> token |> token_value() |> classify()
      _several -> :unsupported
    end
  end

  def parse(_query), do: :none

  @doc "The exact names selected by `query`, or `[]` when its filter is not exact."
  @spec selected_names(String.t() | nil) :: [String.t()]
  def selected_names(query) do
    case parse(query) do
      {:exact, names} -> names
      _other -> []
    end
  end

  @doc """
  Remove every positive `service_name:` token from `query`, keeping all other
  tokens in order. A negated `!service_name:` token is a different filter and
  is kept.
  """
  @spec strip(String.t() | nil) :: String.t()
  def strip(query) when is_binary(query) do
    query
    |> tokenize()
    |> Enum.reject(&service_token?/1)
    |> Enum.join(" ")
  end

  def strip(_query), do: ""

  @doc """
  Replace the service filter of `query` with `names` (exact). An empty list
  clears the filter. Every other token -- time, severity, source, sort -- is
  kept.
  """
  @spec put(String.t() | nil, [String.t()]) :: String.t()
  def put(query, names) when is_list(names) do
    stripped = strip(query)

    case token(names) do
      nil -> stripped
      token when stripped == "" -> token
      token -> stripped <> " " <> token
    end
  end

  @doc """
  Build the `service_name:` token matching exactly `names`, or nil for no names.
  """
  @spec token([String.t()]) :: String.t() | nil
  def token(names) when is_list(names) do
    case normalize_names(names) do
      [] -> nil
      [name] -> if scalar_safe?(name), do: ~s|#{@field}:"#{escape_scalar(name)}"|, else: list_token([name])
      several -> list_token(several)
    end
  end

  @doc """
  Clean a selection: trim, drop blanks, dedupe (first wins), keep order.
  Never truncates; callers enforce `max_selection/0` and say so.
  """
  @spec normalize_names([term()]) :: [String.t()]
  def normalize_names(names) when is_list(names) do
    names
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  @doc """
  Query for `target_tab` carrying the service filter of `source_query`.

  Returns `{query, outcome}`:

    * `{nil, :none}` -- nothing to carry.
    * `{query, :carried}` -- `query` is the target's default query plus the filter.
    * `{nil, :dropped}` -- the filter cannot be expressed on the target (a
      wildcard carried to trace summaries, or an unsupported filter); the
      target should say so.
  """
  @spec carry(String.t() | nil, String.t()) :: {String.t() | nil, :none | :carried | :dropped}
  def carry(source_query, target_tab) do
    base = default_query(target_tab)

    case {parse(source_query), base} do
      {_filter, nil} ->
        {nil, :none}

      {:none, _base} ->
        {nil, :none}

      {{:exact, names}, base} ->
        {put(base, names), :carried}

      {{:wildcard, pattern}, base} ->
        if MapSet.member?(@wildcard_rejecting_tabs, target_tab) do
          {nil, :dropped}
        else
          {base <> " " <> ~s|#{@field}:"#{escape_scalar(pattern)}"|, :carried}
        end

      {:unsupported, _base} ->
        {nil, :dropped}
    end
  end

  @doc """
  The value to hand the stats layer for `query`'s service filter.

    * `nil` -- no filter; cards show every service.
    * a list of exact names, or a wildcard pattern string.
    * `:all_services` -- the pane is filtered but the cards cannot be (a
      negated or unsupported filter); they must say they cover all services
      rather than pass for filtered numbers.
  """
  @spec stats_scope(String.t() | nil) :: nil | [String.t()] | String.t() | :all_services
  def stats_scope(query) do
    if negated?(query) do
      :all_services
    else
      case parse(query) do
        :none -> nil
        {:exact, names} -> names
        {:wildcard, pattern} -> pattern
        :unsupported -> :all_services
      end
    end
  end

  defp negated?(query) when is_binary(query), do: query |> tokenize() |> Enum.any?(&negated_token?/1)
  defp negated?(_query), do: false

  @doc "Short label for a trigger button: `All services`, the name, or `N services`."
  @spec label([String.t()]) :: String.t()
  def label([]), do: "All services"
  def label([name]), do: name
  def label(names) when is_list(names), do: "#{length(names)} services"

  # -- tokenizer -------------------------------------------------------------

  @doc false
  # Raw token text, quotes and escapes preserved, so a rejoined query is
  # byte-for-byte what the user typed apart from inter-token whitespace.
  @spec tokenize(String.t()) :: [String.t()]
  def tokenize(query) when is_binary(query) do
    {tokens, current, _state} =
      query
      |> String.graphemes()
      |> Enum.reduce({[], [], %{quote: nil, depth: 0, escape: false}}, &tokenize_char/2)

    tokens
    |> push_token(current)
    |> Enum.reverse()
  end

  defp tokenize_char(ch, {tokens, current, %{escape: true} = state}) do
    {tokens, [ch | current], %{state | escape: false}}
  end

  defp tokenize_char(ch, {tokens, current, %{quote: q} = state}) when is_binary(q) do
    cond do
      ch == "\\" -> {tokens, [ch | current], %{state | escape: true}}
      ch == q -> {tokens, [ch | current], %{state | quote: nil}}
      true -> {tokens, [ch | current], state}
    end
  end

  defp tokenize_char(ch, {tokens, current, state}) when ch in ["\"", "'", "`"] do
    {tokens, [ch | current], %{state | quote: ch}}
  end

  defp tokenize_char(ch, {tokens, current, state}) when ch in ["(", "["] do
    {tokens, [ch | current], %{state | depth: state.depth + 1}}
  end

  defp tokenize_char(ch, {tokens, current, state}) when ch in [")", "]"] do
    {tokens, [ch | current], %{state | depth: max(state.depth - 1, 0)}}
  end

  defp tokenize_char(ch, {tokens, current, %{depth: 0} = state}) do
    if String.trim(ch) == "" do
      {push_token(tokens, current), [], state}
    else
      {tokens, [ch | current], state}
    end
  end

  defp tokenize_char(ch, {tokens, current, state}), do: {tokens, [ch | current], state}

  defp push_token(tokens, current) do
    case current |> Enum.reverse() |> Enum.join() |> String.trim() do
      "" -> tokens
      token -> [token | tokens]
    end
  end

  defp service_token?(token) do
    case String.split(token, ":", parts: 2) do
      [key, _value] -> String.downcase(key) == @field
      _ -> false
    end
  end

  defp negated_token?("!" <> token), do: service_token?(token)
  defp negated_token?(_token), do: false

  # -- value decoding (mirrors parser/tokens.rs parse_value) -----------------

  defp token_value(token) do
    [_key, value] = String.split(token, ":", parts: 2)
    value |> unescape_quoted() |> parse_value()
  end

  defp classify({:list, names}) do
    case normalize_names(names) do
      [] -> :none
      names -> {:exact, names}
    end
  end

  defp classify({:scalar, ""}), do: :none

  defp classify({:scalar, value}) do
    cond do
      String.starts_with?(value, [">", "<"]) -> :unsupported
      String.contains?(value, "%") -> {:wildcard, value}
      true -> {:exact, [value]}
    end
  end

  defp parse_value(raw) do
    trimmed = String.trim(raw)

    if list_value?(trimmed) do
      items =
        trimmed
        |> String.slice(1..-2//1)
        |> split_list()
        |> Enum.map(&trim_quotes/1)
        |> Enum.reject(&(&1 == ""))

      {:list, items}
    else
      {:scalar, trim_quotes(trimmed)}
    end
  end

  defp list_value?(value) do
    (String.starts_with?(value, "(") and String.ends_with?(value, ")")) or
      (String.starts_with?(value, "[") and String.ends_with?(value, "]"))
  end

  defp trim_quotes(value) do
    value |> String.trim() |> String.trim("\"") |> String.trim("'")
  end

  # The tokenizer's escape pass: inside quotes a backslash is dropped and the
  # next character is kept literally. Quote characters themselves are kept.
  defp unescape_quoted(value) do
    {chars, _quote, _escape} =
      value
      |> String.graphemes()
      |> Enum.reduce({[], nil, false}, fn
        ch, {acc, q, true} -> {[ch | acc], q, false}
        "\\", {acc, q, false} when is_binary(q) -> {acc, q, true}
        ch, {acc, q, false} when is_binary(q) and ch == q -> {[ch | acc], nil, false}
        ch, {acc, q, false} when is_binary(q) -> {[ch | acc], q, false}
        ch, {acc, nil, false} when ch in ["\"", "'", "`"] -> {[ch | acc], ch, false}
        ch, {acc, nil, false} -> {[ch | acc], nil, false}
      end)

    chars |> Enum.reverse() |> Enum.join()
  end

  # parser/tokens.rs split_list: commas split outside quotes and brackets; the
  # escape pass runs again inside quotes.
  defp split_list(value) do
    {items, current, _state} =
      value
      |> String.graphemes()
      |> Enum.reduce({[], [], %{quote: nil, depth: 0, escape: false}}, &split_list_char/2)

    [current |> Enum.reverse() |> Enum.join() | items]
    |> Enum.reverse()
    |> Enum.map(&String.trim/1)
  end

  defp split_list_char(ch, {items, current, %{escape: true} = state}) do
    {items, [ch | current], %{state | escape: false}}
  end

  defp split_list_char(ch, {items, current, %{quote: q} = state}) when is_binary(q) do
    cond do
      ch == "\\" -> {items, current, %{state | escape: true}}
      ch == q -> {items, [ch | current], %{state | quote: nil}}
      true -> {items, [ch | current], state}
    end
  end

  defp split_list_char(ch, {items, current, state}) when ch in ["\"", "'", "`"] do
    {items, [ch | current], %{state | quote: ch}}
  end

  defp split_list_char(ch, {items, current, state}) when ch in ["(", "["] do
    {items, [ch | current], %{state | depth: state.depth + 1}}
  end

  defp split_list_char(ch, {items, current, state}) when ch in [")", "]"] do
    {items, [ch | current], %{state | depth: max(state.depth - 1, 0)}}
  end

  defp split_list_char(",", {items, current, %{depth: 0} = state}) do
    {[current |> Enum.reverse() |> Enum.join() | items], [], state}
  end

  defp split_list_char(ch, {items, current, state}), do: {items, [ch | current], state}

  # -- value encoding ---------------------------------------------------------

  defp scalar_safe?(name) do
    not String.contains?(name, "%") and not String.starts_with?(name, [">", "<"])
  end

  defp list_token(names) do
    items = Enum.map_join(names, ",", &~s|"#{escape_list_item(&1)}"|)
    "#{@field}:(#{items})"
  end

  # One escape pass: the tokenizer's.
  defp escape_scalar(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  # Two escape passes: `split_list` unescapes what survives the tokenizer.
  defp escape_list_item(value), do: value |> escape_scalar() |> escape_scalar()
end
