# The smallest Terra app.
#
#     mix run examples/counter.exs
#
# Keys: j increments, k decrements, q quits and gives your terminal back.

Code.require_file("counter_app.exs", __DIR__)

Terra.run(Counter)
