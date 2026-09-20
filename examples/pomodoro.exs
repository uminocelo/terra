# A pomodoro timer: focus/break phases on a tick, with a progress bar and spinner.
#
#     mix run examples/pomodoro.exs
#
# Shows commands as data: init/1 schedules the first tick and update/2 reschedules
# it, so the clock keeps moving until you quit with q.

Code.require_file("pomodoro_app.exs", __DIR__)

Terra.run(Pomodoro)