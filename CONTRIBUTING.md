# Contributing

Terra targets Elixir 1.18 or newer and OTP 28 or newer. It has no runtime dependencies.

From a checkout of this repo:

```bash
mix deps.get
mix test
mix run examples/keys.exs
```

`mix test` runs the suite with no terminal. `mix run examples/keys.exs` opens the key debugger in the current terminal. Press `q` or Ctrl+C to quit and get the shell back.

`iex -S mix` is not supported. IEx owns stdin, so raw mode, rendering, and restore are not guaranteed. Use `mix run` for examples.
