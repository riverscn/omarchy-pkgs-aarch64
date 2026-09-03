def entry_id:
  if type == "object" then (.id // "" | tostring) else tostring end;

def without_bar_widget($id):
  .bar.layout.left = ((.bar.layout.left // []) | map(select(entry_id != $id)))
  | .bar.layout.center = ((.bar.layout.center // []) | map(select(entry_id != $id)))
  | .bar.layout.right = ((.bar.layout.right // []) | map(select(entry_id != $id)));

without_bar_widget("omarchy.bluetooth")
| (.bar.layout.left[], .bar.layout.center[], .bar.layout.right[]
    | select(entry_id == "omarchy.indicators")) |= (
      if has("items") then
        .items |= map(select(. != "NightLight" and . != "ScreenRecording"))
      else
        .items = ["Dictation", "Reminder", "Dnd", "StayAwake"]
      end
    )
| .disabledPlugins = (
    (.disabledPlugins // []) + ["omarchy.bluetooth", "omarchy.nightlight"]
    | unique
  )
