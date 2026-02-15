defmodule ServiceRadar.Software.SoftwareImageTest do
  @moduledoc """
  Integration tests for SoftwareImage Ash resource and state machine transitions.

  Requires a database. Run with: mix test --include integration
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Software.SoftwareImage
  alias ServiceRadar.TestSupport

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = SystemActor.system(:software_image_test)
    {:ok, actor: actor}
  end

  defp create_image(actor, attrs \\ %{}) do
    default = %{
      name: "test-firmware-#{System.unique_integer([:positive])}",
      version: "1.0.0",
      device_type: "switch",
      filename: "firmware.bin",
      content_hash: "abc123def456",
      file_size: 1024,
      object_key: "images/firmware.bin"
    }

    SoftwareImage
    |> Ash.Changeset.for_create(:create, Map.merge(default, attrs), actor: actor)
    |> Ash.create!()
  end

  describe "create" do
    test "creates an image in :uploaded status", %{actor: actor} do
      image = create_image(actor)

      assert image.status == :uploaded
      assert image.name =~ "test-firmware"
      assert image.version == "1.0.0"
    end
  end

  describe "state transitions" do
    test "uploaded -> verified", %{actor: actor} do
      image = create_image(actor)
      assert image.status == :uploaded

      updated =
        image
        |> Ash.Changeset.for_update(:verify, %{}, actor: actor)
        |> Ash.update!()

      assert updated.status == :verified
    end

    test "verified -> active", %{actor: actor} do
      image = create_image(actor)

      image =
        image
        |> Ash.Changeset.for_update(:verify, %{}, actor: actor)
        |> Ash.update!()

      updated =
        image
        |> Ash.Changeset.for_update(:activate, %{}, actor: actor)
        |> Ash.update!()

      assert updated.status == :active
    end

    test "active -> archived", %{actor: actor} do
      image = create_image(actor)

      image =
        image
        |> Ash.Changeset.for_update(:verify, %{}, actor: actor)
        |> Ash.update!()
        |> Ash.Changeset.for_update(:activate, %{}, actor: actor)
        |> Ash.update!()

      updated =
        image
        |> Ash.Changeset.for_update(:archive, %{}, actor: actor)
        |> Ash.update!()

      assert updated.status == :archived
    end

    test "archived -> deleted", %{actor: actor} do
      image = create_image(actor)

      image =
        image
        |> Ash.Changeset.for_update(:verify, %{}, actor: actor)
        |> Ash.update!()
        |> Ash.Changeset.for_update(:activate, %{}, actor: actor)
        |> Ash.update!()
        |> Ash.Changeset.for_update(:archive, %{}, actor: actor)
        |> Ash.update!()

      updated =
        image
        |> Ash.Changeset.for_update(:soft_delete, %{}, actor: actor)
        |> Ash.update!()

      assert updated.status == :deleted
    end

    test "cannot skip states (uploaded -> active fails)", %{actor: actor} do
      image = create_image(actor)

      assert_raise Ash.Error.Invalid, fn ->
        image
        |> Ash.Changeset.for_update(:activate, %{}, actor: actor)
        |> Ash.update!()
      end
    end

    test "full lifecycle: uploaded -> verified -> active -> archived -> deleted", %{actor: actor} do
      image = create_image(actor)
      assert image.status == :uploaded

      image =
        image
        |> Ash.Changeset.for_update(:verify, %{}, actor: actor)
        |> Ash.update!()

      assert image.status == :verified

      image =
        image
        |> Ash.Changeset.for_update(:activate, %{}, actor: actor)
        |> Ash.update!()

      assert image.status == :active

      image =
        image
        |> Ash.Changeset.for_update(:archive, %{}, actor: actor)
        |> Ash.update!()

      assert image.status == :archived

      image =
        image
        |> Ash.Changeset.for_update(:soft_delete, %{}, actor: actor)
        |> Ash.update!()

      assert image.status == :deleted
    end
  end

  describe "queries" do
    test "list returns all images", %{actor: actor} do
      _img1 = create_image(actor, %{name: "fw-list-a", version: "1.0"})
      _img2 = create_image(actor, %{name: "fw-list-b", version: "2.0"})

      {:ok, result} =
        SoftwareImage
        |> Ash.Query.for_read(:list, %{}, actor: actor)
        |> Ash.read()

      names = Enum.map(result, & &1.name)
      assert "fw-list-a" in names
      assert "fw-list-b" in names
    end

    test "active filter returns only active images", %{actor: actor} do
      img = create_image(actor, %{name: "fw-active-test"})

      img
      |> Ash.Changeset.for_update(:verify, %{}, actor: actor)
      |> Ash.update!()
      |> Ash.Changeset.for_update(:activate, %{}, actor: actor)
      |> Ash.update!()

      {:ok, result} =
        SoftwareImage
        |> Ash.Query.for_read(:active, %{}, actor: actor)
        |> Ash.read()

      names = Enum.map(result, & &1.name)
      assert "fw-active-test" in names
    end
  end
end
