# A mix test watcher: runs the suite as a port command and lists failures.
#
#     mix run examples/test_watcher.exs
#
# The suite runs as data: init/1 returns `{:port, "mix test --no-color", :ran}`
# and the output arrives in update/2 as `{:ran, {:ok, {lines, status}}}`.
# Select a failure with j/k or the arrows to read its assertion, scroll the
# pane with Ctrl+D/Ctrl+U, re-run with r, quit with q or Ctrl+C.

Code.require_file("test_watcher_app.exs", __DIR__)

Terra.run(TestWatcher)
