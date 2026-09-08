defmodule ServiceRadarWebNGWeb.Api.AnsibleRepositoryControllerTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.TestSupport.AnsibleRepositoriesStub, as: Repositories
  alias ServiceRadarWebNG.TestSupport.ProvisioningIdempotencyStub, as: Idempotency
  alias ServiceRadarWebNGWeb.Api.AnsibleRepositoryController, as: Controller

  @moduletag :db_free
  @repository_id "00000000-0000-4000-8000-000000000701"
  @timestamp ~U[2025-02-03 04:05:06.000007Z]

  setup do
    previous = Application.get_env(:serviceradar_web_ng, :ansible_repositories)
    previous_idempotency = Application.get_env(:serviceradar_web_ng, :provisioning_idempotency)
    Application.put_env(:serviceradar_web_ng, :ansible_repositories, Repositories)
    Application.put_env(:serviceradar_web_ng, :provisioning_idempotency, Idempotency)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:serviceradar_web_ng, :ansible_repositories, previous),
        else: Application.delete_env(:serviceradar_web_ng, :ansible_repositories)

      if previous_idempotency,
        do: Application.put_env(:serviceradar_web_ng, :provisioning_idempotency, previous_idempotency),
        else: Application.delete_env(:serviceradar_web_ng, :provisioning_idempotency)
    end)

    scope = %Scope{
      user: %{id: "00000000-0000-4000-8000-000000000702"},
      permissions: MapSet.new(["ansible.repositories.manage", "ansible.catalog.view"])
    }

    conn =
      build_conn()
      |> assign(:current_scope, scope)
      |> put_req_header("idempotency-key", "00000000-0000-4000-8000-000000000704")
      |> Map.put(:request_path, "/api/admin/ansible-repositories")

    %{conn: conn, scope: scope}
  end

  test "creates a public catalog, preserves scope, and exposes only safe fields", %{conn: conn, scope: scope} do
    conn = Controller.create(conn, %{"name" => "new-example", "git_url" => "https://git.example.com/new.git"})
    body = json_response(conn, 201)

    assert body["name"] == "new-example"
    assert get_resp_header(conn, "etag") == ["\"2025-02-03T04:05:06.000007Z\""]
    refute Map.has_key?(body, "metadata")
    refute Map.has_key?(body, "last_sync_summary")
    refute Map.has_key?(body, "parse_diagnostics")

    assert_receive {:repositories, :create, [^scope, %{name: "new-example", git_url: "https://git.example.com/new.git"}]}
  end

  test "catalog readers cannot mutate and anonymous callers never reach the context", %{conn: conn, scope: scope} do
    reader = %{scope | permissions: MapSet.new(["ansible.catalog.view"])}
    assert {:error, :forbidden} = Controller.create(assign(conn, :current_scope, reader), %{})
    assert {:error, :unauthorized} = Controller.index(assign(conn, :current_scope, %Scope{}), %{})
    refute_received {:repositories, _, _}
  end

  test "rejects credential-bearing URLs and unsupported private authentication before persistence", %{conn: conn} do
    for url <- [
          "http://git.example.com/catalog.git",
          "file:///tmp/catalog",
          "https://token@git.example.com/catalog.git",
          "https://git.example.com/catalog.git?token=synthetic",
          "https://git.example.com/catalog.git#synthetic"
        ] do
      response = Controller.create(conn, %{"name" => "example", "git_url" => url})
      assert json_response(response, 400)["error"] == "invalid_request"
    end

    response =
      Controller.create(conn, %{
        "name" => "example",
        "git_url" => "https://git.example.com/catalog.git",
        "credential_secret_id" => "00000000-0000-4000-8000-000000000703"
      })

    assert json_response(response, 400)["message"] =~ "not supported"
    refute_received {:repositories, _, _}
  end

  test "rejects invalid values and unknown fields without echoing their contents", %{conn: conn} do
    for attrs <- [
          %{},
          %{"name" => nil},
          %{"sync_interval_seconds" => "600"},
          %{"sync_interval_seconds" => 59},
          %{"git_ref" => "--upload-pack=synthetic"},
          %{"git_ref" => "refs/../secret"},
          %{"token" => "synthetic-hidden-token"}
        ] do
      params = Map.merge(%{"name" => "example", "git_url" => "https://git.example.com/catalog.git"}, attrs)
      params = if attrs == %{}, do: %{}, else: params
      response = Controller.create(conn, params)
      assert json_response(response, 400)["error"] == "invalid_request"
      refute response.resp_body =~ "synthetic-hidden-token"
    end

    refute_received {:repositories, _, _}
  end

  test "PATCH requires a version and preserves explicit nulls versus omitted fields", %{conn: conn, scope: scope} do
    missing = Controller.update(conn, %{"id" => @repository_id, "description" => nil})
    assert json_response(missing, 428)["error"] == "precondition_required"
    refute_received {:repositories, :update, _}

    updated =
      conn
      |> put_req_header("if-match", "\"#{DateTime.to_iso8601(@timestamp)}\"")
      |> Controller.update(%{"id" => @repository_id, "description" => nil, "credential_secret_id" => nil})

    assert json_response(updated, 200)["description"] == nil

    assert_receive {:repositories, :update,
                    [
                      ^scope,
                      @repository_id,
                      %{description: nil, credential_secret_id: nil},
                      [expected_updated_at: @timestamp]
                    ]}
  end

  test "create requires a key and replays through a scoped read without creating again", %{conn: conn, scope: scope} do
    params = %{"name" => "example", "git_url" => "https://git.example.com/catalog.git"}
    assert {:error, :idempotency_key_required} = Controller.create(delete_req_header(conn, "idempotency-key"), params)
    refute_received {:repositories, :create, _}

    Process.put({Idempotency, :replay}, @repository_id)
    assert json_response(Controller.create(conn, params), 201)["id"] == @repository_id
    assert_receive {:idempotent_request, identity, ^params}
    assert identity.initiator_id == scope.user.id
    assert identity.operation == "/api/admin/ansible-repositories"
    assert_receive {:repositories, :get, [^scope, @repository_id]}
    refute_received {:repositories, :create, _}
  end

  test "stale PATCH and referenced DELETE are conflicts", %{conn: conn} do
    conn = put_req_header(conn, "if-match", "\"#{DateTime.to_iso8601(@timestamp)}\"")
    Process.put({Repositories, :update}, {:error, :conflict})

    assert json_response(Controller.update(conn, %{"id" => @repository_id, "git_ref" => "release-example"}), 409)[
             "error"
           ] == "conflict"

    Process.put({Repositories, :delete}, {:error, :repository_in_use})
    assert json_response(Controller.delete(conn, %{"id" => @repository_id}), 409)["error"] == "repository_in_use"
  end

  test "DELETE reports actual deletion and passes the expected version", %{conn: conn, scope: scope} do
    conn =
      conn
      |> put_req_header("if-match", "\"#{DateTime.to_iso8601(@timestamp)}\"")
      |> Controller.delete(%{"id" => @repository_id})

    assert response(conn, 204) == ""
    assert_receive {:repositories, :delete, [^scope, @repository_id, [expected_updated_at: @timestamp]]}
  end

  test "list validates cursor and bounds and preserves the next page cursor", %{conn: conn, scope: scope} do
    Process.put({Repositories, :list}, {:ok, %{items: [Repositories.repository()], next_cursor: @repository_id}})
    body = conn |> Controller.index(%{"limit" => "3", "after" => @repository_id}) |> json_response(200)
    assert body["next_cursor"] == @repository_id
    assert length(body["items"]) == 1
    assert_receive {:repositories, :list, [^scope, %{limit: 3, after: @repository_id}]}

    assert json_response(Controller.index(conn, %{"limit" => "501"}), 400)["error"] == "invalid_request"
    assert json_response(Controller.index(conn, %{"after" => "invalid"}), 400)["error"] == "invalid_request"
  end

  test "sync status is observed state without private diagnostics or a launch", %{conn: conn} do
    body = conn |> Controller.sync(%{"id" => @repository_id}) |> json_response(202)
    assert body["scheduling_status"] == "already_scheduled"
    assert body["status"] == "pending"
    assert body["diagnostic_count"] == 1
    refute Map.has_key?(body, "parse_diagnostics")
    refute Map.has_key?(body, "last_sync_summary")
    assert_receive {:repositories, :sync, _}
    refute_received {:repositories, :create, _}

    assert json_response(Controller.sync_status(conn, %{"id" => @repository_id}), 200)["repository_id"] ==
             @repository_id
  end

  test "historical credentials in URLs do not enter read responses", %{conn: conn} do
    record = %{
      Repositories.repository()
      | git_url: "https://synthetic:secret@git.example.com/catalog.git?token=hidden#private"
    }

    Process.put({Repositories, :get}, {:ok, record})
    body = conn |> Controller.show(%{"id" => @repository_id}) |> json_response(200)
    assert body["git_url"] == "https://git.example.com/catalog.git"
  end

  test "missing repositories remain not found", %{conn: conn} do
    Process.put({Repositories, :get}, {:error, :not_found})
    assert {:error, :not_found} = Controller.show(conn, %{"id" => @repository_id})
  end
end
