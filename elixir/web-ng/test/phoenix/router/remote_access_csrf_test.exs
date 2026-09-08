defmodule ServiceRadarWebNGWeb.Router.RemoteAccessCSRFTest do
  use ExUnit.Case, async: true

  @mutating_verbs [:delete, :patch, :post, :put]
  @router_path Path.expand("../../../lib/serviceradar_web_ng_web/router.ex", __DIR__)

  test "api_auth keeps CSRF protection enabled for cookie-authenticated JSON APIs" do
    assert :protect_from_forgery in pipeline_plugs(router_ast(), :api_auth)
  end

  test "mutating remote-access API routes stay in the CSRF-protected api_auth pipeline" do
    violations =
      router_ast()
      |> router_scopes()
      |> Enum.flat_map(fn scope ->
        if :api_auth in scope.pipes do
          []
        else
          scope.routes
        end
      end)
      |> Enum.filter(&mutating_remote_access_route?/1)

    assert violations == []
  end

  defp router_ast do
    @router_path
    |> File.read!()
    |> Code.string_to_quoted!()
  end

  defp router_scopes(ast) do
    {_ast, scopes} =
      Macro.prewalk(ast, [], fn
        {:scope, _meta, args} = node, scopes ->
          {node, [scope_info(args) | scopes]}

        node, scopes ->
          {node, scopes}
      end)

    scopes
  end

  defp scope_info(args) do
    block = keyword_block(List.last(args))

    %{
      pipes: pipeline_calls(block),
      routes: route_calls(block)
    }
  end

  defp pipeline_plugs(ast, pipeline_name) do
    {_ast, plugs} =
      Macro.prewalk(ast, [], fn
        {:pipeline, _meta, [^pipeline_name, [do: block]]} = node, _plugs ->
          {node, plug_calls(block)}

        node, plugs ->
          {node, plugs}
      end)

    plugs
  end

  defp pipeline_calls(nil), do: []

  defp pipeline_calls(block) do
    block
    |> block_expressions()
    |> Enum.flat_map(fn
      {:pipe_through, _meta, [pipes]} -> List.wrap(pipes)
      _other -> []
    end)
  end

  defp plug_calls(nil), do: []

  defp plug_calls(block) do
    block
    |> block_expressions()
    |> Enum.flat_map(fn
      {:plug, _meta, [plug | _opts]} -> [plug]
      _other -> []
    end)
  end

  defp route_calls(nil), do: []

  defp route_calls(block) do
    {_block, routes} =
      Macro.prewalk(block, [], fn
        {verb, _meta, [path | _rest]} = node, routes
        when verb in @mutating_verbs and is_binary(path) ->
          {node, [%{verb: verb, path: path} | routes]}

        node, routes ->
          {node, routes}
      end)

    routes
  end

  defp mutating_remote_access_route?(%{path: "/remote-access" <> _suffix}), do: true
  defp mutating_remote_access_route?(_route), do: false

  defp block_expressions({:__block__, _meta, expressions}), do: expressions
  defp block_expressions(nil), do: []
  defp block_expressions(expression), do: [expression]

  defp keyword_block(do: block), do: block
  defp keyword_block(keyword) when is_list(keyword), do: Keyword.get(keyword, :do)
  defp keyword_block(_other), do: nil
end
