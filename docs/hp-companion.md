# HP Windows companion features on Linux

HP lists Battery Manager, enhanced call lighting, Poly Camera Pro, display and presence features, and audio processing for selected OmniBook X Flip 16-ar configurations. This is what was observed on board 8DA8.

| HP feature | Linux status |
| --- | --- |
| System Control thermal modes | HP WMI profiles are readable with the low-byte readback fix. The fan target is controlled separately in this project. |
| Battery Manager | The firmware can pause charging under Linux. HP's native Windows 80% setting still needs a capture. |
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

Capture enabling and disabling the HP limit separately. The script stores the change window, HP process and service names, and relevant WMI log events in a local folder. Review the logs before sharing them. A WMI event can name the method and calling process while omitting arguments. If the action produces no WMI event, Process Monitor can identify an HP service or device opened during the same toggle.

[Microsoft WMI tracing](https://learn.microsoft.com/windows/win32/wmisdk/tracing-wmi-activity) · [Sysinternals Process Monitor](https://learn.microsoft.com/sysinternals/downloads/procmon)
