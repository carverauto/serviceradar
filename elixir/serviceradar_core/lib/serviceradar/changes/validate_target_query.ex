defmodule ServiceRadar.Changes.ValidateTargetQuery do
  @moduledoc false

  alias Ash.Changeset
  alias ServiceRadar.SRQLAst
  alias ServiceRadar.SRQLQuery

  def change(changeset, opts) do
    field = Keyword.get(opts, :field, :target_query)

    case Changeset.get_attribute(changeset, field) do
      nil ->
        changeset

      "" ->
        Changeset.change_attribute(changeset, field, nil)

      query when is_binary(query) ->
        validate_query(changeset, field, query, opts)

      _other ->
        changeset
    end
  end

  defp validate_query(changeset, field, query, opts) do
    normalized_query = normalize_query(query, opts)

    case SRQLAst.validate(normalized_query) do
      :ok ->
        Changeset.change_attribute(changeset, field, normalized_query)

      {:error, reason} ->
        Changeset.add_error(changeset,
          field: field,
          message: "Invalid SRQL query: #{reason}"
        )
    end
  end

  defp normalize_query(query, opts) do
    default_target = Keyword.get(opts, :default_target, :devices)
    SRQLQuery.ensure_target(query, default_target)
  end
end
