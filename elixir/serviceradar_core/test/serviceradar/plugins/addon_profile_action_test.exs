defmodule ServiceRadar.Plugins.AddonProfileActionTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.AddonProfile
  alias ServiceRadar.Plugins.Changes.ApplyAddonConfigDefaults

  @moduletag :requires_app

  test "preview and reconcile actions return structured errors instead of treating context as Access" do
    actor = SystemActor.system(:addon_profile_action_test)
    missing_id = Ecto.UUID.generate()

    assert {:error, _reason} =
             AddonProfile
             |> Ash.ActionInput.for_action(:preview, %{id: missing_id, sample_limit: 1})
             |> Ash.run_action(actor: actor)

    assert {:error, _reason} =
             AddonProfile
             |> Ash.ActionInput.for_action(:reconcile_now, %{id: missing_id})
             |> Ash.run_action(actor: actor)
  end

  test "active netprobe profiles inherit runtime enabled while explicit false is preserved" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "enabled" => %{"type" => "boolean", "default" => false},
        "flow_attribution_ipc_batch" => %{"type" => "boolean", "default" => true}
      }
    }

    assert normalized_params(%{}, schema)["enabled"] == true
    assert normalized_params(%{"enabled" => false}, schema)["enabled"] == false
    assert normalized_params(%{}, schema, enabled: false)["enabled"] == false
    assert normalized_params(%{}, schema, addon_id: "remote-access")["enabled"] == false
  end

  defp normalized_params(params, schema, opts \\ []) do
    changeset =
      AddonProfile
      |> Ash.Changeset.new()
      |> Ash.Changeset.force_change_attribute(:addon_id, Keyword.get(opts, :addon_id, "netprobe"))
      |> Ash.Changeset.force_change_attribute(:enabled, Keyword.get(opts, :enabled, true))
      |> Ash.Changeset.force_change_attribute(:params, params)
      |> Ash.Changeset.set_context(%{config_schema: schema})
      |> ApplyAddonConfigDefaults.change([], %{})

    Ash.Changeset.get_attribute(changeset, :params)
  end
end
