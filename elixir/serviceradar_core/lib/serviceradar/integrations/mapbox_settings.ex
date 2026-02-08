defmodule ServiceRadar.Integrations.MapboxSettings do
  @moduledoc """
  Deployment-level Mapbox settings (singleton).

  We store the access token encrypted at rest so admins can manage it from the UI.
  The Mapbox access token is still a "public" token client-side, but we treat it
  as a managed secret.
  """

  use Ash.Resource,
    domain: ServiceRadar.Integrations,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshCloak]

  postgres do
    table("mapbox_settings")
    repo(ServiceRadar.Repo)
    schema("platform")
    migrate?(false)
  end

  cloak do
    vault(ServiceRadar.Vault)
    attributes([:access_token])
    decrypt_by_default([:access_token])
  end

  code_interface do
    define(:get_settings, action: :get_singleton)
    define(:update_settings, action: :update)
    define(:create, action: :create)
  end

  actions do
    defaults([:read])

    read :get_singleton do
      get?(true)

      prepare(fn query, _ ->
        query
        |> Ash.Query.limit(1)
        |> Ash.Query.load([:access_token_present])
      end)
    end

    create :create do
      accept([:enabled, :style_light, :style_dark])

      argument :access_token, :string do
        sensitive?(true)
        description("Mapbox access token (stored encrypted)")
      end

      argument :clear_access_token, :boolean do
        default(false)
        description("When true, clears the stored access token")
      end

      change(fn changeset, _context ->
        changeset
        |> maybe_set_secret(:access_token)
        |> maybe_clear_secret(:clear_access_token, :encrypted_access_token)
      end)
    end

    update :update do
      require_atomic?(false)

      accept([:enabled, :style_light, :style_dark])

      argument :access_token, :string do
        sensitive?(true)
        description("Mapbox access token (stored encrypted). Leave blank to keep existing.")
      end

      argument :clear_access_token, :boolean do
        default(false)
        description("When true, clears the stored access token")
      end

      change(fn changeset, _context ->
        changeset
        |> maybe_set_secret(:access_token)
        |> maybe_clear_secret(:clear_access_token, :encrypted_access_token)
      end)
    end
  end

  policies do
    bypass always() do
      authorize_if(actor_attribute_equals(:role, :system))
    end

    policy action_type(:read) do
      authorize_if(actor_attribute_equals(:role, :admin))
      authorize_if(actor_attribute_equals(:role, :operator))
      authorize_if(actor_attribute_equals(:role, :viewer))
    end

    policy action([:create, :update]) do
      authorize_if(actor_attribute_equals(:role, :admin))
      authorize_if(actor_attribute_equals(:role, :operator))
      authorize_if(actor_attribute_equals(:role, :system))
    end
  end

  attributes do
    attribute :id, :uuid do
      primary_key?(true)
      allow_nil?(false)
      public?(true)
    end

    attribute :enabled, :boolean do
      allow_nil?(false)
      default(false)
      public?(true)
    end

    # AshCloak exposes `access_token` virtual attribute (plaintext) backed by `encrypted_access_token`.
    attribute :access_token, :string do
      public?(false)
      sensitive?(true)
    end

    attribute :style_light, :string do
      allow_nil?(false)
      default("mapbox://styles/mapbox/light-v11")
      public?(true)
    end

    attribute :style_dark, :string do
      allow_nil?(false)
      default("mapbox://styles/mapbox/dark-v11")
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  calculations do
    calculate(:access_token_present, :boolean, fn records, _opts ->
      Enum.map(records, fn record ->
        case Map.get(record, :encrypted_access_token) do
          value when is_binary(value) -> byte_size(value) > 0
          _ -> false
        end
      end)
    end)
  end

  defp maybe_set_secret(changeset, arg) do
    case Ash.Changeset.get_argument(changeset, arg) do
      value when is_binary(value) ->
        value = String.trim(value)

        if value != "" do
          AshCloak.encrypt_and_set(changeset, arg, value)
        else
          changeset
        end

      _ ->
        changeset
    end
  end

  defp maybe_clear_secret(changeset, clear_arg, encrypted_attr) do
    if Ash.Changeset.get_argument(changeset, clear_arg) do
      Ash.Changeset.force_change_attribute(changeset, encrypted_attr, nil)
    else
      changeset
    end
  end
end
