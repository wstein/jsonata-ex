defmodule Jsonata.FormatTest do
  use ExUnit.Case, async: true

  alias Jsonata.Error

  defp fmt(value, picture) do
    {:ok, result} = Jsonata.evaluate("$formatInteger(#{inspect(value)}, #{inspect(picture)})")
    result
  end

  defp fmt_error(value, picture) do
    {:error, %Error{} = error} =
      Jsonata.evaluate("$formatInteger(#{inspect(value)}, #{inspect(picture)})")

    error
  end

  defp parse(value, picture) do
    {:ok, result} = Jsonata.evaluate("$parseInteger(#{inspect(value)}, #{inspect(picture)})")
    result
  end

  defp fnum(expr) do
    {:ok, result} = Jsonata.evaluate(expr)
    result
  end

  describe "decimal pictures" do
    test "plain and zero-padded" do
      assert fmt(123, "0") == "123"
      assert fmt(123, "000000") == "000123"
      assert fmt(0, "0") == "0"
    end

    test "regular grouping separators" do
      assert fmt(1_234_567, "#,##0") == "1,234,567"
      assert fmt(1_234_567_890, "#,###,##0") == "1,234,567,890"
    end

    test "irregular grouping separators" do
      assert fmt(1_234_567_890, "##,##,##0") == "12345,67,890"
    end

    test "negative numbers keep the sign outside the grouping" do
      assert fmt(-1_234, "#,##0") == "-1,234"
    end

    test "a picture with no mandatory digit raises D3130" do
      assert %Error{code: "D3130"} = fmt_error(5, "###")
    end
  end

  describe "ordinal modifier" do
    test "decimal ordinals" do
      assert fmt(1, "0;o") == "1st"
      assert fmt(2, "0;o") == "2nd"
      assert fmt(3, "0;o") == "3rd"
      assert fmt(4, "0;o") == "4th"
      assert fmt(11, "0;o") == "11th"
      assert fmt(21, "0;o") == "21st"
    end
  end

  describe "roman numerals" do
    test "upper and lower case" do
      assert fmt(2024, "I") == "MMXXIV"
      assert fmt(2024, "i") == "mmxxiv"
      assert fmt(0, "I") == ""
    end
  end

  describe "letter sequences" do
    test "single and rolled-over letters" do
      assert fmt(1, "a") == "a"
      assert fmt(26, "A") == "Z"
      assert fmt(27, "A") == "AA"
    end
  end

  describe "spelled-out words" do
    test "cardinals" do
      assert fmt(123, "w") == "one hundred and twenty-three"
      assert fmt(1234, "w") == "one thousand, two hundred and thirty-four"
      assert fmt(0, "w") == "zero"
    end

    test "case variants" do
      assert fmt(5, "W") == "FIVE"
      assert fmt(5, "Ww") == "Five"
    end

    test "ordinals" do
      assert fmt(1, "w;o") == "first"
      assert fmt(21, "w;o") == "twenty-first"
      assert fmt(100, "w;o") == "one hundredth"
    end
  end

  test "undefined input yields undefined" do
    assert {:ok, :undefined} = Jsonata.evaluate("$formatInteger(nothing, '0')", %{})
  end

  describe "$parseInteger" do
    test "decimals with and without grouping" do
      assert parse("123", "0") == 123
      assert parse("1,234,567", "#,##0") == 1_234_567
      assert parse("12345,67,890", "##,##,##0") == 1_234_567_890
    end

    test "ordinal decimals" do
      assert parse("1st", "0;o") == 1
      assert parse("21st", "0;o") == 21
      assert parse("11th", "0;o") == 11
    end

    test "roman, letters, and words" do
      assert parse("MMXXIV", "I") == 2024
      assert parse("mmxxiv", "i") == 2024
      assert parse("AA", "A") == 27
      assert parse("one hundred and twenty-three", "w") == 123
      assert parse("one thousand, two hundred and thirty-four", "w") == 1234
    end

    test "word ordinals" do
      assert parse("first", "w;o") == 1
      assert parse("twenty-first", "w;o") == 21
      assert parse("one hundredth", "w;o") == 100
    end

    test "round-trips formatInteger" do
      for {n, picture} <- [{42, "0"}, {1_234_567, "#,##0"}, {2024, "I"}, {27, "A"}, {321, "w"}] do
        formatted = fmt(n, picture)
        assert parse(formatted, picture) == n
      end
    end

    test "undefined input yields undefined" do
      assert {:ok, :undefined} = Jsonata.evaluate("$parseInteger(nothing, '0')", %{})
    end
  end

  describe "$formatNumber" do
    test "grouping, padding, and decimals" do
      assert fnum("$formatNumber(12345.6, '#,###.00')") == "12,345.60"
      assert fnum("$formatNumber(1234.5678, '#,##0.00')") == "1,234.57"
      assert fnum("$formatNumber(1230000, '#,###')") == "1,230,000"
      assert fnum("$formatNumber(-6, '000')") == "-006"
      assert fnum("$formatNumber(0.1, '#.##')") == ".1"
    end

    test "scientific notation" do
      assert fnum("$formatNumber(1234.5678, '00.000e0')") == "12.346e2"
      assert fnum("$formatNumber(1, '0.0e0')") == "1.0e0"
      assert fnum("$formatNumber(1234.5678, '#0.000e0')") == "1.235e3"
    end

    test "percent and per-mille scaling" do
      assert fnum("$formatNumber(0.14, '01%')") == "14%"
      assert fnum("$formatNumber(0.14, '###0.0%')") == "14.0%"
    end

    test "positive;negative sub-picture pair with banker's rounding" do
      assert fnum("$formatNumber(34.555, '#0.00;(#0.00)')") == "34.56"
      assert fnum("$formatNumber(-34.555, '#0.00;(#0.00)')") == "(34.56)"
    end

    test "options object overrides the formatting symbols" do
      assert fnum(
               ~s|$formatNumber(1234.5, '#.##0,00', {"grouping-separator": ".", "decimal-separator": ","})|
             ) ==
               "1.234,50"
    end

    test "an over-long picture raises D3080" do
      assert {:error, %Error{code: "D3080"}} = Jsonata.evaluate("$formatNumber(1, '0;0;0')")
    end

    test "undefined input yields undefined" do
      assert {:ok, :undefined} = Jsonata.evaluate("$formatNumber(nothing, '0')", %{})
    end
  end
end
