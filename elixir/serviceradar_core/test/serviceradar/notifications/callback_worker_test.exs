defmodule ServiceRadar.Notifications.CallbackWorkerTest do
  @moduledoc """
  How a verified interaction becomes a job (tasks 4.3.0c, 4.3.0d).

  `build/1` is a changeset, so what it decides is inspectable without a database
  or a running Oban - which is the part worth pinning, because the dedupe
  decision is conditional and getting the condition backwards silently drops a
  real acknowledgement.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Notifications.CallbackWorker

  defp capability(overrides \\ %{}) do
    Map.merge(
      %{
        action: :acknowledge,
        alert_id: "0198f0aa-1111-7000-8000-000000000001",
        delivery_id: "0198f0aa-2222-7000-8000-000000000002",
        external_principal: "slack:U123",
        app_id: "A0123456789",
        action_id: "notification_acknowledge",
        provider_key: :slack
      },
      overrides
    )
  end

  test "string-keyed args with no structs, per the Oban rules" do
    changeset = CallbackWorker.build(capability())
    args = Ecto.Changeset.get_field(changeset, :args)

    assert Enum.all?(Map.keys(args), &is_binary/1)
    assert args["action"] == "acknowledge"
    assert args["provider_key"] == "slack"
    assert args["app_id"] == "A0123456789"
    assert args["action_id"] == "notification_acknowledge"
    refute Enum.any?(Map.values(args), &is_struct/1)
  end

  test "omits absent values rather than carrying nils into the job" do
    args =
      %{delivery_id: nil}
      |> capability()
      |> CallbackWorker.build()
      |> Ecto.Changeset.get_field(:args)

    refute Map.has_key?(args, "delivery_id")
    refute Map.has_key?(args, "snooze_seconds")
  end

  describe "dedupe (task 4.3.0d)" do
    test "applies uniqueness when the provider gave an event id" do
      changeset =
        CallbackWorker.build(
          capability(%{provider_key: :pagerduty, event_id: "01BWDWL3NYY7LUFPZCC28QUCMK"})
        )

      unique = Ecto.Changeset.get_field(changeset, :unique)

      assert unique, "a PagerDuty redelivery must not enqueue a second job"
      assert :event_id in unique.keys
      assert :provider_key in unique.keys
    end

    test "applies NO uniqueness when the provider gave none" do
      # This condition is the whole point. Slack's block_actions payload carries
      # no event id, and a blanket unique on these keys would compare two
      # distinct clicks on a missing value and collapse them - silently dropping
      # the second operator's acknowledgement.
      changeset = CallbackWorker.build(capability())

      refute Ecto.Changeset.get_field(changeset, :unique)
    end

    test "an empty event id is treated as absent, not as a key everything shares" do
      changeset = CallbackWorker.build(capability(%{event_id: ""}))

      refute Ecto.Changeset.get_field(changeset, :unique)
    end
  end
end
