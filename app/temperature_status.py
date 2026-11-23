import json
from pathlib import Path


def read_number(path, scale):
    try:
        temperature = int(path.read_text()) / scale
        return round(temperature, 1) if -40 <= temperature <= 150 else None
    except (OSError, ValueError):
        return None


def driver_label(driver):
    if driver == "k10temp":
        return "cpu"
    if driver == "amdgpu":
        return "gpu"
    if driver == "nvme":
        return "ssd"
    if driver == "acpitz":
        return "system"
    if driver.startswith(("mt79", "iwl", "ath", "rtw", "brcm")):
        return "wifi"
    return "other"


def readings(sysfs=Path("/sys/class")):
    sensors = []
    for device in sorted((sysfs / "hwmon").glob("hwmon*")):
        try:
            driver = (device / "name").read_text().strip()
        except OSError:
            continue
        if driver.startswith("BAT"):
            continue
        for path in sorted(device.glob("temp*_input")):
            temperature = read_number(path, 1000)
            if temperature is None:
                continue
            kind = driver_label(driver)
            try:
                label = path.with_name(path.name.replace("_input", "_label")).read_text().strip()
            except OSError:
                label = ""
            if kind == "other":
                label = f"{driver} {label}".strip()
            elif kind == "ssd" and label == "Composite":
                label = ""
            elif kind == "cpu" and label == "Tctl":
                label = ""
            elif kind == "gpu" and label == "edge":
                label = ""
            sensors.append({"kind": kind, "label": label, "temperature": temperature})
    priority = ("cpu", "gpu", "ssd", "system", "wifi", "other")
    return sorted(sensors, key=lambda sensor: priority.index(sensor["kind"]))


if __name__ == "__main__":
    print(json.dumps(readings(), ensure_ascii=True))
