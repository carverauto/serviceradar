defmodule ServiceRadar.SweepJobs.StampAuditContextTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.SweepJobs.SweepGroupExecution.Changes.StampAuditContext
  alias ServiceRadar.SweepJobs.SweepGroupExecution.Version

  test "preserves action inputs supplied through an atomic changeset" do
    banner_summary = %{"probe_count" => 12, "banner_match_count" => 5}

    changeset =
      Version
      |> Ash.Changeset.new()
      |> Map.put(:atomics, version_action_inputs: %{"banner_grab_summary" => banner_summary})

    changed =
      StampAuditContext.change(changeset, [], %{
        actor: %{id: "actor-1", role: :admin},
        private: %{request_id: "request-1"}
      })

    assert Ash.Changeset.get_attribute(changed, :version_action_inputs) == %{
             "actor" => %{"id" => "actor-1", "role" => "admin"},
             "actor_id" => "actor-1",
             "banner_grab_summary" => banner_summary,
             "request_id" => "request-1"
           }
  end

  test "restores a stale banner summary input from the paper trail diff" do
    banner_summary = %{"probe_count" => 12, "banner_match_count" => 5}

    changeset =
      Version
      |> Ash.Changeset.new()
      |> Ash.Changeset.change_attribute(:changes, %{
        banner_grab_summary: %{from: %{}, to: banner_summary}
      })
      |> Map.put(:atomics, version_action_inputs: %{banner_grab_summary: %{}})

    changed = StampAuditContext.change(changeset, [], %{})

    assert Ash.Changeset.get_attribute(changed, :version_action_inputs) == %{
             banner_grab_summary: banner_summary
           }
  end
end
