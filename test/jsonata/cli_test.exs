defmodule Jsonata.CLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  # Run the CLI, capture stdout (stderr suppressed), return {exit_code, stdout}.
  defp exec(args, stdin \\ "") do
    me = self()
    ref = make_ref()

    stdout =
      capture_io([input: stdin], fn ->
        capture_io(:stderr, fn ->
          code = Jsonata.CLI.execute(args)
          send(me, {ref, code})
        end)
      end)

    code =
      receive do
        {^ref, c} -> c
      after
        1000 -> flunk("CLI.execute timed out")
      end

    {code, stdout}
  end

  # ── Fix 1: number formatting ────────────────────────────────────────────────

  describe "number formatting" do
    test "whole-number float collapses to integer string (no trailing .0)" do
      # 4/2 is Elixir float division → 2.0; must render as "2" not "2.0"
      assert {0, "2\n"} = exec(["-n", "4/2"])
    end

    test "non-whole float preserves decimal places" do
      assert {0, "1.5\n"} = exec(["-n", "1.5"])
    end

    test "integer results print without decimal point" do
      assert {0, "6\n"} = exec(["-n", "$sum([1,2,3])"])
    end

    test "function reference encodes as empty JSON string" do
      # $sum without () returns a function value; JS JSON.stringify renders it ""
      assert {0, "\"\"\n"} = exec(["-n", "$sum"])
    end
  end

  # ── Fix 2: falsy? delegates to Functions.jboolean ──────────────────────────

  describe "--exit-status falsy semantics" do
    test "exits 1 for boolean false" do
      assert {1, _} = exec(["-e", "-n", "false"])
    end

    test "exits 1 for null" do
      assert {1, _} = exec(["-e", "-n", "null"])
    end

    test "exits 1 for numeric zero" do
      assert {1, _} = exec(["-e", "-n", "0"])
    end

    test "exits 1 for empty string" do
      assert {1, _} = exec(["-e", "-n", "\"\""])
    end

    test "exits 1 for empty array" do
      assert {1, _} = exec(["-e", "-n", "[]"])
    end

    test "exits 1 for empty object" do
      assert {1, _} = exec(["-e", "-n", "{}"])
    end

    test "exits 0 for boolean true" do
      assert {0, _} = exec(["-e", "-n", "true"])
    end

    test "exits 0 for non-zero number" do
      assert {0, _} = exec(["-e", "-n", "42"])
    end

    test "exits 0 for non-empty string" do
      assert {0, _} = exec(["-e", "-n", "\"hello\""])
    end

    test "exits 0 for non-empty array" do
      assert {0, _} = exec(["-e", "-n", "[1]"])
    end

    test "exits 0 for non-empty object" do
      assert {0, _} = exec(["-e", "-n", "{\"a\":1}"])
    end
  end

  # ── Fix 3: input key ordering via Jsonata.decode ───────────────────────────

  describe "input key ordering" do
    test "$keys preserves JSON insertion order" do
      {0, output} = exec(["-c", "$keys($)"], ~s({"z": 1, "a": 2, "m": 3}))
      assert output == ~s(["z","a","m"]\n)
    end

    test "nested object key order is preserved" do
      {0, output} = exec(["-c", "$keys($.inner)"], ~s({"inner": {"c": 1, "b": 2, "a": 3}}))
      assert output == ~s(["c","b","a"]\n)
    end
  end

  # ── Fix 4: --arg flag protection ───────────────────────────────────────────

  describe "--arg flag protection" do
    test "rejects a flag-like token as the --arg value" do
      {code, _} = exec(["--arg", "name", "--compact", "-n", "\"ok\""])
      assert code == 1
    end

    test "rejects a flag-like token as the --argjson value" do
      {code, _} = exec(["--argjson", "n", "--compact", "-n", "42"])
      assert code == 1
    end

    test "--arg with a valid string value binds the variable" do
      assert {0, "\"hello\"\n"} = exec(["--arg", "x", "hello", "-n", "$x"])
    end

    test "--argjson with a valid JSON value binds the variable" do
      assert {0, "3\n"} = exec(["--argjson", "nums", "[1,2]", "-n", "$sum($nums) + 0"])
    end

    test "--arg missing value exits 1" do
      assert {1, _} = exec(["--arg", "name"])
    end

    test "--argjson missing value exits 1" do
      assert {1, _} = exec(["--argjson", "name"])
    end
  end

  # ── Basic smoke tests ───────────────────────────────────────────────────────

  describe "basic behavior" do
    test "evaluates expression against stdin JSON" do
      assert {0, "\"Alice\"\n"} = exec(["$.name"], ~s({"name": "Alice"}))
    end

    test "-r prints string without quotes" do
      assert {0, "Alice\n"} = exec(["-r", "$.name"], ~s({"name": "Alice"}))
    end

    test "-n uses null as input" do
      assert {0, "6\n"} = exec(["-n", "$sum([1,2,3])"])
    end

    test "--compact produces single-line output" do
      assert {0, ~s({"a":1}\n)} = exec(["-c", "$"], ~s({"a": 1}))
    end

    test "pretty output indents nested structures" do
      {0, output} = exec(["$"], ~s({"a": [1, 2]}))
      assert output =~ "  \"a\":"
    end

    test "--version exits 0 and prints version string" do
      {code, output} = exec(["--version"])
      assert code == 0
      assert output =~ ~r/jsonata \d/
    end

    test "no arguments exits 1" do
      assert {1, _} = exec([])
    end

    test "expression error exits 5" do
      assert {5, _} = exec(["-n", "$notafunction()"])
    end

    test "undefined result produces no output" do
      {0, output} = exec(["$.missing"], ~s({"a": 1}))
      assert output == ""
    end

    test "--arg binds a string variable" do
      assert {0, "\"hello Alice\"\n"} =
               exec(["--arg", "name", "Alice", "-n", "\"hello \" & $name"])
    end

    test "--argjson binds a parsed JSON variable" do
      assert {0, "6\n"} = exec(["--argjson", "nums", "[1,2,3]", "-n", "$sum($nums)"])
    end

    test "--help prints usage and exits 0" do
      {code, output} = exec(["--help"])
      assert code == 0
      assert output =~ "Usage:"
      assert output =~ "--compact"
    end

    test "-h is an alias for --help" do
      {code, output} = exec(["-h"])
      assert code == 0
      assert output =~ "Usage:"
    end

    test "unknown option warns to stderr and continues" do
      # --unknownoption is not recognised; code 0 since --null-input + valid expr follows
      {code, _} = exec(["--unknownoption", "-n", "1"])
      assert code == 0
    end

    test "invalid JSON from stdin exits 3" do
      {code, _} = exec(["$"], "not json")
      assert code == 3
    end

    test "--argjson with invalid JSON value exits 1" do
      {code, _} = exec(["--argjson", "x", "not-json", "-n", "1"])
      assert code == 1
    end

    test "file input: reads JSON from a file" do
      path = Path.join(System.tmp_dir!(), "cli_test_#{System.unique_integer([:positive])}.json")
      File.write!(path, ~s({"msg":"from file"}))

      try do
        assert {0, "\"from file\"\n"} = exec(["$.msg", path])
      after
        File.rm(path)
      end
    end

    test "file not found exits 2" do
      {code, _} = exec(["$", "/no/such/file/xyz_abc.json"])
      assert code == 2
    end

    test "null output renders as null" do
      assert {0, "null\n"} = exec(["-n", "null"])
    end
  end
end
