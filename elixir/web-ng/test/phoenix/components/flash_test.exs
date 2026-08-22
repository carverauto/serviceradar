defmodule ServiceRadarWebNGWeb.Components.FlashTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.CoreComponents
  alias ServiceRadarWebNGWeb.Layouts

  @moduletag :unit
  @moduletag :db_free

  test "error flash puts the message in a string attribute, not a rendered slot" do
    html =
      render_component(&CoreComponents.flash/1, %{
        kind: :error,
        flash: %{"error" => ~s(only one enabled add-on profile)}
      })

    assert html =~ ~s(data-toast-message="only one enabled add-on profile")
    assert html =~ ~s(phx-hook="ToastTopLayer")
    assert html =~ ~s(popover="manual")
    refute html =~ ~s("event":"lv:clear-flash")
  end

  test "reconnect flashes are not popovers and do not leak JS commands as text" do
    html = render_component(&Layouts.flash_group/1, %{flash: %{}})

    # Broken render_slot-in-attribute leaked unescaped JS commands as body text.
    refute html =~ ~s("event":"lv:clear-flash")
    assert html =~ ~s(id="server-error")
    refute html =~ ~r/id="server-error"[^>]*popover=/
    refute html =~ ~r/id="server-error"[^>]*phx-hook="ToastTopLayer"/
    assert html =~ "Something went wrong!"
    assert html =~ "Attempting to reconnect"
  end
end
