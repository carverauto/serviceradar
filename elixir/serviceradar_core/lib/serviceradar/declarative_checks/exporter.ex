defmodule ServiceRadar.DeclarativeChecks.Exporter do
  @moduledoc """
  Deterministic, secret-free canonical JSON exporter for `DeclarativeCheck` (`1.4`, `4.1`).

  Produces `schema_version: 1` canonical documents with sorted keys at every
  object level, omitting database UUIDs, `credential_secret_id`,
  `credential_rule_id`, and any secret material.
  """

  alias Ash.Error.Forbidden
  alias Ash.Error.Query.NotFound
  alias ServiceRadar.DeclarativeChecks.CanonicalJSON
  alias ServiceRadar.DeclarativeChecks.DeclarativeCheck
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @read_permissions [
    "declarative_checks.view",
    "declarative_checks.manage",
    "declarative_checks.evaluate"
  ]

  @doc """
  Exports a `DeclarativeCheck` struct, validated map, or `slug` string into a
  secret-free canonical `schema_version: 1` map.
  """
  @spec export_map(DeclarativeCheck.t() | map() | String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def export_map(check_or_slug, opts \\ []) when is_list(opts) do
    with :ok <- authorize_export(opts),
         {:ok, check} <- resolve_check(check_or_slug, opts) do
      {:ok, CanonicalJSON.to_canonical_export_map(check)}
    end
  end

  @doc """
  Exports a `DeclarativeCheck` struct, validated map, or `slug` string into a
  deterministic canonical JSON string (`pretty: true` by default).
  """
  @spec export_json(DeclarativeCheck.t() | map() | String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def export_json(check_or_slug, opts \\ []) when is_list(opts) do
    pretty? = Keyword.get(opts, :pretty, true)

    with {:ok, exported_map} <- export_map(check_or_slug, opts) do
      json =
        if pretty?,
          do: CanonicalJSON.encode_pretty(exported_map),
          else: CanonicalJSON.encode(exported_map)

      {:ok, json}
    end
  end

  defp resolve_check(%DeclarativeCheck{} = check, _opts), do: {:ok, check}
  defp resolve_check(map, _opts) when is_map(map), do: {:ok, map}

  defp resolve_check(slug, opts) when is_binary(slug) do
    actor = extract_actor(opts)

    case DeclarativeCheck.get_by_slug(slug, actor: actor) do
      {:ok, %DeclarativeCheck{} = check} -> {:ok, check}
      {:ok, nil} -> {:error, :not_found}
      {:error, %NotFound{}} -> {:error, :not_found}
      {:error, %Ash.Error.Invalid{errors: [%NotFound{} | _]}} -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  defp authorize_export(opts) do
    case extract_actor(opts) do
      nil ->
        {:error, Forbidden.exception([])}

      %{role: :system} ->
        :ok

      actor ->
        allowed? =
          Enum.any?(@read_permissions, fn perm ->
            ActorHasPermission.match?(actor, [permission: perm], %{})
          end)

        if allowed?, do: :ok, else: {:error, Forbidden.exception([])}
    end
  end

  defp extract_actor(opts) do
    ServiceRadar.DeclarativeChecks.extract_actor(opts)
  end
end
