defmodule Jsonata.DateTimeTest do
  use ExUnit.Case, async: true

  alias Jsonata.Error

  defp eval(expr) do
    {:ok, result} = Jsonata.evaluate(expr, :undefined)
    result
  end

  defp eval_error(expr) do
    {:error, %Error{} = error} = Jsonata.evaluate(expr, :undefined)
    error
  end

  describe "$formatBase" do
    test "converts to the given radix (default 10)" do
      assert eval("$formatBase(100, 2)") == "1100100"
      assert eval("$formatBase(255, 16)") == "ff"
      assert eval("$formatBase(42)") == "42"
    end

    test "rejects an out-of-range radix" do
      assert %Error{code: "D3100"} = eval_error("$formatBase(10, 40)")
    end

    test "undefined input passes through" do
      assert eval("$formatBase(missing, 2)") == :undefined
    end
  end

  describe "$fromMillis / $toMillis (ISO 8601 default)" do
    test "fromMillis renders an ISO 8601 UTC timestamp" do
      assert eval("$fromMillis(1)") == "1970-01-01T00:00:00.001Z"
      assert eval("$fromMillis(1521554580000)") == "2018-03-20T14:03:00.000Z"
    end

    test "toMillis parses an ISO 8601 timestamp" do
      assert eval(~s|$toMillis("1970-01-01T00:00:00.001Z")|) == 1
    end

    test "fromMillis and toMillis round-trip" do
      assert eval("$toMillis($fromMillis(1521554580000))") == 1_521_554_580_000
    end

    test "toMillis on a non-timestamp raises D3110" do
      assert %Error{code: "D3110"} = eval_error(~s|$toMillis("not a date")|)
    end

    test "undefined input passes through" do
      assert eval("$fromMillis(missing)") == :undefined
      assert eval("$toMillis(missing)") == :undefined
    end
  end

  describe "$now / $millis" do
    test "produce a string and a number" do
      assert eval("$type($now())") == "string"
      assert eval("$type($millis())") == "number"
    end
  end

  describe "picture strings" do
    test "$fromMillis formats with a picture (see DateTimePictureTest for breadth)" do
      assert {:ok, "1970"} = Jsonata.evaluate(~s|$fromMillis(0, "[Y]")|, :undefined)
    end

    test "$fromMillis with undefined picture delegates to ISO default" do
      # Exercises from_millis([millis, :undefined]) — picture arg missing at runtime
      assert eval("$fromMillis(1521554580000, missing)") == "2018-03-20T14:03:00.000Z"
    end

    test "$fromMillis with both picture and timezone undefined delegates to ISO default" do
      # Exercises from_millis([millis, :undefined, :undefined])
      assert eval("$fromMillis(1521554580000, missing, missing)") == "2018-03-20T14:03:00.000Z"
    end
  end

  describe "$now with picture" do
    test "$now([picture]) returns a formatted string matching the picture" do
      # Exercises now([picture]) → now([picture, :undefined])
      result = eval("$now(\"[Y]\")")
      assert is_binary(result)
      assert String.length(result) == 4
    end

    test "$now([picture, timezone]) returns a formatted string" do
      # Exercises now([picture, timezone])
      result = eval("$now(\"[Y]\", \"+0000\")")
      assert is_binary(result)
      assert String.length(result) == 4
    end
  end

  describe "$toMillis with fractional seconds and timezone offsets" do
    test "parses fractional seconds" do
      # Exercises frac_millis("." <> digits)
      assert eval(~s|$toMillis("1970-01-01T00:00:00.123Z")|) == 123
      assert eval(~s|$toMillis("1970-01-01T00:00:00.1Z")|) == 100
    end

    test "parses timezone with colon separator" do
      # Exercises timezone_offset_millis with [hh, mm] split ("+05:30")
      assert eval(~s|$toMillis("1970-01-01T05:30:00+05:30")|) == 0
      assert eval(~s|$toMillis("1970-01-01T00:00:00-05:00")|) == 18_000_000
    end

    test "parses timezone without colon separator" do
      # Exercises timezone_offset_millis with [hhmm] (no colon) split
      assert eval(~s|$toMillis("1970-01-01T05:30:00+0530")|) == 0
      assert eval(~s|$toMillis("1970-01-01T00:00:00-0500")|) == 18_000_000
    end
  end
end
