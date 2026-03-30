defmodule ServiceRadarWebNGWeb.Api.CollectorControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import ServiceRadarWebNG.AshTestHelpers, only: [system_actor: 0]

  alias ServiceRadar.Edge.CollectorPackage
  alias ServiceRadar.Edge.NatsCredential

  defmodule BrokenCollectorBundleGenerator do
    @moduledoc false
    def create_tarball(_package, _creds, _tls_key, _opts), do: {:error, %{secret: "collector-bundle-secret"}}
  end

  describe "POST /api/admin/collectors/:id/download" do
    test "accepts a download token from the POST body", %{conn: _conn} do
      {package, token} = create_ready_collector_package(:flowgger)

      conn = post(build_conn(), ~p"/api/admin/collectors/#{package.id}/download", %{"download_token" => token})

      assert %{"package" => %{"status" => "delivered"}} = json_response(conn, 200)
    end

    test "rejects query-string token fallback", %{conn: _conn} do
      {package, token} = create_ready_collector_package(:flowgger)

      conn = post(build_conn(), ~p"/api/admin/collectors/#{package.id}/download?download_token=#{token}", %{})

      assert json_response(conn, 400)["error"] == "download_token is required"
    end
  end

  describe "POST /api/collectors/:id/bundle" do
    test "downloads a standard collector bundle from the public route", %{conn: _conn} do
      {package, token} = create_ready_collector_package(:flowgger)

      conn =
        build_conn()
        |> put_req_header("x-serviceradar-download-token", token)
        |> post(~p"/api/collectors/#{package.id}/bundle", %{})

      assert response_content_type(conn, :gzip) =~ "application/gzip"

      body = response(conn, 200)
      {:ok, files} = :erl_tar.extract({:binary, body}, [:compressed, :memory])
      file_names = Enum.map(files, fn {name, _content} -> to_string(name) end)

      assert Enum.any?(file_names, &String.ends_with?(&1, "/config/flowgger.toml"))
      assert Enum.any?(file_names, &String.ends_with?(&1, "/update.sh"))
      assert Enum.any?(file_names, &String.ends_with?(&1, "/certs/collector.pem"))
    end

    test "downloads a falcosidekick bundle that reuses runtime certs", %{conn: _conn} do
      {package, token} =
        create_ready_collector_package(:falcosidekick, %{
          config_overrides: %{
            "namespace" => "demo",
            "release_name" => "falcosidekick-nats-auth"
          }
        })

      conn =
        build_conn()
        |> put_req_header("x-serviceradar-download-token", token)
        |> post(~p"/api/collectors/#{package.id}/bundle", %{})

      assert response_content_type(conn, :gzip) =~ "application/gzip"

      body = response(conn, 200)
      {:ok, files} = :erl_tar.extract({:binary, body}, [:compressed, :memory])

      file_map =
        Map.new(files, fn {name, content} ->
          {to_string(name), IO.iodata_to_binary(content)}
        end)

      file_names = Map.keys(file_map)

      assert Enum.any?(file_names, &String.ends_with?(&1, "/falcosidekick.yaml"))
      assert Enum.any?(file_names, &String.ends_with?(&1, "/deploy.sh"))
      assert Enum.any?(file_names, &String.ends_with?(&1, "/README.md"))
      refute Enum.any?(file_names, &String.contains?(&1, "/certs/"))

      values_yaml = find_file(file_map, "falcosidekick.yaml")
      deploy_script = find_file(file_map, "deploy.sh")

      assert values_yaml =~ "secretName: serviceradar-runtime-certs"
      assert values_yaml =~ "/etc/serviceradar/certs/root.pem"
      assert deploy_script =~ ~s(SECRET_NAME="serviceradar-runtime-certs")
      refute deploy_script =~ "kubectl create secret generic"
      refute values_yaml =~ "serviceradar-falcosidekick-certs"
    end

    test "rejects bundle download when collector capability is disabled", %{conn: _conn} do
      previous_capabilities = Application.get_env(:serviceradar_web_ng, :runtime_capabilities)

      Application.put_env(:serviceradar_web_ng, :runtime_capabilities,
        configured?: true,
        enabled: []
      )

      on_exit(fn ->
        Application.put_env(:serviceradar_web_ng, :runtime_capabilities, previous_capabilities)
      end)

      {package, token} = create_ready_collector_package(:flowgger)

      conn =
        build_conn()
        |> put_req_header("x-serviceradar-download-token", token)
        |> post(~p"/api/collectors/#{package.id}/bundle", %{})

      assert json_response(conn, 403) == %{
               "error" => "collector onboarding is disabled for this deployment"
             }
    end

    test "rejects query-string token fallback on the public bundle route", %{conn: _conn} do
      {package, token} = create_ready_collector_package(:flowgger)

      conn = post(build_conn(), ~p"/api/collectors/#{package.id}/bundle?download_token=#{token}", %{})

      assert json_response(conn, 400)["error"] == "download token is required"
    end

    test "redacts internal bundle generation errors from the client", %{conn: _conn} do
      previous = Application.get_env(:serviceradar_web_ng, :collector_bundle_generator)
      Application.put_env(:serviceradar_web_ng, :collector_bundle_generator, BrokenCollectorBundleGenerator)

      on_exit(fn ->
        Application.put_env(:serviceradar_web_ng, :collector_bundle_generator, previous)
      end)

      {package, token} = create_ready_collector_package(:flowgger)

      conn =
        build_conn()
        |> put_req_header("x-serviceradar-download-token", token)
        |> post(~p"/api/collectors/#{package.id}/bundle", %{})

      assert json_response(conn, 500)["error"] == "bundle creation failed"
      refute conn.resp_body =~ "collector-bundle-secret"
    end
  end

  describe "POST /api/admin/collectors/:id/download" do
    test "returns a shell-literal-safe install script", %{conn: _conn} do
      {package, token} =
        create_ready_collector_package(:flowgger, %{
          site: "$(touch /tmp/site-pwned)",
          hostname: "$(touch /tmp/host-pwned)"
        })

      conn =
        post(build_conn(), ~p"/api/admin/collectors/#{package.id}/download", %{"download_token" => token})

      install_script = json_response(conn, 200)["install_script"]

      assert install_script =~ "SITE='$(touch /tmp/site-pwned)'"
      assert install_script =~ "HOSTNAME='$(touch /tmp/host-pwned)'"
      refute install_script =~ ~s|SITE="$(touch /tmp/site-pwned)"|
      refute install_script =~ ~s|HOSTNAME="$(touch /tmp/host-pwned)"|
    end
  end

  defp create_ready_collector_package(collector_type, overrides \\ %{}) do
    unique = System.unique_integer([:positive])
    token = "collector-bundle-token-#{unique}"
    token_hash = :sha256 |> :crypto.hash(token) |> Base.encode16(case: :lower)

    attrs =
      %{
        collector_type: collector_type,
        site: Map.get(overrides, :site, "demo"),
        hostname: Map.get(overrides, :hostname, "collector-#{unique}.example.com"),
        config_overrides: Map.get(overrides, :config_overrides, %{})
      }

    package =
      CollectorPackage
      |> Ash.Changeset.for_create(:create, attrs, actor: system_actor())
      |> Ash.Changeset.set_argument(:token_hash, token_hash)
      |> Ash.Changeset.set_argument(
        :token_expires_at,
        DateTime.add(DateTime.utc_now(), 86_400, :second)
      )
      |> Ash.create!(actor: system_actor())

    provisioning_package =
      package
      |> Ash.Changeset.for_update(:provision, %{}, actor: system_actor())
      |> Ash.update!(actor: system_actor())

    credential =
      NatsCredential
      |> Ash.Changeset.for_create(
        :create,
        %{
          user_name: "collector-cred-#{unique}",
          credential_type: :collector,
          expires_at: DateTime.add(DateTime.utc_now(), 30 * 86_400, :second),
          metadata: %{site: "demo"}
        },
        actor: system_actor()
      )
      |> Ash.Changeset.set_argument(:user_public_key, sample_user_public_key(unique))
      |> Ash.Changeset.set_argument(:onboarding_package_id, nil)
      |> Ash.create!(actor: system_actor())

    ready_package =
      provisioning_package
      |> Ash.Changeset.for_update(:ready, %{}, actor: system_actor())
      |> Ash.Changeset.set_argument(:nats_credential_id, credential.id)
      |> Ash.Changeset.set_argument(:nats_creds_content, sample_nats_creds())
      |> Ash.Changeset.set_argument(:tls_cert_pem, sample_tls_cert())
      |> Ash.Changeset.set_argument(:tls_key_pem, sample_tls_key())
      |> Ash.Changeset.set_argument(:ca_chain_pem, sample_ca_chain())
      |> Ash.update!(actor: system_actor())

    {ready_package, token}
  end

  defp find_file(file_map, suffix) do
    Enum.find_value(file_map, fn {name, content} ->
      if String.ends_with?(name, suffix), do: content
    end)
  end

  defp sample_nats_creds do
    """
    -----BEGIN NATS USER JWT-----
    dGVzdC11c2VyLWp3dA==
    ------END NATS USER JWT------
    """
  end

  defp sample_tls_cert do
    """
    -----BEGIN CERTIFICATE-----
    dGVzdC10bHMtY2VydA==
    -----END CERTIFICATE-----
    """
  end

  defp sample_tls_key do
    """
    -----BEGIN PRIVATE KEY-----
    dGVzdC10bHMta2V5
    -----END PRIVATE KEY-----
    """
  end

  defp sample_ca_chain do
    """
    -----BEGIN CERTIFICATE-----
    dGVzdC1jYS1jaGFpbg==
    -----END CERTIFICATE-----
    """
  end

  defp sample_user_public_key(unique) do
    suffix =
      unique
      |> Integer.to_string()
      |> String.pad_trailing(55, "A")
      |> String.slice(0, 55)

    "U" <> suffix
  end
end
