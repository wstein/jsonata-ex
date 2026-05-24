defmodule Jsonata.DateTime do
  @moduledoc """
  Date/time built-ins (Phase 5).

  Implements `$fromMillis`/`$toMillis`/`$now`/`$millis`. ISO 8601 is the default;
  picture-string **formatting** (`$fromMillis`/`$now`) is delegated to
  `Jsonata.DateTimePicture`. Picture-string **parsing** (`$toMillis` with a
  picture) is not yet implemented and raises so the gap is explicit.
  """

  alias Jsonata.Error

  @undefined :undefined

  @doc "Milliseconds since the Unix epoch → ISO 8601 string (UTC), or a picture string."
  @spec from_millis([term()]) :: term()
  def from_millis([@undefined | _]), do: @undefined

  def from_millis([millis]) do
    millis |> round() |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
  end

  def from_millis([millis, @undefined]), do: from_millis([millis])
  def from_millis([millis, @undefined, @undefined]), do: from_millis([millis])

  def from_millis([millis, picture]), do: from_millis([millis, picture, @undefined])

  def from_millis([millis, picture, timezone]),
    do: Jsonata.DateTimePicture.format(round(millis), picture, timezone)

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
  def now([picture]), do: now([picture, @undefined])
  def now([@undefined, @undefined]), do: now([])
  def now([picture, timezone]), do: from_millis([System.os_time(:millisecond), picture, timezone])

  @doc "The current time in milliseconds since the Unix epoch."
  @spec millis([term()]) :: integer()
  def millis([]), do: System.os_time(:millisecond)

  defp picture_error,
    do: RuntimeError.exception("date/time picture-string formatting is implemented separately")
end
