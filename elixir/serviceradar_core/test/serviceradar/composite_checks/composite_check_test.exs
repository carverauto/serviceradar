defmodule ServiceRadar.CompositeChecks.CompositeCheckTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.CompositeChecks.CompositeCheck

  defp actor, do: SystemActor.system(:composite_check_test)

  defp create(attrs) do
    CompositeCheck
    |> Ash.Changeset.for_create(:create, attrs, actor: actor())
    |> Ash.create()
  end

  describe "create" do
    test "derives a slug from the name and starts in draft" do
      assert {:ok, check} =
               create(%{
                 name: "PCI Isolation — Managed",
                 scope_query: "in:devices source:armis tag:managed"
               })

      assert check.slug == "pci-isolation-managed"
      assert check.state == :draft
      assert check.evaluation_interval_seconds == 300
    end

    test "rejects a scope that does not target devices" do
      assert {:error, error} =
               create(%{name: "Bad Scope", scope_query: "in:flows src_ip:10.0.0.1"})

      assert Exception.message(error) =~ "must target devices"
    end

    test "rejects a duplicate slug" do
      assert {:ok, _} = create(%{name: "Dupe Check", scope_query: "in:devices"})
      assert {:error, error} = create(%{name: "Dupe Check", scope_query: "in:devices"})
      assert Exception.message(error) =~ "already been taken"
    end
  end

  describe "update" do
    test "renaming does not change the slug" do
      {:ok, check} = create(%{name: "Original Name", scope_query: "in:devices"})

      assert {:ok, renamed} =
               check
               |> Ash.Changeset.for_update(:update, %{name: "Different Name"}, actor: actor())
               |> Ash.update()

      assert renamed.slug == "original-name"
      assert renamed.name == "Different Name"
    end

    # Guards a real hole: a validation whose `atomic/3` returns a bare `:ok` is
    # skipped when the action runs atomically, so scope validation would apply
    # on create but silently not on update.
    test "rejects a non-device scope on update, not just on create" do
      {:ok, check} = create(%{name: "Scope Update", scope_query: "in:devices"})

      assert {:error, error} =
               check
               |> Ash.Changeset.for_update(:update, %{scope_query: "in:flows src_ip:10.0.0.1"},
                 actor: actor()
               )
               |> Ash.update()

      assert Exception.message(error) =~ "must target devices"
    end
  end

  describe "authorization" do
    test "a viewer cannot create a composite check" do
      viewer = %{id: Ash.UUID.generate(), role: :viewer}

      assert {:error, %Ash.Error.Forbidden{}} =
               CompositeCheck
               |> Ash.Changeset.for_create(
                 :create,
                 %{name: "Viewer Attempt", scope_query: "in:devices"},
                 actor: viewer
               )
               |> Ash.create()
    end
  end
end
