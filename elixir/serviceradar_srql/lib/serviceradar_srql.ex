defmodule ServiceRadarSRQL do
  @moduledoc """
  SRQL (ServiceRadar Query Language) shared library.

  This library provides Rust NIF bindings for SRQL parsing via `ServiceRadarSRQL.Native`.
  The NIF is shared between `serviceradar_core` and `web-ng` to enable SRQL query
  parsing in both the backend config compiler and the web layer.

  ## Usage

  Parse an SRQL query:

      {:ok, ast_json} = ServiceRadarSRQL.Native.parse_ast("in:devices hostname:prod-*")
      {:ok, ast} = Jason.decode(ast_json)

  Translate an SRQL query to SQL:

      {:ok, sql_json} = ServiceRadarSRQL.Native.translate("in:devices status:online", 100, nil, nil, nil)
      {:ok, result} = Jason.decode(sql_json)

  ## Architecture

  - `serviceradar_srql` - This library (NIF parsing only)
  - `web-ng` - Uses NIF + AshAdapter for web layer queries
  - `serviceradar_core` - Uses NIF for sysmon profile SRQL resolution
  """

  use Boundary, exports: :all
end
