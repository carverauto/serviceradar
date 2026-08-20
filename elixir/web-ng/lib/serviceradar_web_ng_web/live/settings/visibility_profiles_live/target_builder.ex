defmodule ServiceRadarWebNGWeb.Settings.VisibilityProfilesLive.TargetBuilder do
  @moduledoc """
  Visibility-profile-facing names for the shared SRQL scope builder.

  The implementation moved to `ServiceRadarWebNGWeb.SRQL.ScopeBuilder` when
  composite checks needed the same round-trip. This shim keeps the call sites
  and the `target_query` vocabulary this LiveView is written in.
  """

  alias ServiceRadarWebNGWeb.SRQL.ScopeBuilder

  defdelegate default_builder_state(), to: ScopeBuilder
  defdelegate update_builder(builder, params), to: ScopeBuilder

  defdelegate parse_target_query_to_builder(query), to: ScopeBuilder, as: :parse_query_to_builder
  defdelegate build_target_query(builder), to: ScopeBuilder, as: :build_query
end
