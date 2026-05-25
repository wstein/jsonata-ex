# The conformance scoreboard loads ~1,400 cases; it is excluded from the default
# run and gated separately via `mix test --only conformance`.
ExUnit.start(exclude: [:conformance])
