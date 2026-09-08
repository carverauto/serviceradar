defmodule ServiceRadar.Notifications.NotificationCallbackAppTest do
  @moduledoc """
  The callback app registry against real rows (task 4.3.1a).

  What only a database can answer: that the migration applies, that the identity
  really is unique so one app cannot be registered twice with two secrets, that
  the provider-key constraint refuses a value nothing can resolve, and that the
  ciphertext round-trips through jsonb-free text columns intact.
  """

  use ServiceRadar.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.Crypto
  alias ServiceRadar.Notifications.Callbacks.AppRegistry
  alias ServiceRadar.Notifications.NotificationCallbackApp
  alias ServiceRadar.TestSupport

  @moduletag :integration

  @app_id "A0123456789"

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    original = Application.get_env(:serviceradar_core, :crypto_secret)
    Application.put_env(:serviceradar_core, :crypto_secret, String.duplicate("a", 32))

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:serviceradar_core, :crypto_secret)
        value -> Application.put_env(:serviceradar_core, :crypto_secret, value)
      end
    end)

    {:ok, actor: SystemActor.system(:notification_callback_app_test)}
  end

  defp register!(actor, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          provider_key: :slack,
          external_app_id: @app_id,
          label: "ServiceRadar Alerts",
          signing_secret_ciphertext: Crypto.encrypt("slack-signing-secret-for-tests-only")
        },
        overrides
      )

    NotificationCallbackApp
    |> Ash.Changeset.for_create(:register, attrs, actor: actor)
    |> Ash.create!(actor: actor)
  end

  test "a registered app resolves to its decrypted secret end to end", %{actor: actor} do
    register!(actor)

    assert {:ok, "slack-signing-secret-for-tests-only"} =
             AppRegistry.signing_secret(:slack, @app_id, actor: actor)
  end

  test "an unregistered app id resolves to :app_not_registered", %{actor: actor} do
    register!(actor)

    assert {:error, :app_not_registered} =
             AppRegistry.signing_secret(:slack, "A9999999999", actor: actor)
  end

  test "one app cannot be registered twice", %{actor: actor} do
    register!(actor)

    # Two rows for one app id would make verification depend on row order, and
    # a rotation could leave the stale secret winning.
    assert {:error, _error} =
             NotificationCallbackApp
             |> Ash.Changeset.for_create(
               :register,
               %{
                 provider_key: :slack,
                 external_app_id: @app_id,
                 signing_secret_ciphertext: Crypto.encrypt("a-second-secret")
               },
               actor: actor
             )
             |> Ash.create(actor: actor)
  end

  test "rotating replaces the secret without changing identity", %{actor: actor} do
    app = register!(actor)

    rotated =
      app
      |> Ash.Changeset.for_update(
        :rotate_secret,
        %{signing_secret_ciphertext: Crypto.encrypt("rotated-secret")},
        actor: actor
      )
      |> Ash.update!(actor: actor)

    assert rotated.id == app.id
    assert rotated.external_app_id == @app_id
    assert {:ok, "rotated-secret"} = AppRegistry.signing_secret(:slack, @app_id, actor: actor)
  end

  test "the database refuses a provider key nothing can resolve", %{actor: actor} do
    # Belt and braces with the resource's one_of constraint: a row written by a
    # typo would sit unnoticed in a credential table.
    assert_raise Postgrex.Error, fn ->
      SQL.query!(
        ServiceRadar.Repo,
        """
        INSERT INTO platform.notification_callback_apps
          (provider_key, external_app_id, signing_secret_ciphertext)
        VALUES ('telegram', 'A1', 'x')
        """,
        []
      )
    end

    _unused = actor
  end

  test "an empty ciphertext is refused at the database", %{actor: _actor} do
    assert_raise Postgrex.Error, fn ->
      SQL.query!(
        ServiceRadar.Repo,
        """
        INSERT INTO platform.notification_callback_apps
          (provider_key, external_app_id, signing_secret_ciphertext)
        VALUES ('slack', 'A2', '   ')
        """,
        []
      )
    end
  end
end
