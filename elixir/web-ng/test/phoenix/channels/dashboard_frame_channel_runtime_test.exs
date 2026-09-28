defmodule ServiceRadarWebNGWeb.DashboardFrameChannelRuntimeTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Identity.User
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNGWeb.DashboardFrameChannel.Actions
  alias ServiceRadarWebNGWeb.DashboardFrameChannel.Events

  @moduletag :db_free

  defmodule RecordingInvocationService do
    @moduledoc false
    def create_and_dispatch(attrs, _opts) do
      send(Application.get_env(:serviceradar_web_ng, :dashboard_runtime_test_pid), {:invocation_created, attrs})
      {:ok, %{id: "inv-1", state: :dispatching, result_summary: %{}, error_message: nil, completed_at: nil}}
    end
  end

  @summary %{
    "id" => "e-1",
    "log_provider" => "plugin:demo-ot-plc",
    "log_name" => "demo.faults",
    "class_uid" => 1008,
    "severity_id" => 4,
    "device" => %{"uid" => "sr:device:plc-07"},
    "metadata" => %{"plugin_id" => "demo-ot-plc", "fault_kind" => "jam"}
  }

  setup do
    previous = Application.get_env(:serviceradar_web_ng, :northbound_invocation_service_module)
    Application.put_env(:serviceradar_web_ng, :northbound_invocation_service_module, RecordingInvocationService)
    Application.put_env(:serviceradar_web_ng, :dashboard_runtime_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:serviceradar_web_ng, :dashboard_runtime_test_pid)

      if previous,
        do: Application.put_env(:serviceradar_web_ng, :northbound_invocation_service_module, previous),
        else: Application.delete_env(:serviceradar_web_ng, :northbound_invocation_service_module)
    end)

    :ok
  end

  describe "actions" do
    test "a package without actions.invoke cannot list or invoke" do
      scope = %Scope{user: %User{id: Ecto.UUID.generate(), role: :admin}, permissions: MapSet.new()}

      assert {:error, :capability_not_approved} = Actions.list(scope, ["srql.execute"], %{})
      assert {:error, :capability_not_approved} = Actions.invoke(scope, [], %{"action_id" => "northbound:1"})
      refute_received {:invocation_created, _attrs}
    end

    test "a viewer the authority cannot confirm is denied before any invocation is created" do
      assert {:error, :permission_denied} =
               Actions.invoke(nil, ["actions.invoke"], %{
                 "action_id" => "northbound:1",
                 "targets" => [%{"device_uid" => "sr:device:plc-07"}]
               })

      refute_received {:invocation_created, _attrs}
    end

    test "terminal states end progress polling" do
      assert Actions.terminal?(%{"state" => "succeeded"})
      assert Actions.terminal?(%{"state" => "failed"})
      refute Actions.terminal?(%{"state" => "running"})
    end
  end

  describe "events" do
    test "a package without events.subscribe cannot subscribe" do
      assert {:error, :capability_not_approved} = Events.subscribe(nil, [], %{}, %{"id" => "sub-1"})
    end

    test "an anonymous viewer is denied" do
      assert {:error, :permission_denied} = Events.subscribe(nil, ["events.subscribe"], %{}, %{"id" => "sub-1"})
    end

    test "matches on provider, class, severity floor, device and metadata" do
      filters = %{
        "provider" => filter!(%{"log_provider" => "plugin:demo-ot-plc"}),
        "class" => filter!(%{"class_uid" => [1008, 1009]}),
        "severe" => filter!(%{"min_severity_id" => 5}),
        "device" => filter!(%{"device_uid" => "sr:device:plc-07"}),
        "meta" => filter!(%{"metadata" => %{"fault_kind" => "jam"}}),
        "other_meta" => filter!(%{"metadata" => %{"fault_kind" => "mis_sort"}})
      }

      matched = filters |> Events.match([@summary]) |> Map.new()

      assert matched |> Map.keys() |> Enum.sort() == ["class", "device", "meta", "provider"]
      assert matched["provider"] == [@summary]
    end

    test "unknown filter keys and non-scalar metadata are rejected, not turned into atoms" do
      assert {:error, {:invalid_filter, "not_a_field"}} = normalize(%{"not_a_field" => "x"})
      assert {:error, {:invalid_filter, "metadata"}} = normalize(%{"metadata" => %{"nested" => %{"a" => 1}}})
      assert {:error, {:invalid_filter, "class_uid"}} = normalize(%{"class_uid" => "1008"})
    end
  end

  defp filter!(raw) do
    {:ok, filter} = normalize(raw)
    filter
  end

  defp normalize(raw), do: Events.normalize_filter(raw)
end
