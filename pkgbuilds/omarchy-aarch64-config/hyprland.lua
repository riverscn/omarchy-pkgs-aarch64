-- Runtime capability policy for the generic AArch64 VM profile. Omarchy loads
-- this after its defaults and before the user's bindings, so users can still
-- deliberately provide a replacement implementation.

local function unbind_all(bindings)
  for _, binding in ipairs(bindings) do
    hl.unbind(binding)
  end
end

if o.cmd_missing("gpu-screen-recorder") then
  unbind_all({
    "ALT + PRINT",
    "SUPER + ALT + code:34",
    "SUPER + ALT + code:35",
  })
end

if o.cmd_missing("hyprsunset") then
  hl.unbind("SUPER + CTRL + N")
end

if o.cmd_missing("bluetoothctl") then
  hl.unbind("SUPER + CTRL + B")
end

if o.cmd_missing("brightnessctl") and o.cmd_missing("ddcutil") and o.cmd_missing("asdcontrol") then
  unbind_all({
    "XF86MonBrightnessUp",
    "XF86MonBrightnessDown",
    "SHIFT + XF86MonBrightnessUp",
    "SHIFT + XF86MonBrightnessDown",
    "ALT + XF86MonBrightnessUp",
    "ALT + XF86MonBrightnessDown",
  })
end

if o.cmd_missing("brightnessctl") then
  unbind_all({
    "XF86KbdBrightnessUp",
    "XF86KbdBrightnessDown",
    "XF86KbdLightOnOff",
  })
end
