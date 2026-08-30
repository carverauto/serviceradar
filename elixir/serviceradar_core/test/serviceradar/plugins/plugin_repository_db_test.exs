defmodule ServiceRadar.Plugins.PluginRepositoryDbTest do
  @moduledoc """
  Covers the invariants that make a plugin repository a trust anchor rather than
  a bookmark: it must carry a usable signing key, its URL must be canonical so
  one repository cannot become two rows with two keys, and the seeded built-in
  source must be neither editable nor deletable.
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.PluginRepository

  require Ash.Query

  @moduletag :integration

  defp actor, do: SystemActor.system(:test)

  defp valid_key, do: Base.encode64(:crypto.strong_rand_bytes(32))

  defp create(attrs) do
    defaults = %{
      name: "Acme Plugins",
      repo_url: "https://github.com/acme/sr-plugins-#{System.unique_integer([:positive])}",
      index_asset_name: "serviceradar-wasm-plugin-index.json",
      signing_key_id: "acme-v1",
      signing_public_key: valid_key()
    }

    PluginRepository
    |> Ash.Changeset.for_create(:create, Map.merge(defaults, attrs), actor: actor())
    |> Ash.create()
  end

  describe "signing key" do
    test "a repository requires a signing key id and public key" do
      assert {:error, _} = create(%{signing_key_id: nil})
      assert {:error, _} = create(%{signing_public_key: nil})
    end

    test "rejects a public key that is not base64" do
      assert {:error, error} = create(%{signing_public_key: "not base64!!"})
      assert error_mentions?(error, "base64")
    end

    test "rejects a key of the wrong length" do
      # ed25519 public keys are exactly 32 bytes. A shorter key would fail every
      # signature check with :invalid_signature, which says nothing about the
      # key being the problem.
      assert {:error, error} = create(%{signing_public_key: Base.encode64(<<1, 2, 3>>)})
      assert error_mentions?(error, "32-byte")
    end

    test "accepts a valid 32-byte key" do
      assert {:ok, repository} = create(%{})
      assert repository.signing_key_id == "acme-v1"
    end
  end

  describe "repository url" do
    test "rejects a non-GitHub host" do
      assert {:error, error} = create(%{repo_url: "https://gitlab.com/acme/plugins"})
      assert error_mentions?(error, "github.com")
    end

    test "rejects a url with no repository segment" do
      assert {:error, _} = create(%{repo_url: "https://github.com/acme"})
    end

    test "normalizes a .git suffix so one repository cannot become two rows" do
      assert {:ok, repository} = create(%{repo_url: "https://github.com/acme/normalize-me.git"})
      assert repository.repo_url == "https://github.com/acme/normalize-me"
    end

    test "the same repository cannot be registered twice under different spellings" do
      assert {:ok, _} = create(%{repo_url: "https://github.com/acme/dupe"})
      assert {:error, _} = create(%{repo_url: "https://github.com/acme/dupe.git"})
    end
  end

  describe "the seeded built-in repository" do
    setup do
      builtin =
        PluginRepository
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(builtin == true)
        |> Ash.read_one!(actor: actor())

      %{builtin: builtin}
    end

    test "is seeded by the migration and is the default", %{builtin: builtin} do
      assert builtin
      assert builtin.is_default
      assert builtin.repo_url == "https://github.com/carverauto/serviceradar"
      assert builtin.signing_public_key
    end

    test "cannot be edited", %{builtin: builtin} do
      assert {:error, error} =
               builtin
               |> Ash.Changeset.for_update(:update, %{name: "Hijacked"}, actor: actor())
               |> Ash.update()

      assert error_mentions?(error, "built-in")
    end

    test "cannot be deleted", %{builtin: builtin} do
      assert {:error, error} = Ash.destroy(builtin, actor: actor())
      assert error_mentions?(error, "built-in")
    end

    test "can be disabled and re-enabled", %{builtin: builtin} do
      # Disabling is a legitimate operator decision -- "stop importing from
      # upstream" -- which is why it is not blocked with edit and delete.
      assert {:ok, disabled} =
               builtin |> Ash.Changeset.for_update(:disable, %{}, actor: actor()) |> Ash.update()

      refute disabled.enabled

      assert {:ok, enabled} =
               disabled |> Ash.Changeset.for_update(:enable, %{}, actor: actor()) |> Ash.update()

      assert enabled.enabled
    end
  end

  describe "the migration seed" do
    test "leaves exactly one built-in row and exactly one default" do
      # The migration ends with a DO $$ block that raises unless exactly one
      # default row exists, and its INSERT is keyed ON CONFLICT (repo_url) so a
      # re-run cannot duplicate. This asserts the post-condition that guard
      # exists to protect: a deployment with two defaults, or none, would import
      # from the wrong place or from nowhere.
      builtins =
        PluginRepository
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(builtin == true)
        |> Ash.read!(actor: actor())

      defaults =
        PluginRepository
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(is_default == true)
        |> Ash.read!(actor: actor())

      assert length(builtins) == 1
      assert length(defaults) == 1
      assert hd(builtins).id == hd(defaults).id
    end

    test "the seeded row is unique on repo_url, so a re-run cannot duplicate it" do
      assert {:error, _} = create(%{repo_url: "https://github.com/carverauto/serviceradar"})
    end
  end

  describe "single default" do
    test "a second default row is rejected by the partial unique index" do
      assert {:ok, repository} = create(%{})

      assert_raise Postgrex.Error, fn ->
        ServiceRadar.Repo.query!(
          "UPDATE platform.plugin_repositories SET is_default = true WHERE id = $1",
          [Ecto.UUID.dump!(repository.id)]
        )
      end
    end
  end

  describe "sync state" do
    test "records success and clears a previous error" do
      {:ok, repository} = create(%{})

      {:ok, failed} =
        repository
        |> Ash.Changeset.for_update(:record_sync_error, %{last_sync_error: "boom"},
          actor: actor()
        )
        |> Ash.update()

      assert failed.last_sync_error == "boom"
      assert failed.last_sync_at

      {:ok, recovered} =
        failed
        |> Ash.Changeset.for_update(:record_sync_success, %{}, actor: actor())
        |> Ash.update()

      assert is_nil(recovered.last_sync_error)
    end
  end

  defp error_mentions?(error, fragment) do
    error
    |> inspect()
    |> String.downcase()
    |> String.contains?(String.downcase(fragment))
  end
end
