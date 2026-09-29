defmodule ServiceRadarWebNGWeb.DashboardActionConfirmationsTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.DashboardFrameChannel.ActionConfirmations

  @moduletag :db_free

  @user_id Ecto.UUID.generate()
  @other_user_id Ecto.UUID.generate()
  @now 1_000_000

  @action %{
    id: "northbound:device:sample-reboot",
    descriptor_id: Ecto.UUID.generate(),
    label: "Reboot sample device",
    description: "Restarts the device.",
    provider_name: "Sample Automation",
    safety_classification: "destructive",
    requires_confirmation: true
  }

  @targets [
    %{kind: "device", device_uid: "sr:device:sample-01"},
    %{kind: "device", device_uid: "sr:device:sample-02"}
  ]

  defp issue!(overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          user_id: @user_id,
          action: @action,
          target_scope: "device",
          targets: @targets,
          input_values: %{"reason" => "maintenance window", "api_token" => "not-a-real-token"},
          route_slug: "sample-dashboard"
        },
        overrides
      )

    {:ok, entry, pending} = ActionConfirmations.issue(%{}, attrs, @now)
    {entry, pending}
  end

  defp reply(entry, overrides \\ %{}), do: Map.merge(%{user_id: @user_id, binding: entry.binding}, overrides)

  describe "binding/5" do
    test "treats the target list as a set" do
      assert ActionConfirmations.binding(@user_id, @action.id, "device", @targets, %{}) ==
               ActionConfirmations.binding(@user_id, @action.id, "device", Enum.reverse(@targets), %{})
    end

    test "changes with the viewer, action, scope, targets or input" do
      base = ActionConfirmations.binding(@user_id, @action.id, "device", @targets, %{"a" => 1})

      variants = [
        ActionConfirmations.binding(@other_user_id, @action.id, "device", @targets, %{"a" => 1}),
        ActionConfirmations.binding(@user_id, "northbound:device:other", "device", @targets, %{"a" => 1}),
        ActionConfirmations.binding(@user_id, @action.id, "interface", @targets, %{"a" => 1}),
        ActionConfirmations.binding(@user_id, @action.id, "device", Enum.take(@targets, 1), %{"a" => 1}),
        ActionConfirmations.binding(@user_id, @action.id, "device", @targets, %{"a" => 2})
      ]

      assert Enum.all?(variants, &(&1 != base))
      assert variants |> Enum.uniq() |> length() == length(variants)
    end
  end

  describe "consume/4" do
    test "releases a matching confirmation exactly once" do
      {entry, pending} = issue!()

      assert {:ok, consumed, pending} = ActionConfirmations.consume(pending, entry.id, reply(entry), @now + 1)
      assert consumed.targets == @targets
      assert consumed.action_id == @action.id
      assert pending == %{}

      assert {:error, :confirmation_not_found, ^pending} =
               ActionConfirmations.consume(pending, entry.id, reply(entry), @now + 2)
    end

    test "rejects a binding issued for a different target set and burns the entry" do
      {entry, pending} = issue!()

      other_binding =
        ActionConfirmations.binding(
          @user_id,
          @action.id,
          "device",
          [%{kind: "device", device_uid: "sr:device:sample-99"}],
          entry.input_values
        )

      assert {:error, :confirmation_mismatch, pending} =
               ActionConfirmations.consume(pending, entry.id, reply(entry, %{binding: other_binding}), @now + 1)

      assert pending == %{}

      assert {:error, :confirmation_not_found, _pending} =
               ActionConfirmations.consume(pending, entry.id, reply(entry), @now + 2)
    end

    test "rejects another viewer and a missing binding" do
      {entry, pending} = issue!()

      assert {:error, :confirmation_mismatch, _} =
               ActionConfirmations.consume(pending, entry.id, reply(entry, %{user_id: @other_user_id}), @now + 1)

      {entry, pending} = issue!()

      assert {:error, :confirmation_mismatch, _} =
               ActionConfirmations.consume(pending, entry.id, %{user_id: @user_id}, @now + 1)
    end

    test "rejects a confirmation answered after its TTL" do
      {entry, pending} = issue!()
      late = @now + ActionConfirmations.ttl_ms()

      assert {:error, :confirmation_expired, %{}} = ActionConfirmations.consume(pending, entry.id, reply(entry), late)
    end
  end

  test "decline/3 removes the entry only for the viewer it was issued for" do
    {entry, pending} = issue!()

    assert {:error, :confirmation_mismatch, ^pending} =
             ActionConfirmations.decline(pending, entry.id, %{user_id: @other_user_id})

    assert {:ok, _entry, %{}} = ActionConfirmations.decline(pending, entry.id, %{user_id: @user_id})
  end

  test "issue/3 caps the number of pending confirmations" do
    pending =
      Enum.reduce(1..ActionConfirmations.max_pending(), %{}, fn _n, acc ->
        {:ok, _entry, acc} =
          ActionConfirmations.issue(
            acc,
            %{user_id: @user_id, action: @action, target_scope: "device", targets: @targets},
            @now
          )

        acc
      end)

    assert {:error, :too_many_pending_confirmations} =
             ActionConfirmations.issue(
               pending,
               %{user_id: @user_id, action: @action, target_scope: "device", targets: @targets},
               @now
             )
  end

  test "host_request/3 carries what the dialog shows and hides sensitive input" do
    {entry, _pending} = issue!()
    request = ActionConfirmations.host_request(entry, self(), @now)

    assert request.channel_pid == self()
    assert request.binding == entry.binding
    assert request.label == "Reboot sample device"
    assert request.safety_classification == "destructive"
    assert Enum.map(request.targets, & &1.device_uid) == ["sr:device:sample-01", "sr:device:sample-02"]
    assert request.inputs == [{"api_token", :redacted}, {"reason", "maintenance window"}]
    assert DateTime.after?(request.expires_at, DateTime.utc_now())
  end
end
