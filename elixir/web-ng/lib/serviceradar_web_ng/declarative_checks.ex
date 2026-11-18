defmodule ServiceRadarWebNG.DeclarativeChecks do
  @moduledoc """
  Web-facing context operations for declarative service and posture checks.

  Wraps `ServiceRadar.DeclarativeChecks`, `Exporter`, `Importer`, and `TestRunner`
  with authenticated `ServiceRadarWebNG.Accounts.Scope` propagation and canonical
  JSON-ready map serialization.
  """

  alias ServiceRadar.DeclarativeChecks, as: CoreDeclarativeChecks
  alias ServiceRadar.DeclarativeChecks.Exporter
  alias ServiceRadar.DeclarativeChecks.Importer
  alias ServiceRadar.DeclarativeChecks.TestRunner

  @spec list_checks(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_checks(opts \\ []) do
    case CoreDeclarativeChecks.list_checks(core_opts(opts)) do
      {:ok, checks} -> {:ok, Enum.map(checks, &serialize_check(&1))}
      {:error, _reason} = error -> error
    end
  end

  @spec get_check(String.t(), keyword()) :: {:ok, map()} | {:error, :not_found | term()}
  def get_check(slug, opts \\ []) when is_binary(slug) do
    case CoreDeclarativeChecks.get_check_with_bindings(slug, core_opts(opts)) do
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
