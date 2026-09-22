# A key debugger: a ring buffer of the last 20 runtime events.
#
#     mix run examples/keys.exs
#
# Press keys and watch them arrive as parsed events (`:up`, `{:char, "é"}`,
# `:tab`, `:interrupt`, `{:resize, w, h}`). Press q or Ctrl+C to quit and
# restore the terminal.

Code.require_file("keys_app.exs", __DIR__)

Terra.run(Keys)
