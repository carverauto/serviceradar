defmodule ServiceRadarWebNGWeb.Api.AnsibleAutomationControllerTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AnsibleAutomation
  alias ServiceRadarWebNGWeb.Api.AnsibleAutomationController, as: Controller

  @moduletag :db_free

  defmodule Automation do
    def prepare(scope, params) do
      send(self(), {:prepare, scope.user.id, params})
      {:ok, %{variables: [], targets: []}}
    end

    def request_cancel(_, _), do: {:error, :cancellation_not_implemented}
    def get_operation(_, id), do: {:ok, %{operation: %{id: id, state: :running}}}
  end

  setup do
    previous = Application.get_env(:serviceradar_web_ng, :ansible_automation)
    Application.put_env(:serviceradar_web_ng, :ansible_automation, Automation)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:serviceradar_web_ng, :ansible_automation, previous),
        else: Application.delete_env(:serviceradar_web_ng, :ansible_automation)
    end)

    scope = %Scope{
      user: %{id: "00000000-0000-4000-8000-000000000451"},
      permissions: MapSet.new(["ansible.runs.launch", "ansible.runs.view", "ansible.runs.cancel"])
    }

    %{conn: assign(build_conn(), :current_scope, scope), scope: scope}
  end

  test "controller preserves the authenticated initiating human", c do
    params = %{
      "device_uids" => ["sr:synthetic-device"],
      "playbook_id" => "00000000-0000-4000-8000-000000000452"
    }

    conn = call(c.conn, :prepare, params)
    assert json_response(conn, 200) == %{"targets" => [], "variables" => []}
    assert_receive {:prepare, id, ^params}
    assert id == c.scope.user.id
  end

  test "OAuth clients cannot silently launch as their human owner", c do
    conn = c.conn |> assign(:oauth_client_id, "synthetic-client") |> call(:prepare, %{})
    assert json_response(conn, 403)["error"] == "human_principal_required"
    refute_receive {:prepare, _, _}
  end

  test "missing permissions are denied before canonical dispatch", c do
    conn =
      c.conn
      |> assign(:current_scope, %{c.scope | permissions: MapSet.new()})
      |> call(:prepare, %{})

    assert json_response(conn, 403)["error"] == "forbidden"
    refute_receive {:prepare, _, _}
  end

  test "cancellation truthfully reports the unimplemented durable workflow", c do
    conn = call(c.conn, :cancel, %{"id" => "00000000-0000-4000-8000-000000000453"})
    assert json_response(conn, 501)["error"] == "cancellation_not_implemented"
  end

  test "canonical request boundary rejects body-selected authority and raw launch controls", c do
    for key <-
          ~w(principal_id actor_id awx_job_id limit extra_vars credentials reviewed_launch_snapshot) do
      assert {:error, :unreviewed_request_fields} =
               AnsibleAutomation.prepare(c.scope, %{key => "forged"})

      assert {:error, :unreviewed_request_fields} =
               AnsibleAutomation.launch(c.scope, %{key => "forged"})
    end
  end

  defp call(conn, action, params),
    do: Controller.call(%{conn | params: params}, Controller.init(action))
end
