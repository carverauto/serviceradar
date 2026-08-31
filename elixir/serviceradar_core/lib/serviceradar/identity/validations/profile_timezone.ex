defmodule ServiceRadar.Identity.Validations.ProfileTimezone do
  @moduledoc false

  use Ash.Resource.Validation

  alias ServiceRadar.TimeZone

  @impl true
  def validate(changeset, _opts, context) do
    validate_timezone(Ash.Changeset.get_attribute(changeset, :timezone), changeset, context)
  end

  @impl true
  def atomic(changeset, _opts, context) do
    validate_timezone(pending_timezone(changeset), changeset, context)
  end

  defp pending_timezone(changeset) do
    with :error <- Keyword.fetch(changeset.atomics, :timezone),
         :error <- Ash.Changeset.fetch_change(changeset, :timezone) do
      case changeset.data do
        %{timezone: timezone} -> timezone
        _other -> nil
      end
    else
      {:ok, value} -> value
    end
  end

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
