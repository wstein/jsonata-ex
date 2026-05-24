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
end
