defmodule ServiceRadarWebNG.DeclarativeChecks do
  @moduledoc """
  Web-facing context operations for declarative service and posture checks.

  Wraps `ServiceRadar.DeclarativeChecks`, `Exporter`, `Importer`, `LegacyImporter`,
  `SchemaValidator`, and `TestRunner` with authenticated `ServiceRadarWebNG.Accounts.Scope`
  propagation and canonical JSON-ready map serialization.
  """

  alias ServiceRadar.DeclarativeChecks, as: CoreDeclarativeChecks
  alias ServiceRadar.DeclarativeChecks.CanonicalJSON
  alias ServiceRadar.DeclarativeChecks.DeclarativeCheck
  alias ServiceRadar.DeclarativeChecks.Exporter
  alias ServiceRadar.DeclarativeChecks.Importer
  alias ServiceRadar.DeclarativeChecks.LegacyImporter
  alias ServiceRadar.DeclarativeChecks.SchemaValidator
  alias ServiceRadar.DeclarativeChecks.TestRunner
  alias ServiceRadarWebNG.NetworkCredentials

  require Ash.Query

  @spec supported_posture_evaluators() :: [String.t()]
  def supported_posture_evaluators do
    SchemaValidator.supported_posture_evaluators()
  end

  @spec canonical_pretty_json(map()) :: String.t()
  def canonical_pretty_json(doc) when is_map(doc) do
    doc
    |> CanonicalJSON.to_canonical_export_map()
    |> CanonicalJSON.encode_pretty()
  end

  @spec validate_document(map() | String.t(), keyword()) ::
          {:ok, map(), String.t()} | {:error, term()}
  def validate_document(raw_json, opts \\ [])

  def validate_document(raw_json, opts) when is_binary(raw_json) do
    case Jason.decode(raw_json) do
      {:ok, map} when is_map(map) ->
        validate_document(map, opts)

      {:ok, _other} ->
        {:error,
         %{
           kind: :schema_validation,
           errors: [%{path: "$", code: "invalid_type", message: "root JSON value must be an object"}]
         }}

      {:error, err} ->
        {:error,
         %{
           kind: :invalid_json,
           errors: [%{path: "$", code: "invalid_json", message: Exception.message(err)}]
         }}
    end
  end

  def validate_document(doc_map, opts) when is_map(doc_map) do
    c_opts =
      opts
      |> core_opts()
      |> Keyword.put_new(:skip_srql_nif?, true)

    case SchemaValidator.validate_document(doc_map, c_opts) do
      {:ok, normalized} ->
        export_map = CanonicalJSON.to_canonical_export_map(normalized)
        {:ok, export_map, CanonicalJSON.encode_pretty(export_map)}

      {:error, _reason} = error ->
        error
    end
  end

  @spec list_checks(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_checks(opts \\ []) do
    case CoreDeclarativeChecks.list_checks(core_opts(opts)) do
      {:ok, checks} -> {:ok, Enum.map(checks, &serialize_check(&1))}
      {:error, _reason} = error -> error
    end
  end

  @spec get_check(String.t(), keyword()) :: {:ok, map()} | {:error, :not_found | term()}
  def get_check(slug_or_id, opts \\ []) when is_binary(slug_or_id) do
    c_opts = core_opts(opts)

    case CoreDeclarativeChecks.get_check_with_bindings(slug_or_id, c_opts) do
      {:ok, %{check: check} = result} ->
        bindings = Map.get(result, :credential_bindings, [])
        rollup = Map.get(result, :instance_rollup, default_rollup())

        {:ok,
         serialize_check(check,
           credential_bindings: bindings,
           instance_rollup: rollup
         )}

      {:ok, check} ->
        {:ok, serialize_check(check)}

      {:error, :not_found} ->
        lookup_by_uuid_then_slug(slug_or_id, c_opts)

      {:error, _reason} = error ->
        error
    end
  end

  @spec create_check(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_check(attrs, opts \\ []) when is_map(attrs) do
    c_opts = core_opts(opts)

    case CoreDeclarativeChecks.create_check(attrs, c_opts) do
      {:ok, check} -> {:ok, reload_or_serialize(check, c_opts)}
      {:error, _reason} = error -> error
    end
  end

  @spec update_check(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def update_check(slug, attrs, opts \\ []) when is_binary(slug) and is_map(attrs) do
    c_opts = core_opts(opts)

    case CoreDeclarativeChecks.update_check(slug, attrs, c_opts) do
      {:ok, check} -> {:ok, reload_or_serialize(check, c_opts)}
      {:error, _reason} = error -> error
    end
  end

  @spec delete_check(String.t(), keyword()) :: :ok | {:error, term()}
  def delete_check(slug, opts \\ []) when is_binary(slug) do
    case CoreDeclarativeChecks.delete_check(slug, core_opts(opts)) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @spec export_check_json(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def export_check_json(slug, opts \\ []) when is_binary(slug) do
    export_opts =
      opts
      |> core_opts()
      |> Keyword.put_new(:pretty, true)

    Exporter.export_json(slug, export_opts)
  end

  @spec import_check(map() | String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def import_check(document, opts \\ []) when is_map(document) or is_binary(document) do
    c_opts = core_opts(opts)

    case Importer.import_document(document, c_opts) do
      {:ok, result} -> {:ok, serialize_import_result(result)}
      {:error, _reason} = error -> error
    end
  end

  @spec test_run(String.t() | map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def test_run(target_or_doc, params \\ %{}, opts \\ [])
      when (is_binary(target_or_doc) or is_map(target_or_doc)) and is_map(params) do
    TestRunner.run_ephemeral(target_or_doc, params, core_opts(opts))
  end

  @spec clone_service_check(map() | String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def clone_service_check(service_check_or_id, opts \\ []) do
    c_opts = core_opts(opts)

    with {:ok, draft_doc} <- LegacyImporter.from_service_check(service_check_or_id, c_opts) do
      unique_doc = ensure_unique_slug(draft_doc, opts)
      create_check(unique_doc, opts)
    end
  end

  @spec clone_composite_check(map() | String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def clone_composite_check(composite_check_or_id, opts \\ []) do
    c_opts = core_opts(opts)

    with {:ok, draft_doc} <- LegacyImporter.from_composite_check(composite_check_or_id, c_opts) do
      unique_doc = ensure_unique_slug(draft_doc, opts)
      create_check(unique_doc, opts)
    end
  end

  @spec list_credential_options(keyword()) :: %{secrets: [map()], rules: [map()]}
  def list_credential_options(opts \\ []) do
    case Keyword.get(opts, :scope) do
      nil ->
        %{secrets: [], rules: []}

      scope ->
        secrets =
          case safe_list_secrets(scope) do
            {:ok, rows} ->
              Enum.map(rows, fn row ->
                %{
                  "id" => to_string(row.id),
                  "name" => row.name,
                  "provider" => to_string(row.provider),
                  "credential_kind" => to_string(row.credential_kind)
                }
              end)

            _ ->
              []
          end

        rules =
          case safe_list_rules(scope) do
            {:ok, rows} ->
              Enum.map(rows, fn row ->
                %{
                  "id" => to_string(row.id),
                  "name" => row.name,
                  "provider" => to_string(row.provider),
                  "scope_type" => to_string(row.scope_type),
                  "scope_value" => row.scope_value,
                  "enabled" => row.enabled == true
                }
              end)

            _ ->
              []
          end

        %{secrets: secrets, rules: rules}
    end
  end

  defp safe_list_secrets(scope) do
    NetworkCredentials.list_secrets(scope: scope)
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp safe_list_rules(scope) do
    NetworkCredentials.list_rules(scope: scope)
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp ensure_unique_slug(doc, opts) when is_map(doc) do
    base_slug = to_string(doc["slug"] || "imported-check")
    slug = find_available_slug(base_slug, opts, 0)
    Map.put(doc, "slug", slug)
  end

  defp find_available_slug(base_slug, _opts, attempt) when attempt >= 25 do
    "#{String.slice(base_slug, 0, 110)}-draft-#{System.unique_integer([:positive])}"
  end

  defp find_available_slug(base_slug, opts, 0) do
    case get_check(base_slug, opts) do
      {:error, :not_found} -> base_slug
      {:ok, _} -> find_available_slug(base_slug, opts, 1)
      _ -> base_slug
    end
  end

  defp find_available_slug(base_slug, opts, attempt) do
    suffix = if attempt == 1, do: "-draft", else: "-draft-#{attempt}"
    candidate = String.slice(base_slug, 0, max(1, 126 - byte_size(suffix))) <> suffix

    case get_check(candidate, opts) do
      {:error, :not_found} -> candidate
      {:ok, _} -> find_available_slug(base_slug, opts, attempt + 1)
      _ -> candidate
    end
  end

  defp lookup_by_uuid_then_slug(candidate, c_opts) do
    case Ecto.UUID.cast(candidate) do
      {:ok, uuid} ->
        actor = Keyword.get(c_opts, :actor)

        query =
          DeclarativeCheck
          |> Ash.Query.for_read(:read, %{}, actor: actor)
          |> Ash.Query.filter(id == ^uuid)
          |> Ash.Query.select([:id, :slug])
          |> Ash.Query.limit(1)

        case Ash.read_one(query, actor: actor) do
          {:ok, %{slug: slug}} when is_binary(slug) ->
            case CoreDeclarativeChecks.get_check_with_bindings(slug, c_opts) do
              {:ok, %{check: check} = result} ->
                {:ok,
                 serialize_check(check,
                   credential_bindings: Map.get(result, :credential_bindings, []),
                   instance_rollup: Map.get(result, :instance_rollup, default_rollup())
                 )}

              {:ok, check} ->
                {:ok, serialize_check(check)}

              {:error, _} = err ->
                err
            end

          {:ok, nil} ->
            {:error, :not_found}

          {:error, _} = err ->
            err
        end

      :error ->
        {:error, :not_found}
    end
  rescue
    _ -> {:error, :not_found}
  end

  defp reload_or_serialize(%{slug: slug} = check, c_opts) when is_binary(slug) do
    case CoreDeclarativeChecks.get_check_with_bindings(slug, c_opts) do
      {:ok, %{check: reloaded} = result} ->
        serialize_check(reloaded,
          credential_bindings: Map.get(result, :credential_bindings, []),
          instance_rollup: Map.get(result, :instance_rollup, default_rollup())
        )

      _ ->
        serialize_check(check)
    end
  end

  defp reload_or_serialize(check, _c_opts), do: serialize_check(check)

  defp serialize_check(check, opts \\ [])

  defp serialize_check(%_{} = check, opts) do
    serialized = CoreDeclarativeChecks.serialize_check(check, opts)

    serialized
    |> Map.put_new("credential_bindings", [])
    |> Map.put_new("instance_rollup", default_rollup())
  end

  defp serialize_check(check, _opts) when is_map(check) do
    check
    |> Map.put_new("credential_bindings", [])
    |> Map.put_new("instance_rollup", default_rollup())
  end

  defp serialize_import_result(result) when is_map(result) do
    action = Map.get(result, :action) || Map.get(result, "action") || :dry_run
    dry_run = Map.get(result, :dry_run, Map.get(result, "dry_run", false))
    check = Map.get(result, :check) || Map.get(result, "check")
    serialized_check = if is_nil(check), do: nil, else: serialize_check(check)

    preserved_overrides =
      cond do
        is_map(Map.get(result, :preserved_parameter_overrides)) ->
          Map.get(result, :preserved_parameter_overrides)

        is_map(Map.get(result, "preserved_parameter_overrides")) ->
          Map.get(result, "preserved_parameter_overrides")

        is_map(serialized_check) and is_map(serialized_check["parameter_overrides"]) ->
          serialized_check["parameter_overrides"]

        true ->
          %{}
      end

    %{
      "action" => to_string(action),
      "dry_run" => dry_run == true,
      "template_fingerprint" => Map.get(result, :template_fingerprint) || Map.get(result, "template_fingerprint"),
      "preserved_parameter_overrides" => preserved_overrides,
      "warnings" => Map.get(result, :warnings) || Map.get(result, "warnings") || [],
      "document" => Map.get(result, :document) || Map.get(result, "document") || %{},
      "check" => serialized_check
    }
  end

  defp core_opts(opts) do
    scope = Keyword.get(opts, :scope)
    actor = Keyword.get(opts, :actor) || actor_from_scope(scope)

    opts
    |> Keyword.put(:scope, scope)
    |> Keyword.put(:actor, actor)
    |> Enum.reject(fn {key, value} ->
      is_nil(value) and key in [:state, :pack_id, :actor, :scope]
    end)
  end

  defp actor_from_scope(%{user: user, permissions: %MapSet{} = permissions}) when is_map(user) do
    user
    |> Map.take([:id, :email, :role, :role_profile_id])
    |> Map.put(:permissions, permissions)
  end

  defp actor_from_scope(%{user: user}) when not is_nil(user), do: user
  defp actor_from_scope(_), do: nil

  defp default_rollup do
    %{
      "total" => 0,
      "healthy" => 0,
      "degraded" => 0,
      "down" => 0,
      "unknown" => 0
    }
  end
end
