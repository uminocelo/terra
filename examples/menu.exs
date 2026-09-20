# A keyboard menu: j/k or the arrow keys move, Enter selects, q/Esc quits.
#
#     mix run examples/menu.exs
#
# This one shows event_to_msg/2 normalizing several keys into domain messages.

Code.require_file("menu_app.exs", __DIR__)

Terra.run(Menu)
