defmodule Jsonata.DateTime do
  @moduledoc """
  Date/time built-ins (Phase 5).

  Implements `$fromMillis`/`$toMillis`/`$now`/`$millis`. ISO 8601 is the default
  (with all components but the year optional); picture-string formatting and
  parsing (`$fromMillis`/`$now`/`$toMillis` with a picture) is delegated to
  `Jsonata.DateTimePicture`.
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

  # ISO 8601 with everything but the year optional (mirrors jsonata-js)
  @iso8601 ~r/^(\d{4})(?:-([01]\d))?(?:-([0-3]\d))?(?:T([0-2]\d):([0-5]\d):([0-5]\d))?(\.\d+)?([+-][0-2]\d:?[0-5]\d|Z)?$/

  @doc "ISO 8601 string (or a picture-string format) → milliseconds since the Unix epoch."
  @spec to_millis([term()]) :: term()
  def to_millis([@undefined | _]), do: @undefined

  def to_millis([string]) do
    case Regex.run(@iso8601, string) do
      nil -> raise Error.new("D3110", value: string)
      [_whole | parts] -> iso_to_millis(parts ++ List.duplicate("", 8 - length(parts)))
    end
  end

  def to_millis([string, :undefined]), do: to_millis([string])

  def to_millis([string, picture]),
    do: Jsonata.DateTimePicture.parse(string, picture, System.os_time(:millisecond))

  @doc "The current time as an ISO 8601 string."
  @spec now([term()]) :: term()
  def now([]), do: from_millis([System.os_time(:millisecond)])
  def now([picture]), do: now([picture, @undefined])
  def now([@undefined, @undefined]), do: now([])
  def now([picture, timezone]), do: from_millis([System.os_time(:millisecond), picture, timezone])

  @doc "The current time in milliseconds since the Unix epoch."
  @spec millis([term()]) :: integer()
  def millis([]), do: System.os_time(:millisecond)

  # parts = [year, month, day, hour, minute, second, frac, timezone] ("" when absent)
  defp iso_to_millis([year, month, day, hour, minute, second, frac, timezone]) do
    date_millis = utc_date_millis(to_int(year, 0), to_int(month, 1), to_int(day, 1))
    time_millis = ((to_int(hour, 0) * 60 + to_int(minute, 0)) * 60 + to_int(second, 0)) * 1000
    date_millis + time_millis + frac_millis(frac) - timezone_offset_millis(timezone)
  end

  defp utc_date_millis(year, month, day) do
    year
    |> Date.new!(month, day)
    |> DateTime.new!(~T[00:00:00.000], "Etc/UTC")
    |> DateTime.to_unix(:millisecond)
  end

  defp to_int("", default), do: default
  defp to_int(value, _default), do: String.to_integer(value)

  defp frac_millis(""), do: 0

  defp frac_millis("." <> digits),
    do: digits |> String.slice(0, 3) |> String.pad_trailing(3, "0") |> String.to_integer()

  defp timezone_offset_millis(tz) when tz in ["", "Z"], do: 0

  defp timezone_offset_millis(<<sign::utf8, rest::binary>>) do
    {hours, minutes} =
      case String.split(rest, ":") do
        [hh, mm] ->
          {String.to_integer(hh), String.to_integer(mm)}

        [hhmm] ->
          {hhmm |> String.slice(0, 2) |> String.to_integer(),
           hhmm |> String.slice(2, 2) |> String.to_integer()}
      end

    millis = (hours * 60 + minutes) * 60 * 1000
    if sign == ?-, do: -millis, else: millis
  end
end
