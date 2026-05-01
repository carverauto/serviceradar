defmodule ServiceRadarWebNG.SRQL.Native do
  @moduledoc """
  Compatibility alias for ServiceRadarSRQL.Native.

  This module delegates to the shared SRQL library for backwards compatibility.
  New code should use ServiceRadarSRQL.Native directly.
  """

  defdelegate translate(query, limit, cursor, direction, mode), to: ServiceRadarSRQL.Native
  defdelegate parse_ast(query), to: ServiceRadarSRQL.Native
  defdelegate encode_arrow_json(columns, rows_json), to: ServiceRadarSRQL.Native
end
