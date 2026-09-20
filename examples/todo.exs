# A todo wizard: Tab switches between the input and the list, Enter adds, d deletes.
#
#     mix run examples/todo.exs
#
# Shows the v0.2 widgets (input, list, focus) in one plain Terra.App.

Code.require_file("todo_app.exs", __DIR__)

Terra.run(Todo)