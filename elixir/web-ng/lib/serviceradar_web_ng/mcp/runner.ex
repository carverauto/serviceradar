defmodule ServiceRadarWebNG.Mcp.Runner do
  @moduledoc false

  alias Ash.Error.Action.InvalidArgument
  alias Ash.Error.Forbidden
  alias ServiceRadarWebNG.Api.Access
  alias ServiceRadarWebNG.Mcp.Audit
  alias ServiceRadarWebNG.Mcp.Docs
  alias ServiceRadarWebNG.Mcp.IdentityDiagnostics

  @spec execute_srql(Ash.ActionInput.t(), map()) :: {:ok, map()} | {:error, term()}
  def execute_srql(input, context) do
    query = input.arguments.query

    limit =
      case input.arguments[:limit] do
        nil -> nil
        value -> Access.clamp_limit(value)
      end

    run_tool(context, :execute_srql, input.arguments, [query: query], fn ->
      case Access.execute_query(scope!(context), %{"query" => query, "limit" => limit}) do
        {:ok, response} -> {:ok, response, row_count(response)}
        {:error, reason} -> {:error, format_error(reason)}
      end
    end)
  end

  @spec get_srql_catalog(Ash.ActionInput.t(), map()) :: {:ok, map()} | {:error, term()}
  def get_srql_catalog(input, context) do
    entity = input.arguments[:entity]

    run_tool(context, :get_srql_catalog, input.arguments, [], fn ->
      catalog = Access.srql_catalog(scope!(context))

      case Access.slice_srql_catalog(catalog, entity) do
        {:ok, sliced} -> {:ok, sliced, map_size(sliced["entities"] || %{})}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @spec lookup_srql_docs(Ash.ActionInput.t(), map()) :: {:ok, map()} | {:error, term()}
  def lookup_srql_docs(input, context) do
    query = input.arguments.query

    run_tool(context, :lookup_srql_docs, input.arguments, [query: query], fn ->
      case Docs.lookup(query, scope!(context)) do
        {:ok, payload} -> {:ok, payload, payload["hit_count"] || 0}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @spec srql_grammar(Ash.ActionInput.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def srql_grammar(_input, _context), do: {:ok, Docs.grammar()}

  @spec srql_cookbook(Ash.ActionInput.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def srql_cookbook(_input, _context), do: {:ok, Docs.cookbook()}

  @spec srql_entities(Ash.ActionInput.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def srql_entities(_input, context), do: {:ok, Docs.entity_index(scope!(context))}

  @spec list_devices(Ash.ActionInput.t(), map()) :: {:ok, map()} | {:error, term()}
  def list_devices(input, context) do
    args = input.arguments

    opts = %{
      limit: Access.clamp_limit(args[:limit]),
      offset: Access.clamp_offset(args[:offset]),
      search: args[:search],
      status: args[:status],
      gateway_id: args[:gateway_id],
      device_type: args[:device_type]
    }

    run_tool(context, :list_devices, args, [], fn ->
      devices = Access.list_devices(scope!(context), opts)

      payload = %{
        "data" => Enum.map(devices, &Access.device_to_map/1),
        "count" => length(devices)
      }

      {:ok, payload, length(devices)}
    end)
  end

  @spec get_device(Ash.ActionInput.t(), map()) :: {:ok, map()} | {:error, term()}
  def get_device(input, context) do
    uid = input.arguments.uid

    run_tool(context, :get_device, input.arguments, [], fn ->
      case Access.get_device(scope!(context), uid) do
        {:ok, device} -> {:ok, %{"data" => Access.device_to_map(device)}, 1}
        {:error, :not_found} -> {:error, "device not found"}
        {:error, {:invalid, reason}} -> {:error, reason}
      end
    end)
  end

  @spec trace_device_identity(Ash.ActionInput.t(), map()) :: {:ok, map()} | {:error, term()}
  def trace_device_identity(input, context) do
    args = input.arguments
    seed = args.seed

    run_tool(context, :trace_device_identity, args, [], fn ->
      case IdentityDiagnostics.trace(scope!(context), seed, limit: args[:limit]) do
        {:ok, payload} -> {:ok, payload, trace_row_count(payload)}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @spec explain_identity_reconciliation(Ash.ActionInput.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def explain_identity_reconciliation(input, context) do
    args = input.arguments

    opts = [
      run_id: args[:run_id],
      time: args[:time],
      include_evidence: args[:include_evidence] == true,
      limit: args[:limit]
    ]

    run_tool(context, :explain_identity_reconciliation, args, [], fn ->
      case IdentityDiagnostics.explain(scope!(context), opts) do
        {:ok, payload} -> {:ok, payload, payload["run_count"] || 0}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp trace_row_count(payload) do
    ["merge_chain", "revivals", "identifiers", "evidence"]
    |> Enum.map(fn key -> payload |> Map.get(key, []) |> length() end)
    |> Enum.sum()
  end

  defp run_tool(context, tool, args, extra, fun) when is_function(fun, 0) do
    started = System.monotonic_time(:millisecond)
    audit_opts = audit_opts(context, tool, args, extra)

    try do
      case fun.() do
        {:ok, payload, row_count} ->
          Audit.tool_called(
            Keyword.merge(audit_opts,
              status: :ok,
              row_count: row_count,
              duration_ms: System.monotonic_time(:millisecond) - started
            )
          )

          {:ok, payload}

        {:error, reason} ->
          formatted = format_error(reason)

          Audit.tool_denied(
            Keyword.merge(audit_opts,
              status: :error,
              error: formatted,
              duration_ms: System.monotonic_time(:millisecond) - started
            )
          )

          {:error, tool_error(reason, formatted)}
      end
    rescue
      error in Forbidden ->
        Audit.tool_denied(
          Keyword.merge(audit_opts,
            status: :forbidden,
            error: Exception.message(error),
            duration_ms: System.monotonic_time(:millisecond) - started
          )
        )

        reraise error, __STACKTRACE__
    end
  end

  defp audit_opts(context, tool, args, extra) do
    Keyword.merge(
      [
        tool: tool,
        actor_id: actor_id(context),
        oauth_client_id: context_get(context, :oauth_client_id),
        ip: context_get(context, :mcp_ip),
        argument_digest: Audit.argument_digest(args_map(args))
      ],
      extra
    )
  end

  defp args_map(%{} = args), do: Map.new(args, fn {k, v} -> {to_string(k), v} end)
  defp args_map(_), do: %{}

  defp scope!(context) do
    case context_get(context, :scope) do
      nil -> raise ArgumentError, "MCP tool ran without current_scope in Ash context"
      scope -> scope
    end
  end

  # Ash generic-action callbacks receive `%Ash.Resource.Actions.Implementation.Context{}`
  # with caller context on `:source_context`. Ash 3 also nests extras under `:shared`.
  defp context_get(%{source_context: %{} = ctx}, key), do: context_from_map(ctx, key)
  defp context_get(%{context: %{} = ctx}, key), do: context_from_map(ctx, key)
  defp context_get(_context, _key), do: nil

  defp context_from_map(ctx, key) do
    Map.get(ctx, key) || get_in(ctx, [:shared, key])
  end

  defp actor_id(%{actor: %{id: id}}), do: to_string(id)
  defp actor_id(_), do: nil

  defp row_count(%{"results" => results}) when is_list(results), do: length(results)
  defp row_count(%{results: results}) when is_list(results), do: length(results)
  defp row_count(_), do: nil

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(%{message: message}) when is_binary(message), do: message
  defp format_error(reason), do: inspect(reason)

  # AshAi.Tool.Errors.format/1 only renders types that implement
  # AshAi.ToToolError. A bare string becomes UnknownError and the MCP
  # client sees "unexpected error occurred". InvalidArgument is mapped.
  defp tool_error(%InvalidArgument{} = error, _formatted), do: error
  defp tool_error(%Ash.Error.Query.NotFound{} = error, _formatted), do: error
  defp tool_error(%Forbidden{} = error, _formatted), do: error

  defp tool_error(_reason, formatted) do
    InvalidArgument.exception(message: formatted)
  end
end
