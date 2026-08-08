defmodule Mix.Tasks.Serviceradar.Edge.NatsLegacy do
  @shortdoc "Report or remove legacy NATS material from edge packages"

  @moduledoc """
  Reports onboarding packages that still contain the pre-direct-leaf NATS
  credential fields and optionally removes that material.

  The default is a read-only report. `--apply` is required to clear the
  encrypted `.creds` payload and its credential reference. Credential records
  are revoked after the package payload has been removed; if revocation fails,
  the package remains safe because it no longer contains material that can be
  delivered to an agent, and the failure is included in the report.

  ## Usage

      mix serviceradar.edge.nats_legacy
      mix serviceradar.edge.nats_legacy --package-id <uuid>
      mix serviceradar.edge.nats_legacy --apply --reason "direct leaf migration"
      mix serviceradar.edge.nats_legacy --json
  """

  use Mix.Task

  import Ash.Expr

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.NatsCredential
  alias ServiceRadar.Edge.OnboardingPackage

  require Ash.Query

  @switches [
    apply: :boolean,
    json: :boolean,
    package_id: :string,
    reason: :string
  ]

  @default_reason "legacy_nats_credentials_removed"

  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)

    if rest != [] or invalid != [] do
      Mix.raise(
        "Invalid arguments: #{inspect(rest ++ Enum.map(invalid, &elem(&1, 0)))}. " <>
          "See `mix help serviceradar.edge.nats_legacy`."
      )
    end

    Mix.Task.run("app.start")

    actor = SystemActor.system(:edge_nats_legacy_migration)
    packages = load_packages(opts[:package_id], actor)
    apply? = Keyword.get(opts, :apply, false)
    reason = Keyword.get(opts, :reason, @default_reason)

    rows =
      Enum.map(packages, fn package ->
        row = package_row(package)

        if apply? do
          Map.merge(row, apply_cleanup(package, actor, reason))
        else
          Map.put(row, "action", "report_only")
        end
      end)

    report = %{
      "mode" => if(apply?, do: "apply", else: "report"),
      "reason" => reason,
      "count" => length(rows),
      "packages" => rows
    }

    if Keyword.get(opts, :json, false) do
      Mix.shell().info(Jason.encode!(report, pretty: true))
    else
      print_report(report)
    end
  end

  defp load_packages(nil, actor) do
    OnboardingPackage
    |> Ash.Query.for_read(:with_legacy_nats, %{}, actor: actor)
    |> Ash.Query.sort(created_at: :asc)
    |> Ash.read!(actor: actor)
  end

  defp load_packages(package_id, actor) do
    query =
      OnboardingPackage
      |> Ash.Query.for_read(:with_legacy_nats, %{}, actor: actor)
      |> Ash.Query.filter(expr(id == ^package_id))

    case Ash.read(query, actor: actor) do
      {:ok, [package]} ->
        [package]

      {:ok, []} ->
        Mix.raise("No package with legacy NATS material found: #{package_id}")

      {:ok, packages} ->
        packages

      {:error, error} ->
        Mix.raise("Unable to read onboarding package: #{Exception.message(error)}")
    end
  end

  defp package_row(package) do
    %{
      "package_id" => package.id,
      "label" => package.label,
      "component_id" => package.component_id,
      "component_type" => Atom.to_string(package.component_type),
      "package_status" => Atom.to_string(package.status),
      "credential_id" => package.nats_credential_id,
      "has_encrypted_credentials" => not is_nil(package.nats_creds_ciphertext),
      "cleanup_at" => format_datetime(package.legacy_nats_cleanup_at)
    }
  end

  defp apply_cleanup(package, actor, reason) do
    credential_id = package.nats_credential_id

    case package
         |> Ash.Changeset.for_update(:clear_legacy_nats, %{reason: reason}, actor: actor)
         |> Ash.update(actor: actor) do
      {:ok, _cleaned_package} ->
        %{
          "action" => "cleaned",
          "credential_revoke" => revoke_credential(credential_id, actor, reason)
        }

      {:error, error} ->
        %{
          "action" => "cleanup_failed",
          "error" => Exception.message(error)
        }
    end
  end

  defp revoke_credential(nil, _actor, _reason), do: "not_present"

  defp revoke_credential(credential_id, actor, reason) do
    case Ash.get(NatsCredential, credential_id, actor: actor) do
      {:ok, %{status: :active} = credential} ->
        case credential
             |> Ash.Changeset.for_update(:revoke, %{reason: reason}, actor: actor)
             |> Ash.update(actor: actor) do
          {:ok, _credential} -> "revoked"
          {:error, error} -> "revoke_failed: #{Exception.message(error)}"
        end

      {:ok, %{status: status}} ->
        "already_#{status}"

      {:error, error} ->
        "lookup_failed: #{Exception.message(error)}"
    end
  end

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp print_report(%{"mode" => mode, "count" => count, "packages" => packages}) do
    shell = Mix.shell()
    shell.info("Legacy edge NATS package report")
    shell.info("mode: #{mode}")
    shell.info("packages: #{count}")

    Enum.each(packages, fn package ->
      suffix =
        case package["credential_revoke"] do
          nil -> ""
          result -> " credential_revoke=#{result}"
        end

      shell.info(
        "  #{package["package_id"]} component=#{package["component_id"] || "-"} " <>
          "status=#{package["package_status"]} " <>
          "encrypted=#{package["has_encrypted_credentials"]} " <>
          "action=#{package["action"]}#{suffix}"
      )
    end)
  end
end
