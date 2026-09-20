# A tick-driven app: a spinner that advances every 100 ms.
#
#     mix run examples/tick.exs
#
# Commands are data: init/1 returns `{:tick, ms, msg}` and the runtime delivers
# `msg` to update/2 after that many milliseconds. Press q to quit and restore.

Code.require_file("tick_app.exs", __DIR__)

Terra.run(Spinner)
