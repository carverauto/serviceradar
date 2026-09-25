defmodule ServiceRadar.Credentials.NetworkCredentialSecretActionsTest do
  use ExUnit.Case, async: true

  alias Ash.Resource.Info
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials
  alias ServiceRadar.Credentials.CredentialSecretProvider
  alias ServiceRadar.Credentials.CredentialSecretResolutionAudit
  alias ServiceRadar.Credentials.NetworkCredentialRule
  alias ServiceRadar.Credentials.NetworkCredentialSecret

  @manager %{
    id: "credential-manager",
    role: :admin,
    permissions: MapSet.new(["settings.credentials.manage"])
  }
  @viewer %{id: "credential-viewer", role: :viewer, permissions: MapSet.new([])}
  @system_actor SystemActor.system(:credential_secret_actions_test)
  @secret_id "018f3f56-1111-7222-8333-123456789abc"

  test "human metadata actions cannot replace credential identity or material" do
    assert %{accept: [:name, :description]} =
             Info.action(NetworkCredentialSecret, :edit_details)

    for field <- [
          :secret_payload,
          :provider,
          :credential_kind,
          :source_type,
          :metadata,
          :username,
          :public_fingerprint,
          :next_rotation_due_at
        ] do
      refute field in Info.action(NetworkCredentialSecret, :edit_details).accept
    end
  end

  test "credential managers cannot invoke raw lifecycle actions directly" do
    assert Info.action(NetworkCredentialSecret, :start_rotation).accept == []

    for {action, state, attrs} <- lifecycle_cases() do
      manager_changeset = lifecycle_changeset(action, state, attrs, @manager)
      system_changeset = lifecycle_changeset(action, state, attrs, @system_actor)

      assert Ash.Policy.Info.strict_check(@manager, manager_changeset, Credentials) == false
      assert Ash.Policy.Info.strict_check(@system_actor, system_changeset, Credentials) == true
    end
  end

  test "creating secrets and providers requires the credential management permission" do
    for resource <- [NetworkCredentialSecret, CredentialSecretProvider] do
      manager_changeset = Ash.Changeset.for_create(resource, :create, %{}, actor: @manager)
      viewer_changeset = Ash.Changeset.for_create(resource, :create, %{}, actor: @viewer)

      assert Ash.Policy.Info.strict_check(@manager, manager_changeset, Credentials) == true
      assert Ash.Policy.Info.strict_check(@viewer, viewer_changeset, Credentials) == false
    end
  end

  test "public read actions select only redacted credential metadata" do
    for action <- [:read, :by_id, :by_provider] do
      selected =
        action
        |> public_read_query()
        |> selected_fields()

      assert :id in selected
      assert :name in selected
      assert :provider in selected
      assert :credential_kind in selected
      assert :username in selected
      assert :public_fingerprint in selected
      assert :source_type in selected
      assert :external_secret_ref in selected
      assert :last_rotated_at in selected
      assert :next_rotation_due_at in selected

      refute :encrypted_secret_payload in selected
    end
  end

  # Only the selection is checked here. The policy half -- a credential manager
  # cannot run this read -- is a filter policy, which a pre-flight check reports
  # as authorized-with-an-empty-filter, so it is asserted against the database in
  # CredentialRotationDbTest.
  test "system secret resolution read selects the ciphertext and the resolution fields" do
    selected =
      NetworkCredentialSecret
      |> Ash.Query.for_read(:by_id_with_secret, %{id: @secret_id}, actor: @system_actor)
      |> selected_fields()

    assert :id in selected
    assert :provider in selected
    assert :credential_kind in selected
    assert :username in selected
    assert :metadata in selected
    assert :source_type in selected
    assert :external_secret_ref in selected
    assert :encrypted_secret_payload in selected
  end

  test "encrypted backing field is non-public and sensitive" do
    encrypted = Info.attribute(NetworkCredentialSecret, :encrypted_secret_payload)

    assert encrypted.public? == false
    assert encrypted.sensitive? == true
    assert Map.has_key?(struct(NetworkCredentialSecret), :secret_payload)
  end

  describe "NetworkCredentialRule" do
    test "integration and controller scope is generated and immutable" do
      integration = Info.attribute(NetworkCredentialRule, :integration_id)
      controller = Info.attribute(NetworkCredentialRule, :controller_id)

      assert integration.allow_nil? == false
      assert controller.allow_nil? == false
      assert is_function(integration.default, 0)
      assert is_function(controller.default, 0)

      for action_name <- [:create, :update], field <- [:integration_id, :controller_id] do
        refute field in Info.action(NetworkCredentialRule, action_name).accept
      end
    end
  end

  describe "CredentialSecretResolutionAudit" do
    test "audit creation is system-only" do
      manager_changeset =
        Ash.Changeset.for_create(CredentialSecretResolutionAudit, :create, %{}, actor: @manager)

      system_changeset =
        Ash.Changeset.for_create(CredentialSecretResolutionAudit, :create, %{},
          actor: @system_actor
        )

      assert Ash.Policy.Info.strict_check(@manager, manager_changeset, Credentials) == false
      assert Ash.Policy.Info.strict_check(@system_actor, system_changeset, Credentials) == true
    end
  end

  defp lifecycle_cases do
    [
      {:mark_rotation_due, :active, %{}},
      {:start_rotation, :active, %{}},
      {:complete_rotation, :rotating,
       %{
         secret_payload: "replacement",
         username: "operator",
         public_fingerprint: "sha256:replacement",
         metadata: %{
           "credential_descriptor" => "package_manifest.v1",
           "auth_method" => "username_password"
         }
       }},
      {:fail_rotation, :rotating, %{message: "rotation_complete_failed"}},
      {:disable_rotation, :active, %{}},
      {:enable_rotation, :disabled, %{}}
    ]
  end

  defp lifecycle_changeset(action, state, attrs, actor) do
    secret =
      struct(NetworkCredentialSecret,
        id: "01900000-0000-7000-8000-000000000001",
        name: "Credential",
        provider: "example-network",
        credential_kind: :username_password,
        source_type: :internal_encrypted,
        rotation_state: state,
        metadata: %{
          "credential_descriptor" => "package_manifest.v1",
          "auth_method" => "username_password"
        }
      )

    Ash.Changeset.for_update(secret, action, attrs, actor: actor)
  end

  defp public_read_query(:read) do
    Ash.Query.for_read(NetworkCredentialSecret, :read, %{}, actor: @manager)
  end

  defp public_read_query(:by_id) do
    Ash.Query.for_read(NetworkCredentialSecret, :by_id, %{id: @secret_id}, actor: @manager)
  end

  defp public_read_query(:by_provider) do
    Ash.Query.for_read(NetworkCredentialSecret, :by_provider, %{provider: "example-network"},
      actor: @manager
    )
  end

  defp selected_fields(%Ash.Query{select: select}) when is_list(select), do: select
end
