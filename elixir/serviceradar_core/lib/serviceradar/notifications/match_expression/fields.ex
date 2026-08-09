defmodule ServiceRadar.Notifications.MatchExpression.Fields do
  @moduledoc """
  The matchable surface of a notification route, in exactly one place (design D6).

  Three things have to agree about which field paths a route may name, and they
  live in three different modules:

  1. `ServiceRadar.Notifications.NotificationRoute` refuses to save a
     `match_expression` naming a path outside the allow-list, via
     `ServiceRadar.Notifications.Validations.MatchFieldAllowList`.
  2. `ServiceRadar.Notifications.MatchExpression.Evaluator` resolves a path
     against a routing subject at dispatch time.
  3. Any predicate builder in the UI offers the operator a list to pick from.

  A path the validator admits but the evaluator cannot resolve is the worst
  possible outcome: the route saves cleanly, matches nothing, forever, silently.
  That is the "why was I not paged?" failure design D5 exists to eliminate,
  arriving through the one door D5 does not watch. A path the evaluator can
  resolve but the validator rejects is merely an unusable feature.

  So the list is owned here and read by all three, rather than duplicated into
  each. `NotificationRoute` sets `@match_fields` from `route_fields/0` and
  `@match_field_prefixes` from `route_field_prefixes/0`; the evaluator is proven
  against `route_fields/0` by
  `test/serviceradar/notifications/match_expression/evaluator_test.exs`, which
  asserts every published path resolves against a fully populated subject.

  ## Why this module is not the grammar

  `ServiceRadar.Notifications.MatchExpression` owns the grammar - combinators,
  operators, operand types, and the *syntax* of a dotted path - and deliberately
  refuses to own the field list, because the resolvable set differs between
  routing and suppression. `NotificationSilence.matchers` carries no allow-list
  at all today: a silence may name any syntactically valid path, and the
  evaluator resolves whatever the subject actually contains. This module
  therefore publishes the *route* surface specifically, and says so in every
  function name.

  ## Namespacing

  Every route path is rooted at `alert.`, because the routing subject is the
  alert namespaced under `"alert"` (see `ServiceRadar.Notifications.Router.subject/1`).
  Adding a second root - `device.`, say - means extending the subject builder in
  the same commit, or the new paths resolve to nothing.
  """

  # The complete matchable surface of a route. Everything else is rejected at
  # save time by MatchFieldAllowList.
  @route_fields ~w(
    alert.title
    alert.description
    alert.severity
    alert.status
    alert.source_type
    alert.source_id
    alert.service_check_id
    alert.event_id
    alert.device_uid
    alert.agent_uid
    alert.metric_name
    alert.metric_value
    alert.threshold_value
    alert.comparison
    alert.escalation_level
    alert.tags
  )

  # `alerts.metadata` carries the incident keys written by
  # `AlertLifecycle.merge_incident_metadata/5`, so the whole map is matchable by
  # path without enumerating keys the notification platform does not own.
  @route_field_prefixes ["alert.metadata."]

  # The subject roots the above paths are rooted at. Kept explicit so a reviewer
  # can see at a glance that the subject builder and the allow-list agree.
  @route_namespaces ["alert"]

  @doc """
  The exact field paths a `NotificationRoute.match_expression` may name.
  """
  @spec route_fields() :: [String.t()]
  def route_fields, do: @route_fields

  @doc """
  Path prefixes under which any non-empty continuation is matchable.

  These exist for operator-owned free-form data whose leaves cannot be
  enumerated at compile time.
  """
  @spec route_field_prefixes() :: [String.t()]
  def route_field_prefixes, do: @route_field_prefixes

  @doc """
  The top-level subject keys every route path is rooted at.
  """
  @spec route_namespaces() :: [String.t()]
  def route_namespaces, do: @route_namespaces

  @doc """
  Whether `path` is matchable by a route, by exact entry or by prefix.

  This is the same decision `MatchFieldAllowList` makes at save time, exposed so
  a caller can pre-flight a predicate without building a changeset.
  """
  @spec route_field?(term()) :: boolean()
  def route_field?(path) when is_binary(path) do
    path in @route_fields or Enum.any?(@route_field_prefixes, &prefixed?(path, &1))
  end

  def route_field?(_path), do: false

  defp prefixed?(path, prefix) do
    String.starts_with?(path, prefix) and byte_size(path) > byte_size(prefix)
  end
end
