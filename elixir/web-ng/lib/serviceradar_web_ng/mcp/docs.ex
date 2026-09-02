defmodule ServiceRadarWebNG.Mcp.Docs do
  @moduledoc """
  AI-facing SRQL documents served as MCP resources.

  Grammar and cookbook are compact distillates in priv/mcp, not the human
  Docusaurus pages. The entity index is generated from the live SRQL catalog
  so composite-check entities stay in sync.
  """

  alias ServiceRadarWebNG.Api.Access

  @grammar_path Path.expand("../../../priv/mcp/srql-grammar.md", __DIR__)
  @cookbook_path Path.expand("../../../priv/mcp/srql-cookbook.md", __DIR__)
  @external_resource @grammar_path
  @external_resource @cookbook_path
  @grammar File.read!(@grammar_path)
  @cookbook File.read!(@cookbook_path)

  @spec grammar() :: String.t()
  def grammar, do: @grammar

  @spec cookbook() :: String.t()
  def cookbook, do: @cookbook

  @spec entity_index(term()) :: String.t()
  def entity_index(scope) do
    catalog = Access.srql_catalog(scope)
    entities = catalog["entities"] || %{}

    rows =
      entities
      |> Enum.sort_by(fn {id, _meta} -> to_string(id) end)
      |> Enum.map_join("\n", fn {id, meta} ->
        label = Map.get(meta, "label") || id
        default_filter = Map.get(meta, "default_filter_field") || ""
        default_time = Map.get(meta, "default_time") || ""

        "| `#{id}` | #{label} | `#{default_filter}` | #{default_time} |"
      end)

    """
    # SRQL entity index

    Use `in:<id>` as the entity token. Call `get_srql_catalog` with `entity`
    set to one id to load fields. The unfiltered catalog is ~#{map_size(entities)}
    entities — do not dump it unless you need every field.

    Grammar: `serviceradar://srql/grammar`. Recipes: `serviceradar://srql/cookbook`.

    | id | label | default filter | default time |
    |----|-------|----------------|--------------|
    #{rows}
    """
  end

  @max_query_bytes 200
  @max_hits 5

  @doc """
  Search grammar, cookbook, and the live catalog. Analogous to corrode's
  `lookup_crate_docs`: the agent passes a short query and gets the matching
  sections instead of ingesting every document.
  """
  @spec lookup(String.t(), term()) :: {:ok, map()} | {:error, String.t()}
  def lookup(query, scope) when is_binary(query) do
    trimmed = String.trim(query)

    cond do
      trimmed == "" ->
        {:error, "query is required. Examples: devices, time:, stats, ssh traffic"}

      byte_size(trimmed) > @max_query_bytes ->
        {:error, "query is too long (max #{@max_query_bytes} bytes)"}

      true ->
        tokens = tokenize(trimmed)
        entity_hint = entity_hint(trimmed)

        hits =
          (markdown_chunks(:grammar, @grammar) ++
             markdown_chunks(:cookbook, @cookbook) ++ catalog_chunks(scope))
          |> Enum.map(&scored(&1, trimmed, tokens, entity_hint))
          |> Enum.filter(&(&1.score > 0))
          |> Enum.sort_by(&{-&1.score, &1.title})
          |> Enum.take(@max_hits)

        {:ok, render_lookup(trimmed, hits)}
    end
  end

  def lookup(_query, _scope), do: {:error, "query must be a string"}

  defp tokenize(query) do
    query
    |> String.downcase()
    |> String.split(~r/[^a-z0-9:%_]+/u)
    |> Enum.flat_map(fn tok ->
      stripped = String.trim_trailing(tok, ":")

      if stripped != tok and stripped != "", do: [tok, stripped], else: [tok]
    end)
    |> Enum.reject(&(&1 in ["", "in", "the", "a", "an", "for", "how", "do", "i", "to"]))
    |> Enum.uniq()
  end

  defp entity_hint(query) do
    down = String.downcase(query)

    case Regex.run(~r/\bin:([a-z][a-z0-9_]*)/, down) do
      [_, id] -> id
      _ -> nil
    end
  end

  defp markdown_chunks(source, markdown) do
    markdown
    |> String.split(~r/\n(?=## )/)
    |> Enum.map(fn section ->
      title =
        section
        |> String.split("\n", parts: 2)
        |> hd()
        |> String.replace(~r/^#+/, "")
        |> String.trim()

      %{source: source, id: nil, title: title, body: String.trim(section)}
    end)
  end

  defp catalog_chunks(scope) do
    catalog = Access.srql_catalog(scope)
    entities = catalog["entities"] || %{}

    Enum.map(entities, fn {id, meta} ->
      id = to_string(id)
      label = Map.get(meta, "label") || id

      %{
        source: :catalog,
        id: id,
        title: "in:#{id} — #{label}",
        body: format_entity(id, meta)
      }
    end)
  end

  defp format_entity(id, meta) do
    fields = Map.get(meta, "fields") || %{}
    filter = Map.get(fields, "filter") || []
    boolean = Map.get(fields, "boolean") || []
    enums = Map.get(meta, "enums") || %{}
    default_filter = Map.get(meta, "default_filter_field") || ""
    default_time = Map.get(meta, "default_time") || ""

    enum_lines =
      enums
      |> Enum.sort_by(fn {field, _} -> to_string(field) end)
      |> Enum.map_join("\n", fn {field, values} ->
        shown = values |> Enum.take(12) |> Enum.join(", ")
        extra = max(length(values) - 12, 0)
        suffix = if extra > 0, do: ", …+#{extra}", else: ""
        "- `#{field}`: #{shown}#{suffix}"
      end)

    """
    Entity id: `#{id}`. Use `in:#{id}`.
    Default filter: `#{default_filter}`. Default time: `#{default_time}`.
    Filter fields: #{Enum.join(Enum.take(filter, 40), ", ")}#{if length(filter) > 40, do: ", …", else: ""}
    Boolean fields: #{Enum.join(boolean, ", ")}
    Enums:
    #{enum_lines}

    Call `get_srql_catalog` with `entity=#{id}` for the full field map.
    """
  end

  defp scored(chunk, query, tokens, entity_hint) do
    down_title = String.downcase(chunk.title)
    down_body = String.downcase(chunk.body)
    down_query = String.downcase(query)

    score =
      0
      |> boost(chunk.id && chunk.id == entity_hint, 120)
      |> boost(chunk.id && chunk.id == down_query, 110)
      |> boost(chunk.id && chunk.id in tokens, 90)
      |> boost(heading_has_all?(down_title, tokens), 50)
      |> add_token_score(down_title, tokens, 18)
      |> add_token_score(down_body, tokens, 4)
      |> boost(control_token_hit?(down_query, down_title), 40)

    Map.put(chunk, :score, score)
  end

  defp boost(score, true, n), do: score + n
  defp boost(score, false, _n), do: score
  defp boost(score, nil, _n), do: score

  defp heading_has_all?(_title, []), do: false

  defp heading_has_all?(title, tokens) do
    Enum.all?(tokens, &String.contains?(title, &1))
  end

  defp add_token_score(score, text, tokens, weight) do
    Enum.reduce(tokens, score, fn token, acc ->
      if String.contains?(text, token), do: acc + weight, else: acc
    end)
  end

  defp control_token_hit?(query, title) do
    controls = ~w(time stats bucket sort limit wildcard operator or cidr)
    Enum.any?(controls, &(String.contains?(query, &1) and String.contains?(title, &1)))
  end

  defp render_lookup(query, []) do
    %{
      "query" => query,
      "hit_count" => 0,
      "matches" => [],
      "text" => """
      No SRQL docs matched #{inspect(query)}.

      Try an entity id (`devices`, `logs`, `flows`), an operator (`time:`, `stats`, `bucket`),
      or a task (`ssh`, `cpu`, `alerts`). Full manuals: serviceradar://srql/grammar,
      serviceradar://srql/entities, serviceradar://srql/cookbook.
      """
    }
  end

  defp render_lookup(query, hits) do
    blocks =
      Enum.map_join(hits, "\n\n---\n\n", fn hit ->
        source = source_label(hit.source, hit.id)

        """
        ### #{hit.title}
        source: #{source}

        #{String.trim(hit.body)}
        """
      end)

    %{
      "query" => query,
      "hit_count" => length(hits),
      "matches" =>
        Enum.map(hits, fn hit ->
          %{
            "source" => source_label(hit.source, hit.id),
            "title" => hit.title,
            "score" => hit.score
          }
        end),
      "text" => """
      SRQL docs for #{inspect(query)} (#{length(hits)} hits). Use these to write `execute_srql`.

      #{blocks}
      """
    }
  end

  defp source_label(:grammar, _), do: "grammar"
  defp source_label(:cookbook, _), do: "cookbook"
  defp source_label(:catalog, id), do: "catalog:#{id}"
  defp source_label(other, _), do: to_string(other)
end
