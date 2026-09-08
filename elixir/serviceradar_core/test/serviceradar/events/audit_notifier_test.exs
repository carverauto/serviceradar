defmodule ServiceRadar.Events.AuditNotifierTest do
  use ExUnit.Case, async: true

  alias Ash.Notifier.Notification
  alias ServiceRadar.Events.AuditNotifier

  test "normalizes destroy notifications to delete actions" do
    notification = %Notification{
      action: %{name: :destroy_record, type: :destroy},
      changeset: %Ash.Changeset{}
    }

    assert AuditNotifier.action(notification) == :delete
  end

  test "build_opts injects normalized action and actor" do
    actor = %{id: "user-1"}

    notification = %Notification{
      action: %{name: :disable, type: :update},
      changeset: %Ash.Changeset{context: %{private: %{actor: actor}}}
    }

    opts = AuditNotifier.build_opts(notification, resource_type: "user")

    assert Keyword.get(opts, :resource_type) == "user"
    assert Keyword.get(opts, :action) == :disable
    assert Keyword.get(opts, :actor) == actor
  end

  test "build_opts preserves explicit action and actor overrides" do
    actor = %{id: "user-1"}
    override_actor = %{id: "override"}

    notification = %Notification{
      action: %{name: :update, type: :update},
      changeset: %Ash.Changeset{context: %{private: %{actor: actor}}}
    }

    opts =
      AuditNotifier.build_opts(
        notification,
        resource_type: "user",
        action: :enable,
        actor: override_actor
      )

    assert Keyword.get(opts, :resource_type) == "user"
    assert Keyword.get(opts, :action) == :enable
    assert Keyword.get(opts, :actor) == override_actor
  end
end
