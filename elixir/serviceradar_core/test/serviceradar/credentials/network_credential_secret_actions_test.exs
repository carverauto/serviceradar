defmodule ServiceRadar.Credentials.NetworkCredentialSecretActionsTest do
  use ExUnit.Case, async: true

  alias Ash.Resource.Info
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials
  alias ServiceRadar.Credentials.NetworkCredentialSecret

  @manager %{
    id: "credential-manager",
    role: :admin,
    permissions: MapSet.new(["settings.credentials.manage"])
  }
  @system_actor SystemActor.system(:credential_secret_actions_test)
  @lifecycle_actions [
    :mark_rotation_due,
    :start_rotation,
    :complete_rotation,
    :fail_rotation,
    :disable_rotation,
    :enable_rotation
  ]

  test "human metadata actions cannot replace credential identity or material" do
    assert %{accept: [:name, :description]} =
             Info.action(NetworkCredentialSecret, :edit_details)

    assert %{accept: [:name, :description]} = Info.action(NetworkCredentialSecret, :update)

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
      refute field in Info.action(NetworkCredentialSecret, :update).accept
    end
  end

  test "rotation completion accepts descriptor-approved public username" do
    assert :username in Info.action(NetworkCredentialSecret, :complete_rotation).accept
  end

  test "raw lifecycle actions have no public interfaces and start accepts no metadata" do
    interface_names =
      NetworkCredentialSecret
      |> Info.interfaces()
      |> Enum.map(& &1.name)

    assert :edit_details in interface_names
    assert Info.action(NetworkCredentialSecret, :start_rotation).accept == []

    for action <- @lifecycle_actions do
      refute action in interface_names
    end
  end

  test "credential managers cannot invoke raw lifecycle actions directly" do
    for {action, state, attrs} <- lifecycle_cases() do
      manager_changeset = lifecycle_changeset(action, state, attrs, @manager)
      system_changeset = lifecycle_changeset(action, state, attrs, @system_actor)

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
end
