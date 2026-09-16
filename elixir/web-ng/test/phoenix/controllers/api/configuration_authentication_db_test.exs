defmodule ServiceRadarWebNGWeb.Api.ConfigurationAuthenticationDbTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import ServiceRadarWebNG.AshTestHelpers, only: [admin_user_fixture: 0, viewer_user_fixture: 0]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.ApiToken
  alias ServiceRadar.Identity.OAuthClient.Credentials
  alias ServiceRadar.Identity.User
  alias ServiceRadar.Repo
  alias ServiceRadarWebNG.Auth.Guardian

  @moduletag :web_ng_shared_fixture_db
  @actor SystemActor.system(:configuration_authentication_test)

  test "a persisted read-only administrator API key can read but cannot create configuration" do
    user = admin_user_fixture()
    {_record, key} = api_key(user, "read")
    assert %{"items" => _items} = key |> key_request() |> get(~p"/api/admin/ansible-repositories") |> json_response(200)

    attrs = repository_attrs()
    denied = key |> key_request() |> create_repository(attrs)
    assert json_response(denied, 403)["error"] == "insufficient_scope"
    assert_repository_absent(attrs)
  end

  test "a persisted write API key does not grant its viewer owner configuration RBAC" do
    {_record, key} = api_key(viewer_user_fixture(), "write")
    attrs = repository_attrs()
    denied = key |> key_request() |> create_repository(attrs)
    assert denied.status == 403
    assert_repository_absent(attrs)
  end

  test "revoking a persisted key rejects the next request before configuration mutation" do
    {record, key} = api_key(admin_user_fixture(), "write")
    assert (key |> key_request() |> get(~p"/api/admin/ansible-repositories")).status == 200

    record |> Ash.Changeset.for_update(:revoke, %{}, actor: @actor) |> Ash.update!(actor: @actor)
    attrs = repository_attrs()
    assert (key |> key_request() |> create_repository(attrs)).status == 401
    assert_repository_absent(attrs)
  end

  test "an inactive owner cannot use either a persisted key or an already-issued bearer token" do
    user = viewer_user_fixture()
    {_record, key} = api_key(user, "write")
    {:ok, bearer, _claims} = Guardian.create_access_token(user)
    {:ok, _inactive} = User.deactivate(user, actor: @actor)
    attrs = repository_attrs()

    assert (key |> key_request() |> create_repository(attrs)).status == 401

    bearer_request = put_req_header(build_conn(), "authorization", "Bearer #{bearer}")
    assert create_repository(bearer_request, attrs).status == 401
    assert_repository_absent(attrs)
  end

  test "an unscoped OAuth API bearer cannot inherit its administrator owner's mutation authority" do
    user = admin_user_fixture()

    {:ok, client, _secret} =
      Credentials.create_client(user.id,
        name: "example-oauth-#{Ash.UUID.generate()}",
        scopes: ["write"],
        actor: @actor
      )

    {:ok, token, claims} =
      Guardian.create_api_token(user, scopes: [], claims: %{"client_id" => client.id})

    assert claims["typ"] == "api"
    refute Map.has_key?(claims, "scopes")
    attrs = repository_attrs()

    denied =
      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> create_repository(attrs)

    assert json_response(denied, 403)["error"] == "insufficient_scope"
    assert_repository_absent(attrs)
  end

  defp api_key(user, scope) do
    token = "sr_example_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    record =
      ApiToken
      |> Ash.Changeset.for_create(:create, %{name: "Example key", user_id: user.id, scope: scope, token: token},
        actor: @actor
      )
      |> Ash.create!(actor: @actor)

    {record, token}
  end

  defp key_request(key), do: put_req_header(build_conn(), "x-api-key", key)

  defp repository_attrs do
    marker = Ash.UUID.generate()
    %{"name" => "Example auth catalog #{marker}", "git_url" => "https://git.example.com/#{marker}.git"}
  end

  defp create_repository(conn, attrs) do
    conn |> put_req_header("idempotency-key", Ash.UUID.generate()) |> post(~p"/api/admin/ansible-repositories", attrs)
  end

  defp assert_repository_absent(attrs) do
    assert %{rows: [[0]]} =
             Repo.query!("SELECT count(*) FROM platform.ansible_playbook_repositories WHERE name = $1", [attrs["name"]])
  end
end
