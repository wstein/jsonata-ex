defmodule Jsonata.DateTimePictureTest do
  use ExUnit.Case, async: true

  # 2018-01-01T12:00:00.000Z
  @ts 1_514_808_000_000

  defp fmt(picture, ts \\ @ts) do
    {:ok, result} = Jsonata.evaluate("$fromMillis(#{ts}, #{inspect(picture)})")
    result
  end

  defp fmt(picture, ts, timezone) do
    {:ok, result} =
      Jsonata.evaluate("$fromMillis(#{ts}, #{inspect(picture)}, #{inspect(timezone)})")

    result
  end

  describe "$fromMillis picture strings" do
    test "numeric date components, with and without padding" do
      assert fmt("[Y0001]-[M01]-[D01]") == "2018-01-01"
      assert fmt("[D]/[M]/[Y]") == "1/1/2018"
      assert fmt("[Y]") == "2018"
    end

    test "named months and days" do
      assert fmt("[D01] [MNn] [Y]") == "01 January 2018"
      assert fmt("[FNn], [D] [MNn] [Y]") == "Monday, 1 January 2018"
      assert fmt("[MN]") == "JANUARY"
      assert fmt("[Mn,*-3]") == "jan"
    end

    test "ordinal day" do
      assert fmt("[D1o] of [MNn]") == "1st of January"
    end

    test "time components and am/pm" do
      assert fmt("[H01]:[m01]:[s01]") == "12:00:00"
      assert fmt("[h]:[m01] [Pn]") == "12:00 pm"
    end

    test "day of year and week of year" do
      assert fmt("[Y]-[d]") == "2018-1"
      assert fmt("[Y]-W[W01]") == "2018-W01"
    end

    test "full ISO 8601 default and explicit picture agree" do
      iso = "[Y0001]-[M01]-[D01]T[H01]:[m01]:[s01].[f001][Z01:01t]"
      assert fmt(iso) == "2018-01-01T12:00:00.000Z"
    end

    test "timezone offset shifts the time and renders the offset" do
      # 2018-07-11T12:00:00Z shifted to -05:00
      ts = 1_531_310_400_000
      assert fmt("[Y]-[M01]-[D01]T[H01]:[m]:[s][Z]", ts, "-0500") == "2018-07-11T07:00:00-05:00"
      assert fmt("[H01]:[m01][Z]", ts, "+0530") == "17:30+05:30"
    end
  end

  describe "$toMillis picture parsing" do
    defp parse(string, picture) do
      {:ok, result} = Jsonata.evaluate("$toMillis(#{inspect(string)}, #{inspect(picture)})")
      result
    end

    test "fixed-width fields with no separators" do
      assert parse("201802", "[Y0001][M01]") == 1_517_443_200_000
      assert parse("20180205", "[Y0001][M01][D01]") == 1_517_788_800_000
    end

    test "round-trips $fromMillis" do
      assert parse("2018-02-05", "[Y0001]-[M01]-[D01]") == 1_517_788_800_000
      assert parse("20240101123849", "[Y0001][M01][D01][H01][m01][s01]") == 1_704_112_729_000
    end

    test "named months and ordinal days" do
      assert parse("21 August 2017", "[D1] [MNn] [Y0001]") == 1_503_273_600_000
      assert parse("21st August 2017", "[D1o] [MNn] [Y0001]") == 1_503_273_600_000
    end

    test "spelled-out words" do
      assert parse("twenty-first August two thousand and seventeen", "[Dwo] [MNn] [Yw]") ==
               1_503_273_600_000
    end

    test "ISO partial forms (no picture)" do
      assert {:ok, 1_509_321_600_000} = Jsonata.evaluate(~s|$toMillis("2017-10-30")|)
      assert {:ok, 1_514_764_800_000} = Jsonata.evaluate(~s|$toMillis("2018")|)
    end

    test "a non-matching string yields undefined" do
      assert {:ok, :undefined} = Jsonata.evaluate(~s|$toMillis("nope", "[Y0001]")|)
    end
  end
end
