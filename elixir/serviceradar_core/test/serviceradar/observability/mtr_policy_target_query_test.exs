defmodule ServiceRadar.Observability.MtrPolicyTargetQueryTest do
  @moduledoc """
  An MTR policy's `target_selector` holds its SRQL target query next to other
  selector settings, and the settings form writes the whole selector on every
  save. A query written with `limit:` is refused, but a save that leaves a
  stored query as it was must succeed even when it changes another selector
  key, so a query stored before the rule existed does not block edits.

  The changesets are built, not submitted: the validation runs while the
  changeset is built, so no database is involved.
  """

  use ExUnit.Case, async: true

  alias Ash.Changeset
  alias ServiceRadar.Observability.MtrPolicy

  @stored_query "in:devices tags.role:edge limit:25"

  test "changing another selector key keeps a stored query that has limit:" do
    changeset =
      Changeset.for_update(stored_policy(), :update, %{
        target_selector: %{"srql_query" => @stored_query, "limit" => 50}
      })

    assert changeset.valid?, inspect(changeset.errors)
  end

  test "changing the selector query to one with limit: is refused" do
    changeset =
      Changeset.for_update(stored_policy(), :update, %{
        target_selector: %{"srql_query" => "in:devices tags.role:core limit:25", "limit" => 25}
      })

    refute changeset.valid?

    assert changeset.errors
           |> Enum.filter(&(Map.get(&1, :field) == :target_selector))
           |> Enum.map_join("; ", &Exception.message/1) =~
             "limit:25 cannot be used in a target query"
  end

  defp stored_policy do
    %MtrPolicy{
      id: Ash.UUID.generate(),
      name: "policy01",
      enabled: true,
      scope: "managed_devices",
      target_selector: %{"srql_query" => @stored_query, "limit" => 25},
      baseline_interval_sec: 300,
      baseline_protocol: "icmp",
      baseline_protocols: [:icmp],
      tcp_port: 443,
      baseline_canary_vantages: 0,
      incident_fanout_max_agents: 3,
      incident_cooldown_sec: 600,
      recovery_capture: true,
      consensus_mode: "majority",
      consensus_threshold: 0.66,
      consensus_min_agents: 2
    }
  end
end
