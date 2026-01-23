defmodule ServiceRadar.SNMPProfiles.Changes.ValidateSrqlQuery do
  @moduledoc """
  Validates that the target_query attribute is a valid SRQL query.

  If target_query is nil or empty, validation passes (no targeting = default behavior).
  If target_query is provided, it must parse successfully via the SRQL NIF.

  Unlike sysmon profiles which only target devices, SNMP profiles can target
  both devices and interfaces:
  - `in:devices tags.role:network-monitor` - Target devices
  - `in:interfaces type:ethernet` - Target interfaces
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
    # Normalize the query - add "in:devices" prefix if no "in:" prefix exists
    normalized_query =
      cond do
        String.starts_with?(query, "in:devices") ->
          query

        String.starts_with?(query, "in:interfaces") ->
          query

        String.starts_with?(query, "in:") ->
          # Some other "in:" query - let it pass through for validation
          query

        true ->
          # Default to device targeting
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
