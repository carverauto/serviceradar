defmodule ServiceRadar.Identity.Validations.ProfileTimezone do
  @moduledoc false

  use Ash.Resource.Validation

  alias ServiceRadar.TimeZone

  @impl true
  def validate(changeset, _opts, context) do
    case Ash.Changeset.fetch_change(changeset, :timezone) do
      {:ok, timezone} -> validate_timezone(timezone, changeset, context)
      :error -> :ok
    end
  end

  @impl true
  def atomic(_changeset, _opts, _context),
    do: {:not_atomic, "profile timezone validation requires a PostgreSQL catalog read"}

  defp validate_timezone(timezone, changeset, context) do
    case TimeZone.validate_preference(timezone, query_option(changeset, context)) do
      {:ok, _timezone} ->
        :ok

      {:error, :invalid_timezone} ->
        {:error, field: :timezone, message: "is not a supported timezone"}

      {:error, :catalog_unavailable} ->
        {:error, field: :timezone, message: "timezone catalog is unavailable"}
    end
  end

  defp query_option(changeset, context) do
    query =
      Enum.find_value(
        [Map.get(changeset, :context, %{}), Map.get(context, :source_context, %{})],
        fn source ->
          source
          |> Map.get(:private, %{})
          |> Map.get(:time_zone_query)
        end
      )

    case query do
      query when is_function(query, 2) -> [query: query]
      _ -> []
    end
  end
end
