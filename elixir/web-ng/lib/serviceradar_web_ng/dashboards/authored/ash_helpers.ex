defmodule ServiceRadarWebNG.Dashboards.Authored.AshHelpers do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      require Ash.Query

      defp read!(query, nil), do: Ash.read!(query)
      defp read!(query, scope), do: Ash.read!(query, scope: scope)

      defp read_one(query, scope) do
        result =
          case scope do
            nil -> Ash.read_one(query)
            _ -> Ash.read_one(query, scope: scope)
          end

        case result do
          {:ok, nil} -> {:error, :not_found}
          {:ok, record} -> {:ok, record}
          {:error, error} -> {:error, error}
        end
      end

      defp create(changeset, nil), do: Ash.create(changeset)
      defp create(changeset, scope), do: Ash.create(changeset, scope: scope)

      defp create_with_notifications(changeset, nil), do: Ash.create(changeset, return_notifications?: true)

      defp create_with_notifications(changeset, scope),
        do: Ash.create(changeset, scope: scope, return_notifications?: true)

      defp update(changeset, nil), do: Ash.update(changeset)
      defp update(changeset, scope), do: Ash.update(changeset, scope: scope)

      defp destroy(record, nil), do: Ash.destroy(record)
      defp destroy(record, scope), do: Ash.destroy(record, scope: scope)

      defp destroy_result(:ok), do: :ok
      defp destroy_result({:ok, _record}), do: :ok
      defp destroy_result({:error, error}), do: {:error, error}

      defp maybe_set_owner(changeset, scope) do
        case owner_id(scope) do
          user_id when is_binary(user_id) ->
            Ash.Changeset.force_change_attribute(changeset, :owner_id, user_id)

          _ ->
            changeset
        end
      end

      defp validate_dashboard_attrs(attrs) do
        slug = Map.get(attrs, :slug)

        cond do
          not is_binary(slug) ->
            {:ok, attrs}

          MapSet.member?(reserved_dashboard_slugs(), slug) ->
            {:error, {:reserved_dashboard_slug, slug}}

          route_ref_slug?(slug) ->
            {:error, {:route_ref_dashboard_slug, slug}}

          not Regex.match?(~r/^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$/, slug) ->
            {:error, {:invalid_dashboard_slug, slug}}

          true ->
            {:ok, attrs}
        end
      end

      defp route_ref_slug?(slug) when is_binary(slug), do: Regex.match?(~r/^\d{7}$/, slug)

      defp dashboard_lookup(value) when is_binary(value) do
        value = String.trim(value)

        cond do
          canonical_uuid?(value) ->
            {:id, value}

          Regex.match?(~r/^\d{7}$/, value) ->
            {dashboard_ref, ""} = Integer.parse(value)
            {:ref, dashboard_ref}

          true ->
            {:slug, slugify(value)}
        end
      end

      defp canonical_uuid?(value) when is_binary(value) do
        Regex.match?(
          ~r/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/,
          value
        )
      end

      defp clear_default_dashboard(scope) do
        scope
        |> list_dashboard_preferences()
        |> Enum.filter(& &1.is_default)
        |> Enum.reduce_while(:ok, fn preference, :ok ->
          case preference
               |> Ash.Changeset.for_update(:clear_default, %{})
               |> update(scope) do
            {:ok, _preference} -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
      end

      defp preference_attrs(scope, target_type, target_id, attrs) do
        attrs
        |> Map.put(:user_id, owner_id(scope))
        |> Map.put(:target_type, target_type)
        |> Map.put(:target_id, target_id)
        |> Map.put_new(:favorite, false)
        |> Map.put_new(:is_default, false)
        |> Map.put_new(:metadata, %{})
      end

      defp maybe_filter_status(query, []), do: query
      defp maybe_filter_status(query, statuses), do: Ash.Query.filter(query, status: [in: statuses])

      defp reserved_dashboard_slugs do
        MapSet.new([
          "new",
          "edit",
          "settings",
          "packages",
          "package",
          "default",
          "search",
          "service-availability-noc",
          "security-findings",
          "endpoint-inventory",
          "new-devices"
        ])
      end
    end
  end
end
