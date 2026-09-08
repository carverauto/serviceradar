defmodule ServiceRadar.Plugins.PluginRepositoryPolicyDbTest do
  @moduledoc """
  The authorization boundary around plugin repositories, and the guarantee that
  an attached access token never escapes through a read.

  The separation being tested is the point of the permission: staging a package
  imports from a source the platform already trusts, while adding a repository
  decides *which sources are trusted*. If `plugins.stage` were enough to do the
  second, anyone who could import a plugin could also declare what counts as a
  verified one.
  """

  use ServiceRadar.DataCase, async: true

  alias Ash.Error.Forbidden
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Plugins.PluginRepository
  alias ServiceRadar.Plugins.PluginRepositoryNotifier
  alias ServiceRadar.Plugins.RepositoryCredentials

  require Ash.Query

  @moduletag :integration

  # `ActorHasPermission` short-circuits on an actor carrying a MapSet of
  # permissions (checks.ex:288-291), so these actors exercise the policy without
  # needing a persisted user and role profile.
  defp actor_with(permissions) do
    %{
      id: Ecto.UUID.generate(),
      role: :operator,
      permissions: MapSet.new(permissions)
    }
  end

  defp stager, do: actor_with(["plugins.view", "plugins.stage", "plugins.approve"])
  defp repo_admin, do: actor_with(["plugins.view", "plugins.repositories.manage"])
  defp viewer, do: actor_with(["plugins.view"])

  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{
        name: "Acme Plugins",
        repo_url: "https://github.com/acme/policy-#{System.unique_integer([:positive])}",
        index_asset_name: "serviceradar-wasm-plugin-index.json",
        signing_key_id: "acme-v1",
        signing_public_key: Base.encode64(:crypto.strong_rand_bytes(32))
      },
      overrides
    )
  end

  defp create_as(actor, overrides \\ %{}) do
    PluginRepository
    |> Ash.Changeset.for_create(:create, attrs(overrides), actor: actor)
    |> Ash.create()
  end

  describe "create" do
    test "plugins.stage alone cannot add a repository" do
      assert {:error, %Forbidden{}} = create_as(stager())
    end

    test "plugins.repositories.manage can add a repository" do
      assert {:ok, repository} = create_as(repo_admin())
      assert repository.name == "Acme Plugins"
    end

    test "a viewer cannot add a repository" do
      assert {:error, %Forbidden{}} = create_as(viewer())
    end
  end

  describe "update and destroy" do
    setup do
      {:ok, repository} = create_as(repo_admin())
      %{repository: repository}
    end

    test "plugins.stage cannot edit a repository", %{repository: repository} do
      assert {:error, %Forbidden{}} =
               repository
               |> Ash.Changeset.for_update(:update, %{name: "Renamed"}, actor: stager())
               |> Ash.update()
    end

    test "plugins.stage cannot remove a repository", %{repository: repository} do
      assert {:error, %Forbidden{}} = Ash.destroy(repository, actor: stager())
    end

    test "plugins.stage cannot disable a repository", %{repository: repository} do
      # Disabling a source stops imports for everyone, so it belongs behind the
      # same permission as adding one.
      assert {:error, %Forbidden{}} =
               repository
               |> Ash.Changeset.for_update(:disable, %{}, actor: stager())
               |> Ash.update()
    end

    test "the repository manager can edit, disable and remove", %{repository: repository} do
      assert {:ok, renamed} =
               repository
               |> Ash.Changeset.for_update(:update, %{name: "Renamed"}, actor: repo_admin())
               |> Ash.update()

      assert renamed.name == "Renamed"

      assert {:ok, disabled} =
               renamed
               |> Ash.Changeset.for_update(:disable, %{}, actor: repo_admin())
               |> Ash.update()

      refute disabled.enabled
      assert :ok = Ash.destroy(disabled, actor: repo_admin())
    end
  end

  describe "reads" do
    test "a viewer can list repositories" do
      # Switching which catalog you are looking at is a read; only managing
      # sources is gated.
      {:ok, _repository} = create_as(repo_admin())

      assert {:ok, repositories} =
               PluginRepository |> Ash.Query.for_read(:read) |> Ash.read(actor: viewer())

      assert repositories != []
    end
  end

  describe "audit details" do
    test "record what changed without carrying credential material" do
      {:ok, repository} = create_as(repo_admin())
      token = "ghp_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

      {:ok, repository} =
        RepositoryCredentials.put_token(repository, token, actor: SystemActor.system(:test))

      details = PluginRepositoryNotifier.audit_details(repository)

      assert details.repo_url == repository.repo_url
      assert details.signing_key_id == "acme-v1"
      assert details.enabled
      refute details.builtin

      # The whole point: an auditor learns a token is attached, never its value
      # or which secret holds it.
      assert details.credential_attached == true
      refute details |> inspect() |> String.contains?(token)
      refute details |> inspect() |> String.contains?(repository.credential_secret_id)
    end

    test "report no credential on a public repository" do
      {:ok, repository} = create_as(repo_admin())

      assert PluginRepositoryNotifier.audit_details(repository).credential_attached == false
    end
  end

  describe "attached credentials" do
    setup do
      {:ok, repository} = create_as(repo_admin())
      %{repository: repository}
    end

    test "the token is stored, encrypted, and never returned by a read", %{repository: repository} do
      token = "ghp_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

      assert {:ok, repository} =
               RepositoryCredentials.put_token(repository, token,
                 actor: SystemActor.system(:test)
               )

      assert repository.credential_secret_id

      # A plain read of the repository must not carry the token in any field.
      {:ok, reloaded} =
        PluginRepository
        |> Ash.Query.for_read(:by_id, %{id: repository.id})
        |> Ash.read_one(actor: viewer())

      refute reloaded |> Map.from_struct() |> inspect() |> String.contains?(token)

      # Nor may a read of the credential secret itself: `read` selects only the
      # public fields, which exclude the encrypted payload.
      {:ok, secret} =
        NetworkCredentialSecret
        |> Ash.Query.for_read(:by_id, %{id: repository.credential_secret_id})
        |> Ash.read_one(actor: SystemActor.system(:test))

      refute secret |> Map.from_struct() |> inspect() |> String.contains?(token)
      assert secret.credential_kind == :api_token
    end

    test "fetch_token returns the token only at the point of use", %{repository: repository} do
      token = "ghp_fetchable"

      {:ok, repository} =
        RepositoryCredentials.put_token(repository, token, actor: SystemActor.system(:test))

      assert {:ok, ^token} =
               RepositoryCredentials.fetch_token(repository, actor: SystemActor.system(:test))
    end

    test "a repository with no credential resolves to nil rather than an error", %{
      repository: repository
    } do
      # A public repository is not a failure.
      assert {:ok, nil} =
               RepositoryCredentials.fetch_token(repository, actor: SystemActor.system(:test))
    end

    test "replacing a token retires the old secret and leaves none active but unreferenced", %{
      repository: repository
    } do
      # In-place payload updates are impossible on this resource: AshCloak's
      # encryption is non-atomic and there is no primary read to upgrade
      # through, so Ash raises MustBeAtomic. Replacement therefore creates a new
      # secret and disables the old one.
      {:ok, repository} =
        RepositoryCredentials.put_token(repository, "ghp_first", actor: SystemActor.system(:test))

      first_secret_id = repository.credential_secret_id

      {:ok, repository} =
        RepositoryCredentials.put_token(repository, "ghp_second",
          actor: SystemActor.system(:test)
        )

      assert repository.credential_secret_id != first_secret_id

      assert {:ok, "ghp_second"} =
               RepositoryCredentials.fetch_token(repository, actor: SystemActor.system(:test))

      {:ok, retired} =
        NetworkCredentialSecret
        |> Ash.Query.for_read(:by_id, %{id: first_secret_id})
        |> Ash.read_one(actor: SystemActor.system(:test))

      assert retired.rotation_state == :disabled
    end

    test "clearing detaches the link and retires the secret", %{repository: repository} do
      {:ok, repository} =
        RepositoryCredentials.put_token(repository, "ghp_gone", actor: SystemActor.system(:test))

      secret_id = repository.credential_secret_id

      assert {:ok, cleared} =
               RepositoryCredentials.clear_token(repository, actor: SystemActor.system(:test))

      assert is_nil(cleared.credential_secret_id)

      # The resource has no destroy action -- credentials retire through the
      # rotation state machine -- so "removed" means disabled, not absent. What
      # matters is that nothing is left active and unreferenced.
      {:ok, retired} =
        NetworkCredentialSecret
        |> Ash.Query.for_read(:by_id, %{id: secret_id})
        |> Ash.read_one(actor: SystemActor.system(:test))

      assert retired.rotation_state == :disabled
    end
  end
end
