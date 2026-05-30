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

  describe "escaped bracket [[" do
    test "double [[ in picture produces a literal [" do
      assert fmt("pre[[post") == "pre[post"
      assert fmt("[[ [Y0001] ]]") == "[ 2018 ]"
    end
  end

  describe "calendar component [C] and [E]" do
    test "[C] returns the string ISO" do
      assert fmt("[C]") == "ISO"
    end
  end

  describe "2-digit year [Y,*-2]" do
    test "max width of 2 truncates year to last 2 digits" do
      assert fmt("[Y,*-2]") == "18"
      assert fmt("[Y,2-2]") == "18"
    end

    test "max width of 4 gives full 4-digit year" do
      assert fmt("[Y,*-4]") == "2018"
    end
  end

  describe "12-hour clock edge cases" do
    # midnight = 0 mod 12 -> displays as 12am
    test "midnight is 12 am" do
      assert fmt("[h] [Pn]", 0) == "12 am"
    end

    # 1am = hour 1 mod 12 -> displays as 1am
    test "1am is 1 am" do
      assert fmt("[h] [Pn]", 3_600_000) == "1 am"
    end

    # noon (12:00) = 12 mod 12 = 0 -> displays as 12pm
    test "noon is 12 pm" do
      assert fmt("[h] [Pn]", 43_200_000) == "12 pm"
    end

    # 1pm = hour 13 mod 12 = 1 -> displays as 1pm
    test "1pm is 1 pm" do
      assert fmt("[h] [Pn]", 46_800_000) == "1 pm"
    end
  end

  describe "AM/PM uppercase [PN]" do
    test "[PN] formats am/pm in uppercase" do
      assert fmt("[PN]", 43_200_000) == "PM"
      assert fmt("[PN]", 0) == "AM"
    end

    test "[Pn] formats am/pm in lowercase" do
      assert fmt("[Pn]", 43_200_000) == "pm"
      assert fmt("[Pn]", 0) == "am"
    end
  end

  describe "ISO week year [X]" do
    # 2017-01-01 is a Sunday -> belongs to ISO week 52 of 2016
    test "Jan 1 2017 (Sunday) has ISO week year 2016" do
      assert fmt("[X]", 1_483_228_800_000) == "2016"
    end

    # 2017-01-02 is a Monday -> first day of ISO week 1 of 2017
    test "Jan 2 2017 (Monday) has ISO week year 2017" do
      assert fmt("[X]", 1_483_315_200_000) == "2017"
    end

    # 2017-12-31 is a Sunday -> last day of ISO week 52 of 2017
    test "Dec 31 2017 (Sunday) has ISO week year 2017" do
      assert fmt("[X]", 1_514_678_400_000) == "2017"
    end

    # 2018-01-01 is a Monday -> ISO year 2018
    test "Jan 1 2018 (Monday) has ISO week year 2018" do
      assert fmt("[X]") == "2018"
    end
  end

  describe "week of year [W] boundaries" do
    # 2017-01-01 (Sunday) is in week 52 of 2016 (week < 1 path)
    test "Jan 1 2017 is week 52 of prior year" do
      assert fmt("[W]", 1_483_228_800_000) == "52"
    end

    # 2017-01-02 (Monday) is week 1 of 2017
    test "Jan 2 2017 is week 1" do
      assert fmt("[W]", 1_483_315_200_000) == "1"
    end

    # 2018-12-31 (Monday) wraps forward to week 1 of 2019 (week > 52 path)
    test "Dec 31 2018 wraps forward to week 1 of the next year" do
      assert fmt("[W]", 1_546_214_400_000) == "1"
    end
  end

  describe "week of month [w] boundaries" do
    test "Jan 1 2018 is week 1 of the month" do
      assert fmt("[w]", 1_514_764_800_000) == "1"
    end

    test "Jan 29 2018 is week 5 of the month" do
      assert fmt("[w]", 1_514_764_800_000 + 28 * 86_400_000) == "5"
    end

    test "Feb 1 2018 resets to week 1" do
      assert fmt("[w]", 1_514_764_800_000 + 31 * 86_400_000) == "1"
    end

    # Dec 31, 2018 wraps forward to month week 1 of January 2019
    test "Dec 31 2018 wraps forward to week 1 of the next month" do
      assert fmt("[w]", 1_546_214_400_000) == "1"
    end
  end

  describe "[z] GMT-prefix timezone" do
    test "[z] formats UTC as GMT+00:00" do
      assert fmt("[z]") == "GMT+00:00"
    end

    test "[z] formats negative offsets with GMT prefix" do
      assert fmt("[z]", 1_531_310_400_000, "-0500") == "GMT-05:00"
    end

    test "[z] formats positive offsets with GMT prefix" do
      assert fmt("[z]", 1_531_310_400_000, "+0530") == "GMT+05:30"
    end

    test "[Z01:01t] collapses UTC offset to Z" do
      assert fmt("[Z01:01t]") == "Z"
    end
  end

  describe "$toMillis with timezone in picture" do
    test "parses [Z01:01] colon-separated offset" do
      # 2018-01-01+05:30 = UTC 2017-12-31T18:30:00Z
      assert parse("2018-01-01+05:30", "[Y0001]-[M01]-[D01][Z01:01]") == 1_514_745_000_000
      assert parse("2018-01-01+00:00", "[Y0001]-[M01]-[D01][Z01:01]") == 1_514_764_800_000
      assert parse("2018-01-01-05:00", "[Y0001]-[M01]-[D01][Z01:01]") == 1_514_782_800_000
    end

    test "parses [z01:01] GMT-prefixed colon-separated offset" do
      assert parse("2018-01-01GMT+05:30", "[Y0001]-[M01]-[D01][z01:01]") == 1_514_745_000_000
      assert parse("2018-01-01GMT+00:00", "[Y0001]-[M01]-[D01][z01:01]") == 1_514_764_800_000
    end

    test "parses [Z01] hours-only offset (1-2 digit)" do
      # +05 is 5 hours ahead: 2018-01-01T00:00:00+05:00 = 2017-12-31T19:00:00Z
      assert parse("2018-01-01+05", "[Y0001]-[M01]-[D01][Z01]") == 1_514_746_800_000
    end

    test "parses [z01] GMT-prefixed hours-only offset" do
      assert parse("2018-01-01GMT+05", "[Y0001]-[M01]-[D01][z01]") == 1_514_746_800_000
    end

    test "parses [Z0001] 4-digit no-separator offset" do
      assert parse("2018-01-01+0530", "[Y0001]-[M01]-[D01][Z0001]") == 1_514_745_000_000
      assert parse("2018-01-01+0000", "[Y0001]-[M01]-[D01][Z0001]") == 1_514_764_800_000
    end

    test "parses fractional seconds" do
      assert parse("2018-01-01T12:00:00.123", "[Y0001]-[M01]-[D01]T[H01]:[m01]:[s01].[f001]") ==
               1_514_808_000_123

      assert parse("2018-01-01T12:00:00.12", "[Y0001]-[M01]-[D01]T[H01]:[m01]:[s01].[f001]") ==
               1_514_808_000_120
    end
  end

  describe "$toMillis with am/pm [P] component" do
    test "12:00 am (midnight) parses to start of day" do
      assert parse("2018-01-01 12:00 am", "[Y0001]-[M01]-[D01] [h01]:[m01] [Pn]") ==
               1_514_764_800_000
    end

    test "12:00 pm (noon) parses to midday" do
      assert parse("2018-01-01 12:00 pm", "[Y0001]-[M01]-[D01] [h01]:[m01] [Pn]") ==
               1_514_808_000_000
    end

    test "01:00 am parses to hour 1" do
      assert parse("2018-01-01 01:00 am", "[Y0001]-[M01]-[D01] [h01]:[m01] [Pn]") ==
               1_514_768_400_000
    end

    test "01:00 pm parses to hour 13" do
      assert parse("2018-01-01 01:00 pm", "[Y0001]-[M01]-[D01] [h01]:[m01] [Pn]") ==
               1_514_811_600_000
    end

    test "uppercase AM/PM is also accepted" do
      assert parse("2018-01-01 01:00 AM", "[Y0001]-[M01]-[D01] [h01]:[m01] [Pn]") ==
               1_514_768_400_000

      assert parse("2018-01-01 01:00 PM", "[Y0001]-[M01]-[D01] [h01]:[m01] [Pn]") ==
               1_514_811_600_000
    end

    test "12-hour time with timezone offset" do
      # 2018-01-01 12:00 am+05:30 = midnight at +05:30 = 2017-12-31T18:30:00Z
      assert parse("2018-01-01 12:00 am+05:30", "[Y0001]-[M01]-[D01] [h01]:[m01] [Pn][Z01:01]") ==
               1_514_745_000_000
    end
  end

  describe "$toMillis with Roman numeral and letter presentation" do
    test "uppercase Roman numeral month" do
      assert parse("2018-I-01", "[Y0001]-[MI]-[D01]") == 1_514_764_800_000
    end

    test "lowercase Roman numeral month" do
      assert parse("2018-i-01", "[Y0001]-[Mi]-[D01]") == 1_514_764_800_000
    end

    test "uppercase letter month" do
      assert parse("2018-A-01", "[Y0001]-[MA]-[D01]") == 1_514_764_800_000
    end

    test "lowercase letter month" do
      assert parse("2018-a-01", "[Y0001]-[Ma]-[D01]") == 1_514_764_800_000
    end
  end

  describe "day-of-week [F] formatting" do
    test "[FN] formats day name in uppercase" do
      assert fmt("[FN]") == "MONDAY"
    end

    test "[FNn] formats day name in title case" do
      assert fmt("[FNn]") == "Monday"
    end
  end

  describe "error cases" do
    # Line 112: D3135 — unclosed [ in picture
    test "unclosed [ in picture raises D3135" do
      assert {:error, %Jsonata.Error{code: "D3135"}} =
               Jsonata.evaluate("$fromMillis(0, \"[Y0001\")")
    end

    # Line 198: D3132 — unknown component letter
    test "unknown component letter raises D3132" do
      assert {:error, %Jsonata.Error{code: "D3132", value: "Q"}} =
               Jsonata.evaluate("$fromMillis(0, \"[Q]\")")
    end

    # Line 423: D3133 — name modifier on a component that doesn't support names
    test "name modifier on non-name component raises D3133" do
      assert {:error, %Jsonata.Error{code: "D3133", value: "W"}} =
               Jsonata.evaluate("$fromMillis(#{@ts}, \"[Wn]\")")
    end

    # Line 464: D3134 — too many mandatory digits in timezone
    test "timezone with 5 mandatory digits raises D3134" do
      ts = 1_531_310_400_000

      assert {:error, %Jsonata.Error{code: "D3134"}} =
               Jsonata.evaluate(~s{$fromMillis(#{ts}, "[Z00001]", "+0530")})
    end
  end

  describe "width modifier min-max syntax" do
    # Line 179: parse_width_mod with min only (no dash, no max)
    test "[Y,4] applies only min width of 4" do
      assert fmt("[Y,4]") == "2018"
    end

    # Line 180: parse_width_mod with explicit max (both min and max present)
    test "[Y,2-4] applies explicit max width of 4" do
      assert fmt("[Y,2-4]") == "2018"
    end

    # Line 184: parse_width("") returns nil — triggered by empty min or max part
    test "[Y,-4] with empty min part uses default min" do
      assert fmt("[Y,-4]") == "2018"
    end
  end

  describe "non-integer component presentation" do
    # Lines 232-233: add_format true branch — non-names, non-Z/z, non-integer component
    # [E] with digit presentation "1" falls through to the true -> def branch
    test "[E1] non-names digit presentation returns ISO era string" do
      assert fmt("[E1]") == "ISO"
    end

    # Line 287: fragment(_, "E") returns "ISO"
    test "[E] era component formats as ISO" do
      assert fmt("[E]") == "ISO"
    end

    # Line 155: integer_component?(_part) -> false — fires when a non-integer part
    # follows an integer part (no literal between them), preventing false parse_width fix
    test "non-integer [Pn] following integer [H01] is formatted correctly" do
      # Jan 1 2018 00:00:00Z
      assert fmt("[H01][Pn]", 1_514_764_800_000) == "00am"
    end
  end

  describe "ISO week month [x] component" do
    # Lines 353-362: iso_week_month function — all three branches

    # Normal branch (line 362): date is within the current month's ISO weeks
    test "[x] returns the current month for a mid-month date" do
      # Jan 15 2018
      assert fmt("[x]", 1_516_003_200_000) == "1"
    end

    # Line 360: millis < start_iso — date belongs to previous month's ISO weeks
    # Dec 1-2 2018 is Saturday/Sunday; ISO week 1 of Dec starts on Dec 3,
    # so Dec 1-2 still belong to the November ISO period.
    test "[x] returns previous month when date precedes the ISO week start" do
      assert fmt("[x]", 1_543_622_400_000) == "11"
      assert fmt("[x]", 1_543_708_800_000) == "11"
    end

    # Line 360 + line 368 (prev_month wrapping year): Jan 1 2017 is a Sunday;
    # ISO week 1 of January 2017 starts Jan 2, so Jan 1 still belongs to December 2016.
    test "[x] wraps back to December of the prior year when January date precedes its first ISO week" do
      # Jan 1 2017 (Sunday) -> belongs to December 2016
      assert fmt("[x]", 1_483_228_800_000) == "12"
    end

    # Line 361: millis >= end_iso — date belongs to next month's ISO weeks
    # May 1 2019 is Wednesday; ISO week 1 of May starts Apr 29 (Mon).
    # So Apr 29-30 2019 already belong to the May ISO period.
    test "[x] returns next month when date has crossed into its ISO week" do
      assert fmt("[x]", 1_556_496_000_000) == "5"
      assert fmt("[x]", 1_556_582_400_000) == "5"
    end
  end

  describe "week-of-month [w] prev_period for non-January months" do
    # Line 336: prev_period(year, month, _max) when month != 1
    # Sep 1 2018 is a Saturday; ISO week 1 of September starts Sep 3.
    # Sep 1 therefore falls in "week 0" of September, resolving to week 5 of August.
    test "[w] falls back to previous month when date precedes that month's first ISO week" do
      assert fmt("[w]", 1_535_760_000_000) == "5"
    end
  end

  describe "irregular timezone format (no separator)" do
    # Lines 447, 452-458: irregular_timezone with mandatory_digits in [1, 2]
    # [Z01] has mandatory_digits=2 and grouping=:none (irregular)

    test "[Z01] with half-hour offset appends minutes after colon" do
      ts = 1_531_310_400_000
      assert fmt("[Z01]", ts, "+0530") == "+05:30"
    end

    test "[Z01] with whole-hour offset omits minutes" do
      ts = 1_531_310_400_000
      assert fmt("[Z01]", ts, "+0500") == "+05"
    end

    test "[Z01] with negative offset omits minutes when offset is whole hours" do
      ts = 1_531_310_400_000
      assert fmt("[Z01]", ts, "-0500") == "-05"
    end

    # Lines 460-461: irregular_timezone with mandatory_digits in [3, 4]
    # [Z0001] has mandatory_digits=4 and grouping=:none (irregular)
    test "[Z0001] formats offset as a 4-digit hhmm number" do
      ts = 1_531_310_400_000
      assert fmt("[Z0001]", ts, "+0530") == "+0530"
    end

    test "[Z0001] zero offset formats as +0000" do
      ts = 1_531_310_400_000
      assert fmt("[Z0001]", ts, "+0000") == "+0000"
    end
  end

  describe "$toMillis with day-name [F] component" do
    # Line 559: name_lookup("F", width) — builds day-name lookup table for parsing
    test "parses day name in picture and ignores it for date calculation" do
      # 2018-01-01 is Monday; the [FNn] captures the name but F is not used in date math
      assert parse("2018-01-01 Monday", "[Y0001]-[M01]-[D01] [FNn]") == 1_514_764_800_000
    end
  end

  describe "$toMillis resolve edge cases" do
    # Line 606: resolve with empty component map -> :undefined
    # A picture made entirely of literals matches but produces no components.
    test "a pure-literal picture that matches returns :undefined" do
      assert {:ok, :undefined} = Jsonata.evaluate(~s{$toMillis("foo", "foo")})
    end

    # Lines 620, 675: date_b path — picture with year [Y] and day-of-year [d]
    test "parses ISO ordinal date (year + day-of-year)" do
      # day 1 of 2018 = 2018-01-01 = 1514764800000
      assert parse("2018-001", "[Y0001]-[d001]") == 1_514_764_800_000
      # day 5 of 2018 = 2018-01-05
      assert parse("2018-005", "[Y0001]-[d001]") == 1_514_764_800_000 + 4 * 86_400_000
    end

    # Line 649: default_components leading fill from now_millis
    # When only time components are present, the date is filled from the current time.
    test "time-only picture fills missing date components from now and returns a timestamp" do
      assert {:ok, ts} = Jsonata.evaluate(~s{$toMillis("12:00:00", "[H01]:[m01]:[s01]")})
      assert is_integer(ts)
    end

    # Line 660: D3136 — date_c (ISO week-month calendar) raises error
    test "ISO week-month calendar picture raises D3136" do
      assert {:error, %Jsonata.Error{code: "D3136"}} =
               Jsonata.evaluate(~s{$toMillis("2018-01-1", "[X0001]-[x01]-[w1]")})
    end

    # Line 660: D3136 — date_d (ISO week-year + week-of-year) raises error
    test "ISO week-year + week-of-year picture raises D3136" do
      assert {:error, %Jsonata.Error{code: "D3136"}} =
               Jsonata.evaluate(~s{$toMillis("2018-01", "[X0001]-[W01]")})
    end
  end
end
