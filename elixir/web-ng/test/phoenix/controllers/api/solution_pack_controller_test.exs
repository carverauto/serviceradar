defmodule ServiceRadarWebNGWeb.Api.SolutionPackControllerTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNGWeb.Api.SolutionPackController, as: Controller
  alias ServiceRadarWebNGWeb.Router

  @moduletag :db_free

  @user_id "00000000-0000-4000-8000-000000000951"
  @repo_id "00000000-0000-4000-8000-000000000952"

  defmodule ControllerStub do
    @moduledoc false

    def list_packs(_opts) do
      {:ok,
       [
         %{
           "id" => "io.serviceradar.storage-and-nvr-health",
           "slug" => "storage-and-nvr-health",
           "name" => "Storage Entitlements & NVR Recording Health",
           "version" => "0.1.0"
         }
       ]}
    end

    def get_pack("storage-and-nvr-health", _opts) do
      {:ok,
       %{
         "id" => "io.serviceradar.storage-and-nvr-health",
         "slug" => "storage-and-nvr-health",
         "version" => "0.1.0"
       }}
    end

    def get_pack(_other, _opts), do: {:error, :not_found}

    def export_pack("storage-and-nvr-health", :srpack, _opts) do
      {:ok, <<0x28, 0xB5, 0x2F, 0xFD, 0, 1, 2, 3>>, "storage-and-nvr-health.srpack"}
    end

    def export_pack("storage-and-nvr-health", :json, _opts) do
      {:ok, ~s({"pack_format_version":1,"files":{}}), "storage-and-nvr-health.srpack.json"}
    end

    def export_pack(_other, _fmt, _opts), do: {:error, :not_found}

    def export_custom_pack(%{"slug" => slug}, :json, _opts) do
      {:ok, ~s({"pack_format_version":1,"slug":"#{slug}"}), "#{slug}.srpack.json"}
    end

    def preview_install(pack_input, params, opts) do
      {:ok,
       %{
         dry_run: true,
         input_kind: if(is_map(pack_input), do: "files", else: "slug"),
         config: params["config"],
         activate_dashboard_packages: Keyword.get(opts, :activate_dashboard_packages, false),
         install_paused: Keyword.get(opts, :install_paused, false)
       }}
    end

    def install_pack("conflict-version", _params, _opts) do
      {:error, {:version_already_published, %{dashboard_id: "com.serviceradar.ui", version: "1.0.0"}}}
    end

    def install_pack(_pack_input, params, opts) do
      {:ok,
       %{
         dry_run: false,
         installed: true,
         config: params["config"],
         activate_dashboard_packages: Keyword.get(opts, :activate_dashboard_packages, false),
         install_paused: Keyword.get(opts, :install_paused, false)
       }}
    end

    def uninstall_pack(slug, _opts), do: {:ok, %{slug: slug, mode: :delete}}
    def detach_pack(slug, _opts), do: {:ok, %{slug: slug, mode: :detach}}

    def list_repositories(_opts) do
      {:ok, [%{"id" => "00000000-0000-4000-8000-000000000952", "name" => "Official", "mode" => "release_catalog"}]}
    end

    def create_repository(attrs, _opts) do
      {:ok, Map.put(attrs, "id", "00000000-0000-4000-8000-000000000953")}
    end

    def update_repository(id, attrs, _opts), do: {:ok, Map.put(attrs, "id", id)}
    def delete_repository(_id, _opts), do: :ok
    def sync_repository(_id, _opts), do: {:ok, %{"pack_count" => 3}}

    def build_push_payload(slug, _spec, _opts), do: {:ok, %{"manifest.json" => ~s({"slug":"#{slug}"})}}

    def push_to_gitops("conflict-repo", _payload, _opts) do
      {:error, {:branch_conflict, %{expected: "aaa", actual: "bbb"}}}
    end

    def push_to_gitops(_id, _payload, _opts) do
      {:ok, %{commit_sha: "abc123", branch: "serviceradar/pack-test", pr_url: "https://github.com/example/repo/pull/7"}}
    end

    def pull_from_gitops(_id, slug, opts) do
      {:ok, %{slug: slug, dry_run: Keyword.get(opts, :dry_run, true), source_commit_sha: "def456"}}
    end
  end

  setup do
    previous = Application.get_env(:serviceradar_web_ng, :catalog_backend)
    Application.put_env(:serviceradar_web_ng, :catalog_backend, ControllerStub)

    on_exit(fn ->
      if previous do
        Application.put_env(:serviceradar_web_ng, :catalog_backend, previous)
      else
        Application.delete_env(:serviceradar_web_ng, :catalog_backend)
      end
    end)

    full_scope =
      scope_with_permissions([
        "catalog.view",
        "catalog.packs.install",
        "catalog.packs.export",
        "catalog.repositories.manage",
        "catalog.gitops.sync"
      ])

    %{conn: assign(build_conn(), :current_scope, full_scope)}
  end

  describe "router wiring under /api/v2/catalog" do
    test "resolves all catalog pack, repository, and GitOps routes before AshJsonApiRouter" do
      assert %{plug: Controller, plug_opts: :index} =
               Phoenix.Router.route_info(Router, "GET", "/api/v2/catalog/packs", "localhost")

      assert %{plug: Controller, plug_opts: :show} =
               Phoenix.Router.route_info(Router, "GET", "/api/v2/catalog/packs/storage-and-nvr-health", "localhost")

      assert %{plug: Controller, plug_opts: :export} =
               Phoenix.Router.route_info(
                 Router,
                 "GET",
                 "/api/v2/catalog/packs/storage-and-nvr-health/export",
                 "localhost"
               )

      assert %{plug: Controller, plug_opts: :install} =
               Phoenix.Router.route_info(
                 Router,
                 "POST",
                 "/api/v2/catalog/packs/storage-and-nvr-health/install",
                 "localhost"
               )

      assert %{plug: Controller, plug_opts: :import_pack} =
               Phoenix.Router.route_info(Router, "POST", "/api/v2/catalog/packs/import", "localhost")

      assert %{plug: Controller, plug_opts: :export_custom} =
               Phoenix.Router.route_info(Router, "POST", "/api/v2/catalog/packs/export", "localhost")

      assert %{plug: Controller, plug_opts: :list_repositories} =
               Phoenix.Router.route_info(Router, "GET", "/api/v2/catalog/repositories", "localhost")

      assert %{plug: Controller, plug_opts: :create_repository} =
               Phoenix.Router.route_info(Router, "POST", "/api/v2/catalog/repositories", "localhost")

      assert %{plug: Controller, plug_opts: :update_repository} =
               Phoenix.Router.route_info(Router, "PUT", "/api/v2/catalog/repositories/#{@repo_id}", "localhost")

      assert %{plug: Controller, plug_opts: :delete_repository} =
               Phoenix.Router.route_info(Router, "DELETE", "/api/v2/catalog/repositories/#{@repo_id}", "localhost")

      assert %{plug: Controller, plug_opts: :sync_repository} =
               Phoenix.Router.route_info(Router, "POST", "/api/v2/catalog/repositories/#{@repo_id}/sync", "localhost")

      assert %{plug: Controller, plug_opts: :gitops_push} =
               Phoenix.Router.route_info(
                 Router,
                 "POST",
                 "/api/v2/catalog/repositories/#{@repo_id}/gitops/push",
                 "localhost"
               )

      assert %{plug: Controller, plug_opts: :gitops_pull} =
               Phoenix.Router.route_info(
                 Router,
                 "POST",
                 "/api/v2/catalog/repositories/#{@repo_id}/gitops/pull",
                 "localhost"
               )
    end
  end

  describe "RBAC & authentication enforcement" do
    test "returns 401 when unauthenticated" do
      anon = build_conn()
      assert json_response(call(anon, :index, %{}), 401)["error"] == "authentication required"
      assert json_response(call(anon, :create_repository, %{"name" => "x"}), 401)["error"] == "authentication required"
    end

    test "returns 403 without catalog.* permissions across all actions" do
      no_perms = assign(build_conn(), :current_scope, scope_with_permissions([]))

      for {action, params, path_params} <- [
            {:index, %{}, %{}},
            {:show, %{"slug" => "storage-and-nvr-health"}, %{"slug" => "storage-and-nvr-health"}},
            {:export, %{"slug" => "storage-and-nvr-health"}, %{"slug" => "storage-and-nvr-health"}},
            {:export_custom, %{"spec" => %{"slug" => "x"}}, %{}},
            {:install, %{"slug" => "storage-and-nvr-health"}, %{"slug" => "storage-and-nvr-health"}},
            {:import_pack, %{"files" => %{"manifest.json" => "{}"}}, %{}},
            {:list_repositories, %{}, %{}},
            {:create_repository, %{"name" => "r"}, %{}},
            {:update_repository, %{"id" => @repo_id, "name" => "r"}, %{"id" => @repo_id}},
            {:delete_repository, %{"id" => @repo_id}, %{"id" => @repo_id}},
            {:sync_repository, %{"id" => @repo_id}, %{"id" => @repo_id}},
            {:gitops_push, %{"id" => @repo_id, "pack_slug" => "s"}, %{"id" => @repo_id}},
            {:gitops_pull, %{"id" => @repo_id, "slug" => "s"}, %{"id" => @repo_id}}
          ] do
        resp = call(no_perms, action, params, path_params)
        assert resp.status == 403, "expected 403 for #{action}, got #{resp.status}"
      end
    end
  end

  describe "packs export, import, install, repositories, and GitOps endpoints" do
    test "lists, shows, exports (.srpack and .json), imports with dry_run, and installs", %{conn: conn} do
      assert [%{"slug" => "storage-and-nvr-health"}] = json_response(call(conn, :index, %{}), 200)["data"]

      assert %{"slug" => "storage-and-nvr-health"} =
               json_response(
                 call(conn, :show, %{"slug" => "storage-and-nvr-health"}, %{"slug" => "storage-and-nvr-health"}),
                 200
               )["data"]

      srpack_resp =
        call(conn, :export, %{"slug" => "storage-and-nvr-health", "format" => "srpack"}, %{
          "slug" => "storage-and-nvr-health"
        })

      assert srpack_resp.status == 200

      assert get_resp_header(srpack_resp, "content-disposition") == [
               ~s(attachment; filename="storage-and-nvr-health.srpack")
             ]

      assert <<0x28, 0xB5, 0x2F, 0xFD, _::binary>> = srpack_resp.resp_body

      json_resp =
        call(conn, :export, %{"slug" => "storage-and-nvr-health", "format" => "json"}, %{
          "slug" => "storage-and-nvr-health"
        })

      assert json_resp.status == 200
      assert Jason.decode!(json_resp.resp_body)["pack_format_version"] == 1

      import_dry =
        json_response(
          call(conn, :import_pack, %{
            "dry_run" => true,
            "files" => %{"manifest.json" => "{}"},
            "config" => %{"warn" => 80}
          }),
          200
        )

      assert import_dry["data"]["dry_run"] == true
      assert import_dry["data"]["input_kind"] == "files"

      install_resp =
        json_response(
          call(
            conn,
            :install,
            %{"slug" => "storage-and-nvr-health", "dry_run" => false, "config" => %{"utilization_warn_pct" => 80}},
            %{"slug" => "storage-and-nvr-health"}
          ),
          200
        )

      assert install_resp["data"]["installed"] == true
    end

    test "manages repositories and executes GitOps push/pull + 409 branch conflict", %{conn: conn} do
      assert [%{"name" => "Official"}] = json_response(call(conn, :list_repositories, %{}), 200)["data"]

      created = json_response(call(conn, :create_repository, %{"repository" => %{"name" => "Private GitOps"}}), 201)
      assert created["data"]["name"] == "Private GitOps"

      updated =
        json_response(
          call(conn, :update_repository, %{"id" => @repo_id, "repository" => %{"name" => "Updated"}}, %{"id" => @repo_id}),
          200
        )

      assert updated["data"]["name"] == "Updated"
      assert call(conn, :delete_repository, %{"id" => @repo_id}, %{"id" => @repo_id}).status == 204

      assert json_response(call(conn, :sync_repository, %{"id" => @repo_id}, %{"id" => @repo_id}), 200)["data"][
               "pack_count"
             ] == 3

      push_ok =
        json_response(
          call(
            conn,
            :gitops_push,
            %{"id" => @repo_id, "pack_slug" => "storage-and-nvr-health", "commit_message" => "chore: sync"},
            %{"id" => @repo_id}
          ),
          200
        )

      assert push_ok["data"]["pr_url"] =~ "/pull/7"

      conflict =
        json_response(
          call(
            conn,
            :gitops_push,
            %{"id" => "conflict-repo", "pack_slug" => "storage-and-nvr-health"},
            %{"id" => "conflict-repo"}
          ),
          409
        )

      assert conflict["error"] == "upstream branch conflict"

      pull_preview =
        json_response(
          call(
            conn,
            :gitops_pull,
            %{"id" => @repo_id, "slug" => "storage-and-nvr-health", "dry_run" => true},
            %{"id" => @repo_id}
          ),
          200
        )

      assert pull_preview["data"]["dry_run"] == true
      assert pull_preview["data"]["source_commit_sha"] == "def456"
    end

    test "routes DELETE /api/v2/catalog/packs/:slug, forwards v2 install flags, and returns 409 on version_already_published" do
      assert %{plug: Controller, plug_opts: :uninstall} =
               Phoenix.Router.route_info(
                 Router,
                 "DELETE",
                 "/api/v2/catalog/packs/synthetic-vantage",
                 "localhost"
               )

      full_scope =
        scope_with_permissions([
          "catalog.view",
          "catalog.packs.install"
        ])

      conn = assign(build_conn(), :current_scope, full_scope)

      install_resp =
        json_response(
          call(
            conn,
            :install,
            %{
              "slug" => "synthetic-vantage",
              "activate_dashboard_packages" => "true",
              "install_paused" => "true"
            },
            %{"slug" => "synthetic-vantage"}
          ),
          200
        )

      assert install_resp["data"]["activate_dashboard_packages"] == true
      assert install_resp["data"]["install_paused"] == true

      conflict_resp =
        json_response(
          call(conn, :install, %{"slug" => "conflict-version"}, %{"slug" => "conflict-version"}),
          409
        )

      assert conflict_resp["error"] =~ "already published"

      uninstall_resp =
        json_response(
          call(conn, :uninstall, %{"slug" => "synthetic-vantage"}, %{"slug" => "synthetic-vantage"}),
          200
        )

      assert uninstall_resp["data"]["mode"] == "delete"

      detach_resp =
        json_response(
          call(
            conn,
            :uninstall,
            %{"slug" => "synthetic-vantage", "detach" => "true"},
            %{"slug" => "synthetic-vantage"}
          ),
          200
        )

      assert detach_resp["data"]["mode"] == "detach"
    end
  end

  defp call(conn, action, params, path_params \\ %{}) do
    conn = %{conn | path_params: path_params}
    apply(Controller, action, [conn, params])
  end

  defp scope_with_permissions(perms) do
    Scope.for_user(
      %{id: @user_id, email: "operator@example.com", role: :operator},
      permissions: MapSet.new(perms)
    )
  end
end
