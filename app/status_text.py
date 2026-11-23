"""Human-readable status summaries for fan and battery controls."""

from curve_control import KEYS


def fan_decision(status):
    state = status.get("state") or ""
    if not state:
        return "Fan service unavailable."
    if state == "Restoring HP fan control":
        return "Restoring HP fan control. The firmware has not confirmed the handoff."
    target = status.get("target") or 0
    if target > 0:
        if status.get("boost"):
            return f"Fan boost requests {target:,} RPM."
        return f"The custom curve requests {target:,} RPM."
    if state == "Firmware cooling":
        return "HP controls the fan for temperature safety."
    if state == "Checking firmware fan speed":
        return "HP controls the fan during a scheduled speed check."
    if state == "Firmware fan speed is already sufficient":
        return "HP already calls for at least as much cooling as the selected curve."
    if state == "Automatic":
        if status.get("profile") in KEYS:
            return "HP controls the fan below the first point of the selected curve."
        return "HP controls the fan."
    return state


def charge_summary(charge):
    states = {
        "Charging": "Charging",
        "Not charging": "Not charging",
        "Discharging": "Discharging",
        "Full": "Fully charged",
    }
    battery_status = charge.get("battery_status")
    parts = [states.get(battery_status, "Charging status unavailable")]
    capacity = charge.get("capacity")
    if isinstance(capacity, int):
        parts.append(f"{capacity}%")
    online = charge.get("online")
    if online is True:
        parts.append("Plugged in")
    elif online is False:
        parts.append("Unplugged")
    power_watts = charge.get("power_watts")
    if battery_status in ("Charging", "Discharging") and isinstance(power_watts, (int, float)) and power_watts > 0:
        parts.append(f"{power_watts:.1f} W")
    return " · ".join(parts)


def charge_decision(charge):
    service_active = charge.get("service_active") is True
    native = charge.get("native_limit")
    if not service_active:
        if native == "on":
            return "Charge-limit service is inactive. HP hard 80% limit is enabled."
        if native == "unknown":
            return "Charge-limit service is inactive. Could not verify the HP charging limit."
        return "Charge-limit service is inactive."

    enabled = bool(charge.get("enabled"))
    limit = charge.get("limit")
    hysteresis = charge.get("hysteresis")
    native_note = ""
    if native == "on":
        if enabled and isinstance(limit, int) and limit > 80:
            native_note = " HP hard 80% limit is also on and caps charging at 80%."
        else:
            native_note = " HP hard 80% limit is also on."
    elif native == "unknown":
        native_note = " Could not verify the HP charging limit."

    state = charge.get("state") or ""
    if state not in ("Automatic charging", "Charging paused"):
        return state + native_note
    if not enabled:
        if native == "on":
            return "HP hard 80% limit is enabled."
        if native == "unknown":
            return "Could not verify the HP charging limit."
        return "Custom soft limit off. HP manages charging."
    if charge.get("online") is False:
        return "The soft limit applies when plugged in." + native_note

    resume = limit - hysteresis if isinstance(limit, int) and isinstance(hysteresis, int) else None
    battery_status = charge.get("battery_status")
    capacity = charge.get("capacity")
    if charge.get("paused") and battery_status == "Not charging":
        return f"Held by the custom soft limit at {limit}%. Charging resumes at {resume}%." + native_note
    if (native == "on" and isinstance(limit, int) and limit > 80
            and battery_status == "Not charging" and isinstance(capacity, int) and capacity >= 79):
        return f"Held by the HP hard 80% limit (custom soft limit is set to {limit}%)."
    if battery_status == "Charging" and isinstance(capacity, int) and isinstance(limit, int) and capacity < limit:
        return f"Charging toward the {limit}% limit." + native_note
    return f"Soft limit on. Stops at {limit}% and resumes at {resume}%." + native_note
