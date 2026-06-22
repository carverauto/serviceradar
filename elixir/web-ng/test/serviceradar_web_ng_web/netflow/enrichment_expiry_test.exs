defmodule ServiceRadarWebNGWeb.Netflow.EnrichmentExpiryTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.Netflow.EnrichmentExpiry

  @moduletag :unit
  @moduletag :db_free

  test "sql predicate is self-parenthesized" do
    assert EnrichmentExpiry.sql("src_geo") ==
             "(src_geo.expires_at IS NULL OR src_geo.expires_at > now())"
  end
end
