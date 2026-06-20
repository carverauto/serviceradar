defmodule ServiceRadarWebNGWeb.DeviceLive.ProcessTablePaginationTest do
  # Pure pagination/search logic — no database required.
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.DeviceLive.ProcessTablePagination, as: Pagination

  @moduletag :db_free

  defp rows(count) do
    for i <- 1..count do
      %{"name" => "proc-#{i}", "pid" => i, "status" => "running"}
    end
  end

  defp fields(row), do: [row["name"], row["pid"], row["status"]]

  describe "paginate/4 windowing" do
    test "returns the first page and reports totals" do
      result = Pagination.paginate(rows(120), "", 1, page_size: 50, fields: &fields/1)

      assert length(result.rows) == 50
      assert result.page == 1
      assert result.page_count == 3
      assert result.total == 120
      assert result.filtered_total == 120
      refute result.filtered?
      assert result.range_start == 1
      assert result.range_end == 50
    end

    test "returns a middle page window" do
      result = Pagination.paginate(rows(120), "", 2, page_size: 50, fields: &fields/1)

      assert result.page == 2
      assert result.range_start == 51
      assert result.range_end == 100
      assert hd(result.rows)["pid"] == 51
    end

    test "clamps a page beyond the last page back to the last page" do
      result = Pagination.paginate(rows(120), "", 99, page_size: 50, fields: &fields/1)

      assert result.page == 3
      assert result.range_start == 101
      assert result.range_end == 120
      assert length(result.rows) == 20
    end

    test "empty input yields a single empty page" do
      result = Pagination.paginate([], "", 1, page_size: 50, fields: &fields/1)

      assert result.rows == []
      assert result.page == 1
      assert result.page_count == 1
      assert result.total == 0
      assert result.range_start == 0
      assert result.range_end == 0
    end
  end

  describe "paginate/4 search" do
    test "case-insensitive substring filters across configured fields" do
      data = [
        %{"name" => "Postgres", "pid" => 10, "status" => "running"},
        %{"name" => "nginx", "pid" => 20, "status" => "sleeping"},
        %{"name" => "redis", "pid" => 30, "status" => "running"}
      ]

      result = Pagination.paginate(data, "POST", 1, page_size: 50, fields: &fields/1)

      assert result.filtered?
      assert result.total == 3
      assert result.filtered_total == 1
      assert [%{"name" => "Postgres"}] = result.rows
    end

    test "matches on numeric fields like pid coerced to string" do
      result = Pagination.paginate(rows(10), "7", 1, page_size: 50, fields: &fields/1)

      assert result.filtered_total == 1
      assert [%{"pid" => 7}] = result.rows
    end

    test "blank search is treated as no filter" do
      result = Pagination.paginate(rows(5), "   ", 1, page_size: 50, fields: &fields/1)

      refute result.filtered?
      assert result.filtered_total == 5
    end

    test "filtering resets pagination math to the filtered set" do
      data = for i <- 1..200, do: %{"name" => "proc-#{i}", "pid" => i, "status" => "ok"}
      # "proc-1" matches 1, 10-19, 100-199 -> 111 rows
      result = Pagination.paginate(data, "proc-1", 1, page_size: 50, fields: &fields/1)

      assert result.filtered_total == 111
      assert result.page_count == 3
    end
  end

  describe "parse_page/1" do
    test "parses positive integers and strings, defaults otherwise" do
      assert Pagination.parse_page(3) == 3
      assert Pagination.parse_page("4") == 4
      assert Pagination.parse_page("0") == 1
      assert Pagination.parse_page("-2") == 1
      assert Pagination.parse_page("abc") == 1
      assert Pagination.parse_page(nil) == 1
    end
  end

  describe "normalize_search/1" do
    test "trims and downcases, nil for blank" do
      assert Pagination.normalize_search("  HeLLo ") == "hello"
      assert Pagination.normalize_search("") == nil
      assert Pagination.normalize_search("   ") == nil
      assert Pagination.normalize_search(nil) == nil
    end
  end
end
