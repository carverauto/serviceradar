defmodule Mix.Tasks.Serviceradar.Edge.DirectLeaf do
  @shortdoc "Issue, revoke, or activate an add-on direct-leaf identity"

  @moduledoc """
  Manages the explicit, add-on-scoped direct-leaf mTLS lifecycle.

  Issuing an identity stores its encrypted PEM material as `pending`. It does
  not make the identity usable until the edge-site leaf bundle has been
  regenerated, installed, and reloaded, followed by an explicit `mark-ready`
  for the same generation.

  ## Usage

      mix serviceradar.edge.direct_leaf issue --assignment-id <uuid>
      mix serviceradar.edge.direct_leaf revoke --assignment-id <uuid> --reason "removed"
      mix serviceradar.edge.direct_leaf mark-ready --assignment-id <uuid> --generation 2
  """

  use Mix.Task

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.DirectLeafAccessProvisioner

  @switches [
    assignment_id: :string,
    generation: :integer,
    validity_days: :integer,
    reason: :string
  ]

  @default_reason "direct leaf access revoked"

  @impl Mix.Task
  def run([action | args]) when action in ["issue", "revoke", "mark-ready"] do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)

    if rest != [] or invalid != [] do
      Mix.raise("Invalid arguments. See `mix help serviceradar.edge.direct_leaf`.")
    end

    assignment_id = required_option(opts, :assignment_id)
    Mix.Task.run("app.start")
    actor = SystemActor.system(:direct_leaf_access_cli)

    result =
      case action do
        "issue" ->
          DirectLeafAccessProvisioner.issue(assignment_id,
            validity_days: Keyword.get(opts, :validity_days, 30),
            actor: actor
          )

        "revoke" ->
          DirectLeafAccessProvisioner.revoke(assignment_id,
            reason: Keyword.get(opts, :reason, @default_reason),
            actor: actor
          )

        "mark-ready" ->
          generation = required_option(opts, :generation)
          DirectLeafAccessProvisioner.mark_ready(assignment_id, generation, actor: actor)
      end

    case result do
      {:ok, assignment} -> print_result(action, assignment)
      {:error, reason} -> Mix.raise("Direct-leaf #{action} failed: #{inspect(reason)}")
    end
  end

  def run(_args) do
    Mix.raise(
      "Expected issue, revoke, or mark-ready. See `mix help serviceradar.edge.direct_leaf`."
    )
  end

  defp required_option(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> value
      value when is_integer(value) -> value
      _ -> Mix.raise("Missing required --#{key_to_string(key)} option.")
    end
  end

  defp key_to_string(key), do: key |> Atom.to_string() |> String.replace("_", "-")

  defp print_result(action, assignment) do
    Mix.shell().info("direct-leaf action=#{action}")
    Mix.shell().info("assignment_id=#{assignment.id}")
    Mix.shell().info("status=#{assignment.direct_access_status}")
    Mix.shell().info("generation=#{assignment.direct_access_generation}")
    Mix.shell().info("component_id=#{assignment.direct_identity_component_id || "-"}")
    Mix.shell().info("partition_id=#{assignment.direct_identity_partition_id || "-"}")
    Mix.shell().info("expires_at=#{format_datetime(assignment.direct_access_expires_at)}")
    Mix.shell().info("error=#{assignment.direct_access_error || "-"}")
  end

  defp format_datetime(nil), do: "-"
  defp format_datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp format_datetime(value), do: inspect(value)
end
