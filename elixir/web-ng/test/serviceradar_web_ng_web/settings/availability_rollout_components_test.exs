defmodule ServiceRadarWebNGWeb.Settings.AvailabilityRolloutComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadar.Inventory.Availability.Setting
  alias ServiceRadarWebNGWeb.Settings.AvailabilityRolloutComponents

  @moduletag :db_free

  defp setting(attrs) do
    struct!(
      %Setting{
        mode: :shadow,
        mode_control: :auto,
        mode_control_pin: nil,
        readiness: %{
          "conditions" => %{
            "capture_backfill" => %{"met" => true},
            "sweep_groups" => %{"met" => false, "waiting" => 1}
          }
        }
      },
      attrs
    )
  end

  defp document(setting, can_edit) do
    html =
      render_component(&AvailabilityRolloutComponents.rollout_panel/1,
        setting: setting,
        can_edit: can_edit
      )

    LazyHTML.from_fragment(html)
  end

  defp present?(document, selector), do: document |> LazyHTML.query(selector) |> LazyHTML.to_tree() != []

  test "an editor can change an unpinned control, and readiness shows each condition" do
    document = document(setting(%{}), true)

    refute present?(document, "#availability-rollout-pinned")
    refute present?(document, "#availability-rollout-control-hold_legacy[disabled]")
    assert present?(document, "#availability-rollout-control-hold_legacy[data-confirm]")
    assert present?(document, "#availability-rollout-condition-capture_backfill[data-met='true']")
    assert present?(document, "#availability-rollout-condition-sweep_groups[data-met='false']")
    refute present?(document, "#availability-rollout-condition-policy_violations")
  end

  test "a pinned control is shown read-only, even to an editor" do
    document = document(setting(%{mode_control: :hold_legacy, mode_control_pin: "hold_legacy"}), true)

    assert LazyHTML.text(LazyHTML.query(document, "#availability-rollout-pinned")) =~ "hold_legacy"

    for control <- ["auto", "hold_shadow", "hold_legacy"] do
      assert present?(document, "#availability-rollout-control-#{control}[disabled]")
    end
  end
end
