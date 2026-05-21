defmodule ServiceRadar.Credentials.OpenBaoAdapterTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Credentials.SecretProviderAdapters.OpenBao

  test "resolves KV v2 value field from OpenBao" do
    request_fun = fn request ->
      assert request[:method] == :get
      assert request[:url] == "http://openbao.vault.svc:8200/v1/secret/data/network/snmp/core"
      assert {"x-vault-token", "test-token"} in request[:headers]

      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "data" => %{"community" => "bao-public"},
             "metadata" => %{"version" => 7}
           }
         }
       }}
    end

    assert {:ok, resolved} =
             OpenBao.resolve(
               %{
                 provider_type: :openbao,
                 external_secret_ref: "network/snmp/core",
                 external_secret_fields: %{"value" => "community"}
               },
               provider(),
               openbao_token: "test-token",
               request_fun: request_fun
             )

    assert resolved.value == "bao-public"
    assert resolved.metadata["adapter"] == "openbao"
    assert resolved.metadata["kv_version"] == 2
  end

  test "returns structured JSON when no single value field is selected" do
    request_fun = fn _request ->
      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "data" => %{
               "version" => "v3",
               "username" => "snmp-user",
               "auth_password" => "auth-pass"
             }
           }
         }
       }}
    end

    assert {:ok, resolved} =
             OpenBao.resolve(
               %{provider_type: :openbao, external_secret_ref: "network/snmp/v3"},
               provider(),
               openbao_token: "test-token",
               request_fun: request_fun
             )

    assert {:ok, decoded} = Jason.decode(resolved.value)
    assert decoded["version"] == "v3"
    assert decoded["username"] == "snmp-user"
    assert decoded["auth_password"] == "auth-pass"
  end

  test "authenticates with Kubernetes auth before resolving a secret" do
    request_fun = fn request ->
      cond do
        request[:method] == :post ->
          assert request[:url] == "http://openbao.vault.svc:8200/v1/auth/k8s-demo/login"
          assert request[:json] == %{role: "serviceradar-core", jwt: "service-account-jwt"}

          {:ok,
           %{
             status: 200,
             body: %{"auth" => %{"client_token" => "kubernetes-login-token"}}
           }}

        request[:method] == :get ->
          assert request[:url] == "http://openbao.vault.svc:8200/v1/secret/data/network/snmp/core"
          assert {"x-vault-token", "kubernetes-login-token"} in request[:headers]

          {:ok,
           %{
             status: 200,
             body: %{"data" => %{"data" => %{"community" => "bao-public"}}}
           }}
      end
    end

    provider =
      provider(%{
        "auth_method" => "kubernetes",
        "kubernetes_auth_mount" => "k8s-demo",
        "kubernetes_role" => "serviceradar-core"
      })

    assert {:ok, resolved} =
             OpenBao.resolve(
               %{
                 provider_type: :openbao,
                 external_secret_ref: "network/snmp/core",
                 external_secret_fields: %{"value" => "community"}
               },
               provider,
               kubernetes_jwt: "service-account-jwt",
               request_fun: request_fun
             )

    assert resolved.value == "bao-public"
  end

  test "maps HTTP failures to broker error classes" do
    request_fun = fn _request -> {:ok, %{status: 403, body: %{}}} end

    assert {:error, :unauthorized} =
             OpenBao.resolve(
               %{provider_type: :openbao, external_secret_ref: "network/snmp/core"},
               provider(),
               openbao_token: "test-token",
               request_fun: request_fun
             )
  end

  defp provider(metadata \\ %{}) do
    %{
      provider_type: :openbao,
      endpoint_url: "http://openbao.vault.svc:8200",
      metadata: Map.merge(%{"kv_mount" => "secret", "kv_version" => "2"}, metadata)
    }
  end
end
