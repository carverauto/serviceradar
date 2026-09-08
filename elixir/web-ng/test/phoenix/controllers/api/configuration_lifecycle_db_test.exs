defmodule ServiceRadarWebNGWeb.Api.ConfigurationLifecycleDbTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import ServiceRadarWebNG.AshTestHelpers, only: [admin_user_fixture: 0]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Repo
  alias ServiceRadarWebNG.Auth.Guardian

  @moduletag :web_ng_shared_fixture_db

  setup do
    user = admin_user_fixture()
    {:ok, token, _claims} = Guardian.create_access_token(user)
    %{token: token}
  end

  test "repository replay is stable and stale ETags cannot update or delete a newer row", %{
    token: token
  } do
    marker = Ash.UUID.generate()
    key = Ash.UUID.generate()

    attrs = %{
      "name" => "Example repository #{marker}",
      "git_url" => "https://git.example.com/project/#{marker}.git"
    }

    created =
      token
      |> request()
      |> put_req_header("idempotency-key", key)
      |> post(~p"/api/admin/ansible-repositories", attrs)

    assert %{"id" => id} = json_response(created, 201)
    [initial_etag] = get_resp_header(created, "etag")

    replayed =
      token
      |> request()
      |> put_req_header("idempotency-key", key)
      |> post(~p"/api/admin/ansible-repositories", attrs)

    assert %{"id" => ^id} = json_response(replayed, 201)
    assert get_resp_header(replayed, "etag") == [initial_etag]

    conflict =
      token
      |> request()
      |> put_req_header("idempotency-key", key)
      |> post(
        ~p"/api/admin/ansible-repositories",
        Map.put(attrs, "name", "Another synthetic request")
      )

    assert conflict.status == 409

    Repo.query!(
      """
      UPDATE platform.ansible_playbook_repositories
      SET name = 'Intervening operator edit', updated_at = updated_at + interval '1 microsecond'
      WHERE id = ($1::text)::uuid
      """,
      [id]
    )

    stale_update =
      token
      |> request()
      |> put_req_header("if-match", initial_etag)
      |> patch(~p"/api/admin/ansible-repositories/#{id}", %{"name" => "Stale overwrite"})

    assert stale_update.status == 409

    stale_delete =
      token
      |> request()
      |> put_req_header("if-match", initial_etag)
      |> delete(~p"/api/admin/ansible-repositories/#{id}")

    assert stale_delete.status == 409

    observed = token |> request() |> get(~p"/api/admin/ansible-repositories/#{id}")
    assert %{"name" => "Intervening operator edit"} = json_response(observed, 200)
    [current_etag] = get_resp_header(observed, "etag")

    updated =
      token
      |> request()
      |> put_req_header("if-match", current_etag)
      |> patch(~p"/api/admin/ansible-repositories/#{id}", %{
        "description" => "Reviewed current version"
      })

    assert %{"description" => "Reviewed current version"} = json_response(updated, 200)
    [current_etag] = get_resp_header(updated, "etag")
    before_delete = version_actions(:repository, id)
    assert "create" in before_delete
    assert "update" in before_delete

    deleted =
      token
      |> request()
      |> put_req_header("if-match", current_etag)
      |> delete(~p"/api/admin/ansible-repositories/#{id}")

    assert deleted.status == 204
    assert (token |> request() |> get(~p"/api/admin/ansible-repositories/#{id}")).status == 404
    assert Enum.sort(version_actions(:repository, id)) == Enum.sort(["destroy" | before_delete])

    deleted_replay =
      token
      |> request()
      |> put_req_header("idempotency-key", key)
      |> post(~p"/api/admin/ansible-repositories", attrs)

    assert deleted_replay.status == 410
    assert (token |> request() |> get(~p"/api/admin/ansible-repositories/#{id}")).status == 404
  end

  test "deleting an unused disabled controller retains its complete audit history", %{
    token: token
  } do
    marker = Ash.UUID.generate()

    {:ok, secret} =
      NetworkCredentialSecret.create_secret(
        %{
          name: "Example AWX credential #{marker}",
          provider: "awx",
          credential_kind: :api_token,
          source_type: :internal_encrypted,
          secret_payload: "invented-controller-token",
          metadata: %{"auth_method" => "bearer_token"}
        },
        actor: SystemActor.system(:configuration_lifecycle_db_test)
      )

    created =
      token
      |> request()
      |> put_req_header("idempotency-key", Ash.UUID.generate())
      |> post(~p"/api/admin/ansible-controllers", %{
        "name" => "Example controller #{marker}",
        "base_url" => "https://awx.example.com",
        "agent_id" => Ash.UUID.generate(),
        "sync_credential_secret_id" => secret.id,
        "enabled" => false
      })

    assert %{"id" => id} = json_response(created, 201)
    [etag] = get_resp_header(created, "etag")
    before_delete = version_actions(:controller, id)
    assert "create" in before_delete

    Repo.query!(
      """
      UPDATE platform.ansible_controllers
      SET updated_at = updated_at + interval '1 microsecond'
      WHERE id = ($1::text)::uuid
      """,
      [id]
    )

    stale_delete =
      token
      |> request()
      |> put_req_header("if-match", etag)
      |> delete(~p"/api/admin/ansible-controllers/#{id}")

    assert stale_delete.status == 409
    current = token |> request() |> get(~p"/api/admin/ansible-controllers/#{id}")
    assert %{"id" => ^id} = json_response(current, 200)
    [etag] = get_resp_header(current, "etag")

    deleted =
      token
      |> request()
      |> put_req_header("if-match", etag)
      |> delete(~p"/api/admin/ansible-controllers/#{id}")

    assert deleted.status == 204
    assert (token |> request() |> get(~p"/api/admin/ansible-controllers/#{id}")).status == 404
    assert Enum.sort(version_actions(:controller, id)) == Enum.sort(["destroy" | before_delete])
  end

  test "credential rotation replay ignores its old ETag without rotating twice or disclosing material",
       %{token: token} do
    marker = Ash.UUID.generate()
    initial_material = "invented-community-before-rotation"
    rotated_material = "invented-community-after-rotation"

    created =
      token
      |> request()
      |> put_req_header("idempotency-key", Ash.UUID.generate())
      |> post(~p"/api/admin/network-credential-secrets", %{
        "name" => "Example credential #{marker}",
        "provider" => "snmp",
        "auth_method" => "community",
        "values" => %{"community" => initial_material}
      })

    assert %{"id" => id} = json_response(created, 201)
    [initial_etag] = get_resp_header(created, "etag")
    refute created.resp_body =~ initial_material
    key = Ash.UUID.generate()
    attrs = %{"values" => %{"community" => rotated_material}}

    rotated =
      token
      |> request()
      |> put_req_header("if-match", initial_etag)
      |> put_req_header("idempotency-key", key)
      |> post(~p"/api/admin/network-credential-secrets/#{id}/rotate", attrs)

    assert %{"id" => ^id, "rotation_state" => "active"} = json_response(rotated, 200)
    [rotation_etag] = get_resp_header(rotated, "etag")
    assert completed_rotations(id) == 1
    refute rotated.resp_body =~ rotated_material

    replayed =
      token
      |> request()
      |> put_req_header("if-match", initial_etag)
      |> put_req_header("idempotency-key", key)
      |> post(~p"/api/admin/network-credential-secrets/#{id}/rotate", attrs)

    assert %{"id" => ^id} = json_response(replayed, 200)
    assert get_resp_header(replayed, "etag") == [rotation_etag]
    assert completed_rotations(id) == 1

    stale_rotation =
      token
      |> request()
      |> put_req_header("if-match", initial_etag)
      |> put_req_header("idempotency-key", Ash.UUID.generate())
      |> post(~p"/api/admin/network-credential-secrets/#{id}/rotate", attrs)

    assert stale_rotation.status == 409
    assert completed_rotations(id) == 1

    %{rows: [[stored]]} =
      Repo.query!(
        """
        SELECT string_agg(row_to_json(receipt)::text, '')
        FROM platform.ansible_provisioning_requests receipt
        WHERE resource_id = ($1::text)::uuid
        """,
        [id]
      )

    refute stored =~ initial_material
    refute stored =~ rotated_material
    refute replayed.resp_body =~ rotated_material
  end

  defp request(token), do: put_req_header(build_conn(), "authorization", "Bearer #{token}")

  defp version_actions(kind, id) do
    table =
      case kind do
        :repository -> "ansible_playbook_repository_versions"
        :controller -> "ansible_controller_versions"
      end

    %{rows: rows} =
      Repo.query!(
        "SELECT version_action_name FROM platform.#{table} WHERE version_source_id = ($1::text)::uuid",
        [id]
      )

    List.flatten(rows)
  end

  defp completed_rotations(id) do
    %{rows: [[count]]} =
      Repo.query!(
        """
        SELECT count(*) FROM platform.network_credential_secret_versions
        WHERE version_source_id = ($1::text)::uuid AND version_action_name = 'complete_rotation'
        """,
        [id]
      )

    count
  end
end
