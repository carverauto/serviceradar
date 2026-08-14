defmodule ServiceRadarWebNGWeb.Settings.NotificationsLive.DeliveryFiltersTest do
  @moduledoc """
  Delivery Log filter parsing.

  Two properties are load bearing: a filtered view must be shareable (so parse
  and serialise are inverses), and an unrecognised enumerated value must DROP the
  filter rather than becoming one - and must never mint an atom.
  """

  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.Settings.NotificationsLive.DeliveryFilters

  @moduletag :db_free

  @alert_id "018f7a10-0000-7000-8000-000000000001"
  @channel_id "018f7a10-0000-7000-8000-000000000002"

  test "the default filter set hides nothing but the time window" do
    filters = DeliveryFilters.empty()

    assert filters.state == nil
    assert filters.suppression_reason == nil
    assert filters.is_test == nil
    assert filters.window == "24h"
    refute DeliveryFilters.any?(filters)
  end

  test "parses the enumerated filters through the whitelist" do
    filters =
      DeliveryFilters.parse(%{
        "state" => "suppressed",
        "suppression_reason" => "no_matching_route",
        "execution_route" => "edge_agent",
        "payload_format" => "slack_blocks",
        "is_test" => "false",
        "provider_version" => "3",
        "alert_id" => @alert_id,
        "channel_id" => @channel_id,
        "window" => "7d"
      })

    assert filters.state == :suppressed
    assert filters.suppression_reason == :no_matching_route
    assert filters.execution_route == :edge_agent
    assert filters.payload_format == :slack_blocks
    assert filters.is_test == false
    assert filters.provider_version == 3
    assert filters.alert_id == @alert_id
    assert filters.channel_id == @channel_id
    assert filters.window == "7d"
  end

  test "every suppression reason the engine records is offerable, including no_matching_route" do
    for reason <- ~w(device_out_of_service silence schedule snoozed throttled acknowledged
                     channel_disabled dependency no_matching_route) do
      filters = DeliveryFilters.parse(%{"suppression_reason" => reason})
      assert to_string(filters.suppression_reason) == reason
    end
  end

  test "a crafted enumerated value drops the filter and creates no atom" do
    crafted = "reason_#{System.unique_integer([:positive])}"

    filters =
      DeliveryFilters.parse(%{
        "state" => "definitely_not_a_state",
        "suppression_reason" => crafted,
        "execution_route" => "sideband",
        "payload_format" => "yaml",
        "window" => "3000y"
      })

    assert filters.state == nil
    assert filters.suppression_reason == nil
    assert filters.execution_route == nil
    assert filters.payload_format == nil
    assert filters.window == "24h"

    assert_raise ArgumentError, fn -> String.to_existing_atom(crafted) end
  end

  test "a non-uuid id is dropped rather than reaching a query" do
    filters = DeliveryFilters.parse(%{"alert_id" => "'; drop table", "channel_id" => "42"})

    assert filters.alert_id == nil
    assert filters.channel_id == nil
  end

  test "parse and to_params are inverses for a shareable link" do
    params = %{
      "state" => "suppressed",
      "suppression_reason" => "silence",
      "alert_id" => @alert_id,
      "is_test" => "true",
      "window" => "7d"
    }

    round_tripped = params |> DeliveryFilters.parse() |> DeliveryFilters.to_params()

    assert round_tripped == params
    assert DeliveryFilters.parse(round_tripped) == DeliveryFilters.parse(params)
  end

  test "unset filters are omitted so a shared link carries only what was chosen" do
    assert DeliveryFilters.to_params(DeliveryFilters.empty()) == %{}
  end

  test "the window resolves to an explicit lower bound" do
    now = ~U[2026-08-09 12:00:00.000000Z]

    assert DeliveryFilters.since(DeliveryFilters.parse(%{"window" => "1h"}), now) ==
             ~U[2026-08-09 11:00:00.000000Z]

    assert DeliveryFilters.since(DeliveryFilters.parse(%{"window" => "all"}), now) == nil
    assert DeliveryFilters.since(DeliveryFilters.empty(), now) == ~U[2026-08-08 12:00:00.000000Z]
  end

  test "any?/1 reports whether the operator narrowed anything" do
    refute DeliveryFilters.any?(DeliveryFilters.empty())
    assert DeliveryFilters.any?(DeliveryFilters.parse(%{"state" => "failed"}))
    assert DeliveryFilters.any?(DeliveryFilters.parse(%{"window" => "all"}))
  end
end
