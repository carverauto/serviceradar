defmodule ServiceRadarWebNGWeb.Settings.NotificationsLive.AccessTest do
  @moduledoc """
  The authorization gate of `/settings/notifications`.

  Every `handle_event/3` in the notification LiveView is routed through
  `Access.authorize_event/2` before it reaches a handler, so these are the tests
  that prove a forged event changes nothing: if the gate refuses, no handler runs.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Identity.RBAC.Catalog, as: RBACCatalog
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNGWeb.Settings.NotificationsLive.Access

  @moduletag :db_free

  # Mirrors the shipped default role sets: an operator reads channels and the
  # delivery log, and manages silences, but channel mutation and test-send are
  # admin-only.
  defp operator_scope do
    %Scope{
      permissions:
        MapSet.new([
          "notifications.channels.view",
          "notifications.routes.view",
          "notifications.deliveries.view",
          "notifications.silences.manage"
        ])
    }
  end

  defp admin_scope do
    %Scope{
      permissions:
        MapSet.new([
          "notifications.channels.view",
          "notifications.channels.manage",
          "notifications.routes.view",
          "notifications.routes.manage",
          "notifications.providers.manage",
          "notifications.deliveries.view",
          "notifications.test.send",
          "notifications.silences.manage"
        ])
    }
  end

  defp empty_scope, do: %Scope{permissions: MapSet.new([])}

  describe "tab whitelist" do
    test "resolves only declared tab ids" do
      for tab <- Access.tabs() do
        assert {:ok, ^tab} = Access.tab(tab.id)
      end
    end

    test "an unknown segment is refused and creates no atom" do
      crafted = "definitely_not_a_tab_#{System.unique_integer([:positive])}"

      assert :error = Access.tab(crafted)
      assert :error = Access.tab("../../etc/passwd")
      assert :error = Access.tab(nil)
      assert :error = Access.tab(:channels)

      assert_raise ArgumentError, fn -> String.to_existing_atom(crafted) end
    end

    test "every tab permission is a real RBAC catalog key" do
      keys = MapSet.new(RBACCatalog.permission_keys())

      for tab <- Access.tabs() do
        assert MapSet.member?(keys, tab.permission),
               "tab #{tab.id} permission #{tab.permission} is not catalogued"

        if tab.manage_permission do
          assert MapSet.member?(keys, tab.manage_permission),
                 "tab #{tab.id} manage permission #{tab.manage_permission} is not catalogued"
        end
      end
    end

    test "visible tabs follow the scope" do
      assert Access.visible_tabs(empty_scope()) == []
      refute Access.any_access?(empty_scope())

      operator_ids = operator_scope() |> Access.visible_tabs() |> Enum.map(& &1.id)
      assert "channels" in operator_ids
      assert "deliveries" in operator_ids

      admin_ids = admin_scope() |> Access.visible_tabs() |> Enum.map(& &1.id)
      assert length(admin_ids) == length(Access.tabs())
    end

    test "a scope holding only channels.view cannot see the delivery log tab" do
      scope = %Scope{permissions: MapSet.new(["notifications.channels.view"])}
      ids = scope |> Access.visible_tabs() |> Enum.map(& &1.id)

      assert "channels" in ids
      refute "deliveries" in ids

      {:ok, deliveries} = Access.tab("deliveries")
      refute Access.visible_tab?(scope, deliveries)
    end

    test "the delivery log is never manageable" do
      {:ok, deliveries} = Access.tab("deliveries")
      refute Access.manage_tab?(admin_scope(), deliveries)
    end
  end

  describe "event authorization" do
    test "a scope without channels.manage cannot mutate a channel" do
      scope = operator_scope()

      for event <- ~w(new_channel edit_channel validate_channel save_channel disable_channel enable_channel) do
        assert {:error, :forbidden} = Access.authorize_event(scope, event),
               "#{event} must be refused without notifications.channels.manage"
      end

      assert :ok = Access.authorize_event(admin_scope(), "save_channel")
    end

    test "test send is gated separately from channel edit" do
      # Editing a channel and performing real egress are different acts, so
      # holding one must not imply the other.
      manage_only = %Scope{permissions: MapSet.new(["notifications.channels.manage"])}
      test_only = %Scope{permissions: MapSet.new(["notifications.test.send"])}

      assert {:error, :forbidden} = Access.authorize_event(manage_only, "test_channel")
      assert :ok = Access.authorize_event(test_only, "test_channel")
      assert {:error, :forbidden} = Access.authorize_event(test_only, "save_channel")
    end

    test "silences are gated by their own key, not by routes.manage" do
      routes_only = %Scope{permissions: MapSet.new(["notifications.routes.manage"])}

      assert {:error, :forbidden} = Access.authorize_event(routes_only, "save_silence")
      assert {:error, :forbidden} = Access.authorize_event(routes_only, "cancel_silence")
      assert :ok = Access.authorize_event(operator_scope(), "save_silence")
    end

    test "provider mutation is admin-only" do
      assert {:error, :forbidden} = Access.authorize_event(operator_scope(), "disable_provider")
      assert :ok = Access.authorize_event(admin_scope(), "disable_provider")
    end

    test "an undeclared event is refused rather than permitted by default" do
      assert {:error, :unknown_event} = Access.authorize_event(admin_scope(), "drop_everything")
      assert {:error, :unknown_event} = Access.authorize_event(admin_scope(), :save_channel)
    end

    test "an empty scope is refused every declared event" do
      scope = empty_scope()

      for event <- ~w(save_channel save_route save_silence disable_provider filter_deliveries test_channel) do
        assert {:error, :forbidden} = Access.authorize_event(scope, event)
      end
    end
  end
end
