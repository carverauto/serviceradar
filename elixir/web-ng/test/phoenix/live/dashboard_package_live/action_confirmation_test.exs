defmodule ServiceRadarWebNGWeb.DashboardPackageLive.ActionConfirmationTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.DashboardFrameChannel.ActionConfirmations
  alias ServiceRadarWebNGWeb.DashboardPackageLive.ActionConfirmation

  @moduletag :db_free

  @user_id Ecto.UUID.generate()

  defp socket(user_id \\ @user_id) do
    ActionConfirmation.assign_defaults(%Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, current_scope: %{user: %{id: user_id}}}
    })
  end

  # Builds the request exactly as the frame channel does, with this test
  # process standing in for the channel.
  defp request(targets \\ ["sr:device:sample-01"]) do
    {:ok, entry, _pending} =
      ActionConfirmations.issue(
        %{},
        %{
          user_id: @user_id,
          action: %{
            id: "northbound:device:sample-reset",
            descriptor_id: Ecto.UUID.generate(),
            label: "Reset sample port",
            description: nil,
            provider_name: "Sample Automation",
            safety_classification: "destructive"
          },
          target_scope: "device",
          targets: Enum.map(targets, &%{kind: "device", device_uid: &1}),
          input_values: %{"reason" => "planned", "password" => "not-a-real-password"},
          route_slug: "sample-dashboard"
        },
        System.monotonic_time(:millisecond)
      )

    ActionConfirmations.host_request(entry, self(), System.monotonic_time(:millisecond))
  end

  test "confirming the displayed request replies to the channel with its binding" do
    request = request()
    socket = ActionConfirmation.handle_request(socket(), request)

    socket = ActionConfirmation.handle_decision(socket, :confirmed, request.id)

    assert_received {:dashboard_action_confirmation_reply, id, :confirmed, reply}
    assert id == request.id
    assert reply == %{user_id: @user_id, binding: request.binding}
    assert socket.assigns.action_confirmations == []
  end

  test "a request for another viewer is never shown" do
    socket = ActionConfirmation.handle_request(socket(Ecto.UUID.generate()), request())

    assert socket.assigns.action_confirmations == []
  end

  test "only the request at the head of the queue can be confirmed" do
    first = request(["sr:device:sample-01"])
    second = request(["sr:device:sample-02"])

    socket =
      socket()
      |> ActionConfirmation.handle_request(first)
      |> ActionConfirmation.handle_request(second)
      |> ActionConfirmation.handle_decision(:confirmed, second.id)

    refute_received {:dashboard_action_confirmation_reply, _id, _decision, _reply}
    assert Enum.map(socket.assigns.action_confirmations, & &1.id) == [first.id, second.id]
  end

  test "declining without an id declines the displayed request; closing drops one" do
    first = request(["sr:device:sample-01"])
    second = request(["sr:device:sample-02"])

    socket =
      socket()
      |> ActionConfirmation.handle_request(first)
      |> ActionConfirmation.handle_request(second)
      |> ActionConfirmation.handle_decision(:declined, nil)

    assert_received {:dashboard_action_confirmation_reply, id, :declined, _reply}
    assert id == first.id

    socket = ActionConfirmation.handle_closed(socket, second.id)
    assert socket.assigns.action_confirmations == []
  end

  test "the host dialog shows the action, its safety classification and every target" do
    request = request(["sr:device:sample-01", "sr:device:sample-02"])

    html = render_component(&ActionConfirmation.confirmation_modal/1, confirmations: [request])

    assert html =~ "Reset sample port"
    assert html =~ "Destructive"
    assert html =~ "sr:device:sample-01"
    assert html =~ "sr:device:sample-02"
    assert html =~ ~s(phx-click="confirm_dashboard_action")
    assert html =~ ~s(phx-value-id="#{request.id}")
    refute html =~ "not-a-real-password"
    refute html =~ request.binding
  end

  test "no dialog renders when nothing is waiting" do
    refute render_component(&ActionConfirmation.confirmation_modal/1, confirmations: []) =~ "Confirm action"
  end
end
