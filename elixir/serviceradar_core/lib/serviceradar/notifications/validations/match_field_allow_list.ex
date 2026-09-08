defmodule ServiceRadar.Notifications.Validations.MatchFieldAllowList do
  @moduledoc """
  Restricts a predicate document to the field paths its evaluation context can
  actually resolve (design D6).

  `ServiceRadar.Notifications.MatchExpression` owns the grammar: combinators,
  operators, operand types, and the *syntax* of a dotted attribute path. It
  deliberately stops short of deciding which paths exist, because the resolvable
  set differs between routing and suppression. This validation is that missing
  half, supplied per resource, and it duplicates none of the grammar - it walks
  the document only far enough to collect the field paths and checks each one
  against an allow-list.

  Why it earns its place: without it, `alert.serverity` saves cleanly and
  produces a route that matches nothing, forever, silently. That is precisely
  the "why was I not paged?" failure design D5 exists to eliminate, arriving
  through the one door D5 does not watch - a typo, rather than a suppression
  decision. Turning it into a save-time error is the only place it is cheap to
  find.

  Anything this module does not recognise as a field-bearing node is left alone
  and reported by the grammar validator instead, so a malformed document yields
  one error rather than two.

  ## Options

  - `:attribute` (required) - the map attribute holding the document
  - `:fields` - exact allowed paths
  - `:field_prefixes` - allowed path prefixes, e.g. `"alert.metadata."`, which
    admit any non-empty continuation

  The allow-lists are passed in rather than hardcoded here so they stay module
  attributes on the resource that owns the evaluation context, where a reviewer
  reading routing behaviour will see them.
  """

  use Ash.Resource.Validation

  @impl true
  def init(opts) do
    case Keyword.get(opts, :attribute) do
      attribute when is_atom(attribute) and not is_nil(attribute) ->
        {:ok, opts}

      _other ->
        {:error,
         "#{inspect(__MODULE__)} requires an `:attribute` option naming the map attribute to check"}
    end
  end

  @impl true
  def validate(changeset, opts, _context) do
    attribute = Keyword.fetch!(opts, :attribute)

    case fetch_incoming(changeset, attribute) do
      {:ok, value} -> check(value, attribute, opts)
      :error -> :ok
    end
  end

  @impl true
  def atomic(changeset, opts, _context) do
    attribute = Keyword.fetch!(opts, :attribute)

    case fetch_incoming(changeset, attribute) do
      {:ok, value} ->
        # A predicate document computed in SQL has no literal to inspect.
        if Ash.Expr.expr?(value) do
          {:not_atomic,
           "#{inspect(__MODULE__)} cannot check the field paths of an expression-valued " <>
             "update of `#{attribute}`; set the predicate document as a literal value"}
        else
          check(value, attribute, opts)
        end

      :error ->
        :ok
    end
  end

  # `Ash.update/2` runs a `require_atomic?: true` action through
  # `Ash.Changeset.fully_atomic_changeset/4`, which parks accepted attribute
  # values in `changeset.atomics` rather than `changeset.attributes`. Consulting
  # only `fetch_change/2` would therefore check the PREVIOUS document on every
  # update and let a disallowed path through, so both are read.
  defp fetch_incoming(changeset, attribute) do
    case Ash.Changeset.fetch_change(changeset, attribute) do
      {:ok, value} -> {:ok, value}
      :error -> Keyword.fetch(changeset.atomics, attribute)
    end
  end

  defp check(value, attribute, opts) do
    rules = %{
      fields: opts |> Keyword.get(:fields, []) |> MapSet.new(),
      prefixes: Keyword.get(opts, :field_prefixes, [])
    }

    case walk(value, rules) do
      :ok ->
        :ok

      {:error, path} ->
        {:error,
         field: attribute,
         message:
           "references \"#{path}\", which is not a matchable field; " <>
             "the matchable set is #{describe_matchable(rules)}"}
    end
  end

  defp walk(node, rules) when is_map(node) and not is_struct(node) do
    normalized = normalize_keys(node)
    keys = Map.keys(normalized)

    cond do
      "all" in keys -> walk_branches(Map.get(normalized, "all"), rules)
      "any" in keys -> walk_branches(Map.get(normalized, "any"), rules)
      "not" in keys -> walk(Map.get(normalized, "not"), rules)
      "field" in keys -> check_path(Map.get(normalized, "field"), rules)
      true -> walk_shorthand(keys, rules)
    end
  end

  # Grammar violations belong to MatchExpression, not here.
  defp walk(_node, _rules), do: :ok

  defp walk_branches(branches, rules) when is_list(branches) do
    Enum.reduce_while(branches, :ok, fn branch, :ok ->
      case walk(branch, rules) do
        :ok -> {:cont, :ok}
        {:error, path} -> {:halt, {:error, path}}
      end
    end)
  end

  defp walk_branches(_branches, _rules), do: :ok

  defp walk_shorthand(keys, rules) do
    Enum.reduce_while(keys, :ok, fn key, :ok ->
      case check_path(key, rules) do
        :ok -> {:cont, :ok}
        {:error, path} -> {:halt, {:error, path}}
      end
    end)
  end

  defp check_path(path, rules) when is_binary(path) do
    if MapSet.member?(rules.fields, path) or Enum.any?(rules.prefixes, &prefixed?(path, &1)) do
      :ok
    else
      {:error, path}
    end
  end

  defp check_path(_path, _rules), do: :ok

  defp prefixed?(path, prefix) do
    String.starts_with?(path, prefix) and byte_size(path) > byte_size(prefix)
  end

  defp describe_matchable(rules) do
    exact = rules.fields |> Enum.sort() |> Enum.join(", ")

    case Enum.sort(rules.prefixes) do
      [] -> exact
      prefixes -> exact <> ", and any path under " <> Enum.join(prefixes, ", ")
    end
  end

  defp normalize_keys(map) do
    Map.new(map, fn {key, value} -> {key_to_string(key), value} end)
  end

  # Atom.to_string/1 on an existing key creates no atom. The reverse direction
  # is what the Iron Laws forbid, and it never happens here.
  defp key_to_string(key) when is_binary(key), do: key
  defp key_to_string(key) when is_atom(key) and not is_nil(key), do: Atom.to_string(key)
  # A non-string key is a grammar violation; MatchExpression reports it.
  defp key_to_string(_key), do: nil
end
