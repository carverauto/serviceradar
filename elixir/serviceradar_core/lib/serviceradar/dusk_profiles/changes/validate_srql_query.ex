defmodule ServiceRadar.DuskProfiles.Changes.ValidateSrqlQuery do
  @moduledoc """
  Validates that the target_query attribute is a valid SRQL query.

  If target_query is nil or empty, validation passes (no targeting = default behavior).
  If target_query is provided, it must parse successfully via the SRQL NIF.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :target_query) do
      nil ->
        changeset

      "" ->
        # Empty string is treated as nil (no targeting)
        Ash.Changeset.change_attribute(changeset, :target_query, nil)

      query when is_binary(query) ->
        validate_query(changeset, query)

      _other ->
        changeset
    end
  end

  defp validate_query(changeset, query) do
    # Ensure the query starts with "in:devices" (we only support device targeting)
    normalized_query =
      if String.starts_with?(query, "in:devices") do
        query
      else
        "in:devices " <> query
      end

    case ServiceRadarSRQL.Native.parse_ast(normalized_query) do
      {:ok, _ast_json} ->
        # Query is valid, store the normalized version
        Ash.Changeset.change_attribute(changeset, :target_query, normalized_query)

      {:error, reason} ->
        Ash.Changeset.add_error(changeset,
          field: :target_query,
          message: "Invalid SRQL query: #{reason}"
        )
    end
  end
end
