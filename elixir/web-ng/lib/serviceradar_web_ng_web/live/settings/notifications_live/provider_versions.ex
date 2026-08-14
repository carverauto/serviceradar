defmodule ServiceRadarWebNGWeb.Settings.NotificationsLive.ProviderVersions do
  @moduledoc """
  The definition history of a declarative provider, reconstructed from its
  AshPaperTrail version rows (task 2.3.2).

  ## Why there is no new column

  `NotificationProvider` is already audited by `AshPaperTrail`, and
  `NotificationDelivery.provider_version` already records the definition version
  that rendered each delivery. Between them the platform can already answer both
  questions this surface asks - "what did version 2 say?" and "which version
  rendered this delivery?" - so a `notification_provider_definitions` table would
  be a second copy of an audit trail that already exists, kept in step by hand.

  The version table stores `changes` only (`change_tracking_mode :changes_only`),
  so a version row lists just the attributes that update touched.
  `history/2` therefore folds the rows in chronological order, carrying the last
  seen `definition` and `definition_version` forward, and emits one entry per
  definition version. Rows that changed neither - an `activate`, a rename - are
  correctly invisible here: they are not new versions of the document.

  ## Rollback is a new version, never a rewrite

  `NotificationDelivery` rows point at the version that rendered them, so history
  is append-only: rolling back to version 1 writes the version-1 document as
  version 3. The delivery log continues to identify exactly which document
  produced which notification, which is what the spec's "superseded version
  remains auditable" scenario requires, and an operator can roll back a rollback.

  ## Purity

  Pure. It takes rows and returns entries; the read itself belongs to
  `ServiceRadarWebNGWeb.Settings.NotificationsLive.Data`. Its tests run
  `async: true`, and no atom is ever created from a stored value.
  """

  @type entry :: %{
          number: pos_integer(),
          definition: map(),
          recorded_at: DateTime.t() | nil,
          action: String.t(),
          current?: boolean()
        }

  @doc """
  The definition history for a provider, newest first.

  `rows` are `NotificationProvider.Version` records in any order;
  `current_version` is the provider row's `definition_version`, which marks the
  entry a channel renders at today.
  """
  @spec history([map()], term()) :: [entry()]
  def history(rows, current_version \\ nil) when is_list(rows) do
    rows
    |> Enum.sort_by(&sort_key/1)
    |> Enum.reduce({[], %{definition: nil, number: nil}}, &fold_row/2)
    |> elem(0)
    |> Enum.map(&Map.put(&1, :current?, &1.number == current_version))
  end

  @doc "The entry for one version number, or nil."
  @spec find([entry()], term()) :: entry() | nil
  def find(entries, number) when is_list(entries) do
    Enum.find(entries, &(&1.number == number))
  end

  @doc "The versions that are not the current one, newest first."
  @spec supersedable([entry()]) :: [entry()]
  def supersedable(entries) when is_list(entries) do
    Enum.reject(entries, & &1.current?)
  end

  defp fold_row(row, {entries, state}) do
    changes = normalize(Map.get(row, :changes))
    definition = Map.get(changes, "definition") || state.definition
    number = Map.get(changes, "definition_version") || state.number

    if definition_change?(changes) and is_map(definition) and is_integer(number) do
      entry = %{
        number: number,
        definition: definition,
        recorded_at: Map.get(row, :version_inserted_at),
        action: action(row)
      }

      {[entry | entries], %{definition: definition, number: number}}
    else
      {entries, %{definition: definition, number: number}}
    end
  end

  # A version row is a new *definition* version only when it touched the document
  # or its version number. An `activate` writes a version row too, and listing it
  # as a definition version would offer a rollback that changes nothing.
  defp definition_change?(changes) do
    Map.has_key?(changes, "definition") or Map.has_key?(changes, "definition_version")
  end

  # `changes` is written from Elixir with atom keys and read back from `jsonb`
  # with string keys. Both are accepted by comparing names, never by creating an
  # atom from a stored key.
  defp normalize(changes) when is_map(changes) and not is_struct(changes) do
    Map.new(changes, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize(_changes), do: %{}

  defp action(row) do
    case Map.get(row, :version_action_name) do
      nil -> to_string(Map.get(row, :version_action_type) || "update")
      name -> to_string(name)
    end
  end

  # Chronological, with the row id as the tiebreak so two versions written in the
  # same microsecond still fold in a stable order. The timestamp is reduced to an
  # integer first: comparing `DateTime` structs directly compares their fields in
  # alphabetical key order, which puts `day` before `month` and is not
  # chronological at all.
  defp sort_key(row) do
    {timestamp(Map.get(row, :version_inserted_at)), to_string(Map.get(row, :id) || "")}
  end

  defp timestamp(%DateTime{} = at), do: DateTime.to_unix(at, :microsecond)

  defp timestamp(%NaiveDateTime{} = at) do
    at |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:microsecond)
  end

  defp timestamp(_at), do: 0
end
