defmodule Jsonata.DateTime do
  @moduledoc """
  Date/time built-ins (Phase 5).

  Implements the ISO 8601 default behaviour of `$fromMillis`/`$toMillis` plus
  `$now`/`$millis`. The XPath/F&O **picture-string** formatting and parsing (a
  second argument to these functions, and `$formatInteger`/`$parseInteger`) is a
  large sub-system ported separately; supplying a picture currently raises so the
  gap is explicit rather than silently wrong.
  """

  alias Jsonata.Error

  @undefined :undefined

  @doc "Milliseconds since the Unix epoch → ISO 8601 string (UTC)."
  @spec from_millis([term()]) :: term()
  def from_millis([@undefined | _]), do: @undefined

  def from_millis([millis]) do
    millis |> round() |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
  end

  def from_millis([millis, :undefined | _]), do: from_millis([millis])
  def from_millis([_millis, _picture | _]), do: raise(picture_error())

  @doc "ISO 8601 string → milliseconds since the Unix epoch."
  @spec to_millis([term()]) :: term()
  def to_millis([@undefined | _]), do: @undefined

  def to_millis([string]) do
    case DateTime.from_iso8601(string) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime, :millisecond)
      {:error, _reason} -> raise Error.new("D3110", value: string)
    end
  end

  def to_millis([string, :undefined]), do: to_millis([string])
  def to_millis([_string, _picture]), do: raise(picture_error())

  @doc "The current time as an ISO 8601 string."
  @spec now([term()]) :: term()
  def now([]), do: from_millis([System.os_time(:millisecond)])
  def now([:undefined | _]), do: now([])
  def now([_picture | _]), do: raise(picture_error())

  @doc "The current time in milliseconds since the Unix epoch."
  @spec millis([term()]) :: integer()
  def millis([]), do: System.os_time(:millisecond)

  defp picture_error,
    do: RuntimeError.exception("date/time picture-string formatting is implemented separately")
end
