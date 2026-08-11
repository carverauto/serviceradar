defmodule ServiceRadarWebNG.NotificationsFixtures do
  @moduledoc """
  Rows for the notification settings surface, created with the system actor.

  Every fixture writes through the real Ash action rather than inserting a row,
  so a fixture that stops being valid - a new required attribute, a new
  validation - fails here instead of producing a record the LiveView can never
  have produced.

  The provider catalog is seeded with `ServiceRadar.Notifications.ProviderSeeder`
  rather than hand-built, because a hand-built provider carries a `config_schema`
  that nothing else validates, and a channel is then accepted against a schema
  the shipped catalog does not have.
  """

  alias ServiceRadar.Notifications.NotificationChannel
  alias ServiceRadar.Notifications.NotificationEscalationPolicy
  alias ServiceRadar.Notifications.NotificationProvider
  alias ServiceRadar.Notifications.NotificationRoute
  alias ServiceRadar.Notifications.NotificationSilence
  alias ServiceRadar.Notifications.ProviderSeeder
  alias ServiceRadarWebNG.AshTestHelpers

  require Ash.Query

  @doc "Seeds the first-party provider catalog. Idempotent."
  def seed_providers do
    :ok = ProviderSeeder.seed_providers()
    :ok
  end

  @doc "Seeds the catalog if needed and returns the provider with `provider_key`."
  def provider_fixture(provider_key \\ "webhook") do
    seed_providers()

    NotificationProvider
    |> Ash.Query.for_read(:by_provider_key, %{provider_key: provider_key})
    |> Ash.read_one!(actor: actor())
  end

  @doc """
  A control-plane webhook channel.

  `https://hooks.example.com/...` is deliberately a public host: the outbound URL
  policy refuses private and loopback addresses, so a fixture pointed at
  `localhost` would be rejected the moment anything tried to deliver through it.
  """
  def channel_fixture(attrs \\ %{}) do
    unique = System.unique_integer([:positive])
    provider = Map.get(attrs, :provider) || provider_fixture()

    defaults = %{
      name: "Channel #{unique}",
      provider_id: provider.id,
      execution_route: :control_plane,
      config: %{"url" => "https://hooks.example.com/notify/#{unique}"}
    }

    attrs =
      defaults
      |> Map.merge(Map.new(attrs))
      |> Map.delete(:provider)

    NotificationChannel
    |> Ash.Changeset.for_create(:create, attrs, actor: actor())
    |> Ash.create!()
  end

  @doc "An escalation policy with no steps, which is all a route needs to bind."
  def escalation_policy_fixture(attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    attrs = Map.merge(%{name: "Policy #{unique}", repeat_count: 0}, Map.new(attrs))

    NotificationEscalationPolicy
    |> Ash.Changeset.for_create(:create, attrs, actor: actor())
    |> Ash.create!()
  end

  @doc "A route bound to an escalation policy, matching one alert severity."
  def route_fixture(attrs \\ %{}) do
    unique = System.unique_integer([:positive])
    attrs = Map.new(attrs)

    policy_id =
      Map.get(attrs, :escalation_policy_id) || escalation_policy_fixture().id

    defaults = %{
      name: "Route #{unique}",
      priority: 100,
      escalation_policy_id: policy_id,
      match_expression: %{"all" => [%{"field" => "alert.severity", "equals" => "critical"}]}
    }

    NotificationRoute
    |> Ash.Changeset.for_create(:create, Map.merge(defaults, attrs), actor: actor())
    |> Ash.create!()
  end

  @doc "A scheduled silence whose window is open for the next hour."
  def silence_fixture(attrs \\ %{}) do
    unique = System.unique_integer([:positive])
    now = DateTime.utc_now()

    defaults = %{
      name: "Silence #{unique}",
      comment: "Maintenance window #{unique}",
      matchers: %{"all" => [%{"field" => "alert.severity", "equals" => "warning"}]},
      starts_at: now,
      ends_at: DateTime.add(now, 3600, :second),
      created_by: "fixture"
    }

    NotificationSilence
    |> Ash.Changeset.for_create(:create, Map.merge(defaults, Map.new(attrs)), actor: actor())
    |> Ash.create!()
  end

  @doc "Reads a resource back with the system actor, bypassing the viewer's scope."
  def read_all(resource) do
    resource
    |> Ash.Query.for_read(:read)
    |> Ash.read!(actor: actor())
  end

  defp actor, do: AshTestHelpers.system_actor()
end
