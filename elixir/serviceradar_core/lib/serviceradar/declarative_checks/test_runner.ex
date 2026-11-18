defmodule ServiceRadar.DeclarativeChecks.TestRunner do
  @moduledoc """
  Bounded ephemeral execution runner (`TestDeclarativeCheck`, `3.5`) for
  interactive builder previews and `POST /api/v2/declarative-checks/test-run`.

  Requires `declarative_checks.evaluate` RBAC permission (or system actor),
  enforces a hard `<= 15_000ms` timeout, scrubs all secrets (`"[REDACTED]"`),
  and NEVER mutates `DeclarativeCheckInstance`, `ServiceState`, or alerts.
  """

  alias Ash.Error.Forbidden
  alias Ash.Error.Query.NotFound
  alias ServiceRadar.DeclarativeChecks.DAGEngine
  alias ServiceRadar.DeclarativeChecks.DeclarativeCheck
  alias ServiceRadar.DeclarativeChecks.SchemaValidator
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @default_timeout_ms 10_000
  @max_timeout_ms 15_000

  @doc """
  Executes a declarative check graph ephemerally.

  Accepts either `run_ephemeral(check_or_slug_or_doc, opts_keyword)` or
  `run_ephemeral(check_or_slug_or_doc, params_map, opts_keyword)`.
  """
  @spec run_ephemeral(DeclarativeCheck.t() | map() | String.t(), keyword() | map()) ::
          {:ok, map()} | {:error, term()}
  def run_ephemeral(target_spec, opts_or_params \\ [])

  def run_ephemeral(target_spec, opts) when is_list(opts) do
    run_ephemeral(target_spec, %{}, opts)
  end

  def run_ephemeral(target_spec, params) when is_map(params) do
    run_ephemeral(target_spec, params, [])
  end

  @spec run_ephemeral(DeclarativeCheck.t() | map() | String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def run_ephemeral(check_or_slug_or_doc, params, opts) when is_map(params) and is_list(opts) do
    with :ok <- authorize_evaluate(opts),
         {:ok, check_doc} <- resolve_and_validate_check(check_or_slug_or_doc, params, opts) do
      timeout_ms = resolve_timeout_ms(params, opts)
      target_ctx = extract_target_ctx(check_doc, params, opts)
      eval_opts = build_eval_opts(params, opts)

      run_bounded(check_doc, target_ctx, eval_opts, timeout_ms)
    end
  end

  defp run_bounded(check_doc, target_ctx, eval_opts, timeout_ms) do
    task =
      Task.async(fn ->
        DAGEngine.evaluate_target(check_doc, target_ctx, eval_opts)
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, res}} ->
        slug = to_string(Map.get(check_doc, :slug) || Map.get(check_doc, "slug") || "ephemeral")
        status_str = Atom.to_string(res.status)

        {:ok,
         %{
           "schema_version" => 1,
           "ephemeral" => true,
           "slug" => slug,
           "target_key" => res.target_key,
           "verdict" => res.verdict,
           "status" => status_str,
           "summary" => res.summary,
           "duration_ms" => res.duration_ms,
           "evaluated_at" => DateTime.to_iso8601(res.evaluated_at),
           "node_traces" => res.node_traces,
           "nodes" => res.node_traces
         }}

      {:ok, {:error, _} = err} ->
        err

      nil ->
        {:error, :test_run_timeout}
    end
  end

  defp resolve_and_validate_check(%DeclarativeCheck{} = check, _params, _opts) do
    {:ok, check}
  end

  defp resolve_and_validate_check(slug, _params, opts) when is_binary(slug) do
    actor = extract_actor(opts)

    case DeclarativeCheck.get_by_slug(slug, actor: actor) do
      {:ok, %DeclarativeCheck{} = check} -> {:ok, check}
      {:ok, nil} -> {:error, :not_found}
      {:error, %NotFound{}} -> {:error, :not_found}
      {:error, %Ash.Error.Invalid{errors: [%NotFound{} | _]}} -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  defp resolve_and_validate_check(%{"document" => inner}, _params, opts) when is_map(inner) do
    SchemaValidator.validate_document(inner, opts)
  end

  defp resolve_and_validate_check(doc, _params, opts) when is_map(doc) do
    if Map.has_key?(doc, "nodes") or Map.has_key?(doc, :nodes) do
      SchemaValidator.validate_document(doc, opts)
    else
      case Map.get(doc, "slug") || Map.get(doc, :slug) do
        slug when is_binary(slug) -> resolve_and_validate_check(slug, doc, opts)
        _ -> SchemaValidator.validate_document(doc, opts)
      end
    end
  end

  defp extract_target_ctx(check_doc, params, opts) do
    raw_target =
      Map.get(params, "target") ||
        Map.get(params, :target) ||
        Keyword.get(opts, :target) ||
        %{}

    binding =
      Map.get(check_doc, :target_binding) ||
        Map.get(check_doc, "target_binding") ||
        %{}

    Map.merge(
      %{
        "target_key" => "singleton",
        "url" => Map.get(binding, "url"),
        "host" => Map.get(binding, "host"),
        "port" => Map.get(binding, "port")
      },
      stringify_keys(raw_target)
    )
  end

  defp build_eval_opts(params, opts) do
    overrides =
      Map.get(params, "parameter_overrides") ||
        Map.get(params, :parameter_overrides) ||
        Keyword.get(opts, :parameter_overrides)

    edge_obs =
      Map.get(params, "edge_observations") ||
        Map.get(params, :edge_observations) ||
        Keyword.get(opts, :edge_observations)

    opts
    |> maybe_put_opt(:parameter_overrides, overrides)
    |> maybe_put_opt(:edge_observations, edge_obs)
  end

  defp resolve_timeout_ms(params, opts) do
    raw =
      Map.get(params, "timeout_ms") ||
        Map.get(params, :timeout_ms) ||
        Keyword.get(opts, :timeout_ms) ||
        @default_timeout_ms

    if is_integer(raw), do: raw |> max(100) |> min(@max_timeout_ms), else: @default_timeout_ms
  end

  defp authorize_evaluate(opts) do
    case extract_actor(opts) do
      nil ->
        {:error, Forbidden.exception([])}

      %{role: :system} ->
        :ok

      actor ->
        if ActorHasPermission.match?(actor, [permission: "declarative_checks.evaluate"], %{}) do
          :ok
        else
          {:error, Forbidden.exception([])}
        end
    end
  end

  defp extract_actor(opts) do
    ServiceRadar.DeclarativeChecks.extract_actor(opts)
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp stringify_keys(_), do: %{}

  defp maybe_put_opt(opts, _k, nil), do: opts
  defp maybe_put_opt(opts, k, v), do: Keyword.put(opts, k, v)
end
