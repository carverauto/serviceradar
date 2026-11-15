defmodule ServiceRadar.Changes.ValidateTargetQuery do
  @moduledoc """
  Validates a profile's or sweep group's target query with
  `ServiceRadar.SRQLTargetQuery.validate/2` and stores it with its entity made
  explicit. A blank query is stored as `nil`.

  The query is checked on create and when an update changes it, so a query
  saved before a rule existed does not block unrelated edits.
  """

  alias Ash.Changeset
  alias ServiceRadar.SRQLTargetQuery

  def change(changeset, opts) do
    field = Keyword.get(opts, :field, :target_query)

    if changeset.action_type == :create or Changeset.changing_attribute?(changeset, field) do
      normalize(changeset, field, opts)
    else
      changeset
    end
  end

  defp normalize(changeset, field, opts) do
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
    case SRQLTargetQuery.validate(query,
           default_target: Keyword.get(opts, :default_target, :devices)
         ) do
      {:ok, normalized_query} ->
        Changeset.change_attribute(changeset, field, normalized_query)

      {:error, message} ->
        Changeset.add_error(changeset, field: field, message: message)
    end
  end
end
