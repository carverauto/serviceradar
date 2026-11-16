defmodule ServiceRadar.Validations.TargetQuery do
  @moduledoc """
  Validates the SRQL target queries an attribute stores, with
  `ServiceRadar.SRQLTargetQuery.validate/2`.

  Options:

    * `:attribute` -- the attribute holding the queries (required).
    * `:default_target` -- the entity a query that names none targets
      (default `:devices`).
    * `:entity` -- the only entity a query may target. Without it any entity
      the parser accepts is allowed.
    * `:required?` -- whether a blank query is an error (default `false`, where
      a blank query means "no target query").
    * `:shape` -- where the queries sit in the attribute value:
      * `:query` (default) -- the value is the query;
      * `{:map, keys}` -- the value is a map holding the query under the first
        of `keys` present;
      * `:input_definitions` -- the value is a list of plugin input
        definitions, each holding a `query` for its own `entity`.

  The queries are validated on create and when an update changes them. An
  update that leaves a query as stored, including one that changes other parts
  of the attribute holding it, keeps that query, so a query saved before a rule
  existed does not block unrelated edits.
  """

  use Ash.Resource.Validation

  alias Ash.Changeset.OriginalDataNotAvailable
  alias ServiceRadar.Plugins.ValueUtils
  alias ServiceRadar.SRQLTargetQuery
  alias ServiceRadar.Validations.ProposedValue

  @impl true
  def init(opts) do
    case Keyword.get(opts, :attribute) do
      attribute when is_atom(attribute) and not is_nil(attribute) -> {:ok, opts}
      _ -> {:error, "#{inspect(__MODULE__)} requires an :attribute option"}
    end
  end

  @impl true
  def validate(changeset, opts, _context) do
    attribute = Keyword.fetch!(opts, :attribute)

    if changeset.action_type == :create or
         Ash.Changeset.changing_attribute?(changeset, attribute) do
      changeset
      |> Ash.Changeset.get_attribute(attribute)
      |> validate_value(stored_queries(changeset, opts), opts)
    else
      :ok
    end
  end

  # An atomic update reads the value it is about to write. A single-record
  # update carries the stored row to compare against; a bulk update does not,
  # so a query nested in a larger value cannot be told apart from its stored
  # copy there and the update must load the row.
  @impl true
  def atomic(changeset, opts, _context) do
    attribute = Keyword.fetch!(opts, :attribute)

    case ProposedValue.fetch(changeset, attribute) do
      :unchanged -> :ok
      {:changed, value} -> validate_atomic(value, changeset, opts)
      {:not_atomic, _reason} = not_atomic -> not_atomic
    end
  end

  defp validate_atomic(value, %{data: %OriginalDataNotAvailable{}}, opts) do
    if Keyword.get(opts, :shape, :query) == :query do
      validate_value(value, [], opts)
    else
      {:not_atomic,
       "#{Keyword.fetch!(opts, :attribute)} nests its target queries, so the stored " <>
         "value is needed to tell which of them changed"}
    end
  end

  defp validate_atomic(value, changeset, opts) do
    validate_value(value, stored_queries(changeset, opts), opts)
  end

  defp stored_queries(%{action_type: :create}, _opts), do: []

  defp stored_queries(changeset, opts) do
    changeset.data
    |> Map.get(Keyword.fetch!(opts, :attribute))
    |> queries(Keyword.get(opts, :shape, :query), Keyword.get(opts, :default_target, :devices))
  end

  defp validate_value(value, stored_queries, opts) do
    value
    |> queries(Keyword.get(opts, :shape, :query), Keyword.get(opts, :default_target, :devices))
    |> Enum.reject(&(&1 in stored_queries))
    |> Enum.find_value(:ok, &query_error(&1, opts))
  end

  defp queries(value, :query, default_target), do: [{value, default_target}]

  defp queries(value, {:map, keys}, default_target) when is_map(value),
    do: [{Enum.find_value(keys, &Map.get(value, &1)), default_target}]

  defp queries(_value, {:map, _keys}, _default_target), do: []

  defp queries(definitions, :input_definitions, default_target) when is_list(definitions) do
    for definition when is_map(definition) <- definitions do
      entity = ValueUtils.string_value(definition, [:entity, "entity"])

      {ValueUtils.string_value(definition, [:query, "query"]),
       if(ValueUtils.blank_string?(entity),
         do: default_target,
         else: ValueUtils.normalize_entity(entity)
       )}
    end
  end

  defp queries(_value, :input_definitions, _default_target), do: []

  defp query_error({query, default_target}, opts) do
    attribute = Keyword.fetch!(opts, :attribute)

    cond do
      is_binary(query) and String.trim(query) != "" ->
        case SRQLTargetQuery.validate(query,
               default_target: default_target,
               entity: Keyword.get(opts, :entity)
             ) do
          {:ok, _normalized} -> nil
          {:error, message} -> {:error, field: attribute, message: message}
        end

      not (is_nil(query) or is_binary(query)) ->
        {:error, field: attribute, message: "must be an SRQL query"}

      Keyword.get(opts, :required?, false) ->
        {:error, field: attribute, message: "is required"}

      true ->
        nil
    end
  end
end
