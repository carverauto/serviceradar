defmodule ServiceRadarWebNGWeb.DeviceLive.BulkStateApplyDbTest do
  @moduledoc false

  # Writes to the shared ocsf_devices table, so keep it serial like the other
  # CNPG-backed device tests.
  use ServiceRadarWebNG.DataCase, async: false

  alias Phoenix.LiveView.Socket
  alias ServiceRadar.Inventory.Device
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AshTestHelpers
  alias ServiceRadarWebNGWeb.DeviceLive.IndexEvents

  require Ash.Query

  @moduletag :web_ng_shared_fixture_db

  @permissions MapSet.new(["devices.view", "devices.update", "devices.bulk_edit"])

  test "a failing managed leg rolls back the service change from the same submit" do
    uid = "bulk-state-rollback-#{System.unique_integer([:positive])}"

    Repo.insert_all("ocsf_devices", [
      %{
        uid: uid,
        type_id: 0,
        hostname: "bulk-state-rollback-host",
        is_available: true,
        is_active: true,
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      }
    ])

    socket = socket_for(uid)

    assert {:noreply, socket} =
             IndexEvents.handle_event(
               "apply_bulk_state",
               %{"bulk_state" => %{"service_state" => "inactive", "managed_state" => "bogus"}},
               socket
             )

    assert socket.assigns.flash["error"] =~ "Failed to update devices"
    assert socket.assigns.flash["error"] =~ "Unknown managed state"

    assert %Device{is_active: true} =
             Device
             |> Ash.Query.filter(uid == ^uid)
             |> Ash.read_one!(actor: AshTestHelpers.system_actor())
  end

  defp socket_for(uid) do
    scope = %Scope{user: %{id: "bulk-state-user"}, permissions: @permissions}

    assigns = %{
      __changed__: %{},
      current_scope: scope,
      srql: %{query: ""},
      selected_devices: MapSet.new([uid]),
      select_all_matching: false,
      total_matching_count: nil,
      bulk_target_scope: "selected",
      bulk_target_matching_count: nil,
      bulk_state_form: nil,
      bulk_scope_form: nil,
      flash: %{}
    }

    %Socket{assigns: assigns}
  end
end
