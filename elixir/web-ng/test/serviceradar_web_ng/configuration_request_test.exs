defmodule ServiceRadarWebNG.ConfigurationRequestTest do
  use ExUnit.Case, async: true

  import Phoenix.ConnTest, only: [build_conn: 0]
  import Plug.Conn

  alias Ash.Error.Invalid
  alias ServiceRadar.Automation.Ansible.PlaybookRepository
  alias ServiceRadarWebNG.ConfigurationRequest

  @moduletag :db_free

  test "resource ETag preserves microseconds for conditional mutations" do
    timestamp = ~U[2026-01-02 03:04:05.000006Z]
    record = %PlaybookRepository{updated_at: timestamp}
    response = ConfigurationRequest.put_etag(build_conn(), record)
    [etag] = get_resp_header(response, "etag")
    request = put_req_header(build_conn(), "if-match", etag)

    assert {:ok, opts} = ConfigurationRequest.mutation_opts(request)
    assert opts[:expected_updated_at] == timestamp

    assert :ok = ConfigurationRequest.assert_current(record, opts)
    changed = %{record | updated_at: DateTime.add(timestamp, 1, :microsecond)}
    assert {:error, :conflict} = ConfigurationRequest.assert_current(changed, opts)
  end

  test "new endpoints require a version and existing endpoints can opt into compatibility" do
    assert {:error, :precondition_required} = ConfigurationRequest.mutation_opts(build_conn())
    assert {:ok, []} = ConfigurationRequest.mutation_opts(build_conn(), required: false)
  end

  test "wildcards, weak tags, lists, and malformed timestamps cannot bypass the version check" do
    for etag <- ["*", "W/\"2026-01-02T03:04:05Z\"", ~s("a", "b"), "\"\"", "\"invalid\"", "2026-01-02"] do
      request = put_req_header(build_conn(), "if-match", etag)
      assert {:error, :invalid_precondition} = ConfigurationRequest.mutation_opts(request)
    end
  end

  test "stale Ash mutations become conflicts without exposing internal details" do
    error = %Ash.Error.Changes.StaleRecord{resource: PlaybookRepository}
    assert {:error, :conflict} = ConfigurationRequest.normalize_result({:error, error})

    assert {:error, :conflict} =
             ConfigurationRequest.normalize_result({:error, %{errors: [%{errors: [error]}]}})

    assert {:error, :conflict} =
             ConfigurationRequest.normalize_result({:error, %Ash.Changeset{errors: [error]}})

    assert {:error, :not_found} = ConfigurationRequest.normalize_result({:error, :not_found})
  end

  test "single-record lookups normalize missing records and preserve other errors" do
    missing = %Ash.Error.Query.NotFound{resource: PlaybookRepository}
    wrapped = %Invalid{errors: [missing]}

    for result <- [{:ok, nil}, {:error, missing}, {:error, wrapped}] do
      assert {:error, :not_found} = ConfigurationRequest.require_record(result)
    end

    invalid = %Ash.Error.Changes.InvalidAttribute{field: :id, message: "is invalid"}
    mixed = %Invalid{errors: [missing, invalid]}
    forbidden = %Ash.Error.Forbidden{}
    record = %PlaybookRepository{id: "00000000-0000-4000-8000-000000000901"}

    for result <- [{:error, mixed}, {:error, forbidden}, {:error, invalid}, {:ok, record}] do
      assert ConfigurationRequest.require_record(result) == result
    end
  end
end
