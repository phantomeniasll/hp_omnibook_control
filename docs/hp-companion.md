# HP Windows companion features on Linux

HP lists Battery Manager, enhanced call lighting, Poly Camera Pro, display and presence features, and audio processing for selected OmniBook X Flip 16-ar configurations. This is what was observed on board 8DA8.

| HP feature | Linux status |
| --- | --- |
| System Control thermal modes | HP WMI profiles are readable with the low-byte readback fix. The fan target is controlled separately in this project. |
| Battery Manager | Linux exposes both the native HP hard 80% limit (`Battery Health Manager` BIOS setting, confirmed via live write and readback on 8DA8) and the optional Linux custom soft charge pause. |
| Display brightness | The AMD backlight device exposes current and maximum brightness. HP color presets and enhanced call lighting are separate features. |
| Keyboard lighting | Linux exposes no keyboard backlight LED device on the tested kernel. Firmware hotkey support does not establish a Linux control path. |
| Camera and presence | Linux exposes camera nodes and two proximity sensors. Poly effects, presence policy, and gestures need separate investigation. |
| Tablet rotation | Linux exposes an accelerometer and a gyroscope. Desktop rotation can use these sensors. |
| Microphone and speaker | Linux exposes audio devices and a microphone mute LED. HP and Poly signal processing require a separate implementation. |

[HP app feature guide](https://support.hp.com/au-en/document/ish_7449949-7450003-16) · [HP 16-ar product datasheet](https://www8.hp.com/h20195/V2/GetPDF.aspx/4aa8-4803enca)

## Capture one change at a time

Open the HP app in Windows. From an elevated PowerShell window at the repository root, run:

```powershell
.\tools\windows\capture-hp-app.ps1 -Feature battery
```

Capture enabling and disabling the HP limit separately. Enter the current value at the first prompt. Wait for the script to finish reading the BIOS settings and prompt you to change myHP. Apply the change in myHP, then enter the new value at the prompt.

For a battery capture, `battery-bios.json` contains read-only snapshots of the battery-related BIOS settings reported by HP's WMI provider before and after the toggle. Compare `CurrentValue` for each setting. The file records whether each snapshot succeeded, found no matching settings, or could not query the provider. Review and share this file first.

The output folder also contains the change window, HP process and service names, and WMI events from that window. Review those files before sharing them, since the raw event log can include unrelated system activity. WMI events can name a method and its calling process while omitting the arguments. If the action produces no WMI event, Process Monitor can identify an HP service or device opened during the same toggle.

[Microsoft WMI tracing](https://learn.microsoft.com/windows/win32/wmisdk/tracing-wmi-activity) · [Sysinternals Process Monitor](https://learn.microsoft.com/sysinternals/downloads/procmon)
