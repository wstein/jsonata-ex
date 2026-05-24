defmodule JsonataTest do
  use ExUnit.Case, async: true
  doctest Jsonata

  test "version/0 reports the application version" do
    assert Jsonata.version() == "0.1.0"
  end
end
