// SPDX-License-Identifier: GPL-2.0-only
#define pr_fmt(fmt) KBUILD_MODNAME ": " fmt

#include <linux/acpi.h>
#include <linux/delay.h>
#include <linux/dmi.h>
#include <linux/init.h>
#include <linux/jiffies.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/suspend.h>
#include <linux/thermal.h>
#include <linux/workqueue.h>

#define FAN_CONTROL 0x93
#define FAN_TARGET 0x94
#define FAN_TACHOMETER 0x95
#define FAN_OVERRIDE BIT(4)
#define RPM_PER_UNIT 50
#define REQUESTED_RPM 4500
#define BOOST_DURATION_SECONDS 30
#define BOOST_ACPI_LIMIT_MC 75000
#define MIN_CURVE_RPM 3000
#define CURVE_LEASE_SECONDS 6

static acpi_handle pci0;
static bool boost;
static bool curve;
static bool active;
static bool suspended;
static int active_target;
static int firmware_floor;
static unsigned long boost_deadline;
static DEFINE_MUTEX(fan_lock);

module_param(boost, bool, 0400);
module_param(curve, bool, 0444);
module_param(active, bool, 0444);

static int mailbox_read(unsigned int address)
{
	union acpi_object argument = { .integer = {
		.type = ACPI_TYPE_INTEGER, .value = address,
	} };
	struct acpi_object_list args = { .count = 1, .pointer = &argument };
	unsigned long long value;

	if (ACPI_FAILURE(acpi_evaluate_integer(pci0, "RDMB", &args, &value)) ||
	    value > U8_MAX)
		return -EIO;

	return value;
}

static int mailbox_write(unsigned int address, unsigned int value)
{
	union acpi_object arguments[] = {
		{ .integer = { .type = ACPI_TYPE_INTEGER, .value = address } },
		{ .integer = { .type = ACPI_TYPE_INTEGER, .value = value } },
	};
	struct acpi_object_list args = {
		.count = ARRAY_SIZE(arguments), .pointer = arguments,
	};

	return ACPI_FAILURE(acpi_evaluate_object(pci0, "WRMB", &args, NULL))
		? -EIO : 0;
}

static int set_override(bool enabled)
{
	union acpi_object arguments[] = {
		{ .integer = { .type = ACPI_TYPE_INTEGER, .value = FAN_CONTROL } },
		{ .integer = { .type = ACPI_TYPE_INTEGER, .value = 0xef } },
		{ .integer = { .type = ACPI_TYPE_INTEGER,
			       .value = enabled ? FAN_OVERRIDE : 0 } },
	};
	struct acpi_object_list args = {
		.count = ARRAY_SIZE(arguments), .pointer = arguments,
	};

	return ACPI_FAILURE(acpi_evaluate_object(pci0, "AOMB", &args, NULL))
		? -EIO : 0;
}

static int restore_automatic(void)
{
	int attempt, control;

	for (attempt = 0; attempt < 3; attempt++) {
		set_override(false);
		control = mailbox_read(FAN_CONTROL);
		if (control >= 0 && !(control & FAN_OVERRIDE))
			return 0;
		msleep(100);
	}

	pr_err("Unable to verify automatic control. Reboot to reset the controller.\n");
	return -EIO;
}

static bool safe_to_boost(void)
{
	struct thermal_zone_device *zone = thermal_zone_get_zone_by_name("acpitz");
	int temperature;

	return !IS_ERR_OR_NULL(zone) && !thermal_zone_get_temp(zone, &temperature) &&
	       temperature < BOOST_ACPI_LIMIT_MC;
}

static void monitor_boost(struct work_struct *work);
static DECLARE_DELAYED_WORK(boost_work, monitor_boost);

static void monitor_boost(struct work_struct *work)
{
	int tachometer, control;

	mutex_lock(&fan_lock);
	if (!active)
		goto out;
	tachometer = mailbox_read(FAN_TACHOMETER);
	control = mailbox_read(FAN_CONTROL);

	if (time_after_eq(jiffies, boost_deadline) || !safe_to_boost() ||
	    tachometer <= 0 || tachometer == U8_MAX ||
	    (!curve && tachometer * RPM_PER_UNIT > active_target) ||
	    control < 0 || !(control & FAN_OVERRIDE) ||
	    mailbox_read(FAN_TARGET) != active_target / RPM_PER_UNIT) {
		if (!restore_automatic()) {
			WRITE_ONCE(active, false);
			pr_info("Automatic fan control restored\n");
			goto out;
		}
	}
	schedule_delayed_work(&boost_work, HZ);
out:
	mutex_unlock(&fan_lock);
}

static int cancel_boost(const char *value, const struct kernel_param *parameter)
{
	int result;
	bool requested;

	if (kstrtobool(value, &requested) || !requested)
		return -EINVAL;
	cancel_delayed_work_sync(&boost_work);
	mutex_lock(&fan_lock);
	if (!active) {
		result = 0;
		goto out;
	}
	result = restore_automatic();
	if (result) {
		boost_deadline = jiffies;
		schedule_delayed_work(&boost_work, HZ);
		goto out;
	}
	WRITE_ONCE(active, false);
	pr_info("Automatic fan control restored\n");
out:
	mutex_unlock(&fan_lock);
	return result;
}

static const struct kernel_param_ops cancel_boost_ops = { .set = cancel_boost };
module_param_cb(cancel, &cancel_boost_ops, NULL, 0200);

static int set_curve_target(const char *value, const struct kernel_param *parameter)
{
	int rpm, control, tachometer, current_target, result = -EIO;

	if (kstrtoint(value, 10, &rpm) || rpm < MIN_CURVE_RPM ||
	    rpm > REQUESTED_RPM || rpm % RPM_PER_UNIT)
		return -EINVAL;
	mutex_lock(&fan_lock);
	if (!curve || suspended || !safe_to_boost()) {
		result = -EBUSY;
		goto out;
	}
	control = mailbox_read(FAN_CONTROL);
	tachometer = mailbox_read(FAN_TACHOMETER);
	current_target = mailbox_read(FAN_TARGET);
	if (control < 0 || tachometer < 0 || tachometer == U8_MAX ||
	    current_target < 0 || current_target == U8_MAX)
		goto out;
	if (!active) {
		if (control & FAN_OVERRIDE) {
			result = -EBUSY;
			goto out;
		}
		firmware_floor = max(tachometer, current_target) * RPM_PER_UNIT;
	}
	if (rpm <= firmware_floor || (active && !(control & FAN_OVERRIDE))) {
		result = -EAGAIN;
		goto out;
	}

	if (!active && set_override(true))
		goto restore;
	if ((current_target != rpm / RPM_PER_UNIT || !active) &&
	    mailbox_write(FAN_TARGET, rpm / RPM_PER_UNIT))
		goto restore;
	control = mailbox_read(FAN_CONTROL);
	if (control < 0 || !(control & FAN_OVERRIDE) ||
	    mailbox_read(FAN_TARGET) != rpm / RPM_PER_UNIT)
		goto restore;

	active_target = rpm;
	boost_deadline = jiffies + CURVE_LEASE_SECONDS * HZ;
	if (!active) {
		WRITE_ONCE(active, true);
		schedule_delayed_work(&boost_work, HZ);
	}
	result = 0;
	goto out;

restore:
	if (!restore_automatic()) {
		WRITE_ONCE(active, false);
	} else {
		WRITE_ONCE(active, true);
		boost_deadline = jiffies;
		schedule_delayed_work(&boost_work, HZ);
	}
out:
	mutex_unlock(&fan_lock);
	return result;
}

static const struct kernel_param_ops curve_target_ops = { .set = set_curve_target };
module_param_cb(target, &curve_target_ops, NULL, 0200);

static int pause_for_sleep(struct notifier_block *notifier, unsigned long event, void *data)
{
	if (event == PM_SUSPEND_PREPARE || event == PM_HIBERNATION_PREPARE) {
		mutex_lock(&fan_lock);
		suspended = true;
		mutex_unlock(&fan_lock);
		if (cancel_boost("1", NULL))
			return NOTIFY_BAD;
	} else if (event == PM_POST_SUSPEND || event == PM_POST_HIBERNATION) {
		mutex_lock(&fan_lock);
		suspended = false;
		mutex_unlock(&fan_lock);
	}
	return NOTIFY_OK;
}

static struct notifier_block fan_pm_notifier = { .notifier_call = pause_for_sleep };

static int __init omnibook_fan_probe_init(void)
{
	int sample, tachometer, previous_target, control, baseline, target;
	int result = -EIO;

	if (!dmi_match(DMI_SYS_VENDOR, "HP") ||
	    !dmi_match(DMI_BOARD_NAME, "8DA8") ||
	    !dmi_match(DMI_BIOS_VERSION, "F.11"))
		return -ENODEV;

	if (ACPI_FAILURE(acpi_get_handle(NULL, "\\_SB.PCI0", &pci0)))
		return -ENODEV;

	if (curve)
		return boost ? -EINVAL : register_pm_notifier(&fan_pm_notifier);

	if (boost && !safe_to_boost()) {
		pr_info("Skipping boost: ACPI temperature is high or unavailable\n");
		return -EBUSY;
	}

	control = mailbox_read(FAN_CONTROL);
	previous_target = mailbox_read(FAN_TARGET);
	tachometer = mailbox_read(FAN_TACHOMETER);
	if (control < 0 || previous_target < 0 || tachometer <= 0 ||
	    tachometer == U8_MAX)
		return -EIO;
	baseline = tachometer * RPM_PER_UNIT;
	pr_info("Automatic RPM before probe: %d, control 0x%02x, target byte 0x%02x\n",
		baseline, control, previous_target);
	if ((control & FAN_OVERRIDE) || baseline + 300 > REQUESTED_RPM) {
		pr_info("Skipping probe: an override is already active or RPM is already near the test target\n");
		return -EBUSY;
	}

	if (mailbox_write(FAN_TARGET, REQUESTED_RPM / RPM_PER_UNIT)) {
		pr_info("Could not stage the requested target\n");
		goto restore;
	}
	target = mailbox_read(FAN_TARGET);
	pr_info("Target readback while still in automatic mode: %d (requested %d)\n",
		target, REQUESTED_RPM / RPM_PER_UNIT);
	if (set_override(true)) {
		pr_info("ACPI could not enable the fan override\n");
		goto restore;
	}
	if (mailbox_write(FAN_TARGET, REQUESTED_RPM / RPM_PER_UNIT)) {
		pr_info("ACPI could not write the fan target after enabling the override\n");
		goto restore;
	}
	control = mailbox_read(FAN_CONTROL);
	target = mailbox_read(FAN_TARGET);
	if (control < 0 || !(control & FAN_OVERRIDE) ||
	    target != REQUESTED_RPM / RPM_PER_UNIT) {
		pr_info("Controller did not confirm the request: control %d, target %d, expected %d\n",
			control, target, REQUESTED_RPM / RPM_PER_UNIT);
		goto restore;
	}

	if (boost) {
		active_target = REQUESTED_RPM;
		WRITE_ONCE(active, true);
		boost_deadline = jiffies + BOOST_DURATION_SECONDS * HZ;
		schedule_delayed_work(&boost_work, HZ);
		pr_info("Fan boost requested: %d RPM for up to %d seconds\n",
			REQUESTED_RPM, BOOST_DURATION_SECONDS);
		return 0;
	}

	for (sample = 1; sample <= 5; sample++) {
		msleep(1000);
		tachometer = mailbox_read(FAN_TACHOMETER);
		if (tachometer <= 0 || tachometer == U8_MAX)
			goto restore;
		pr_info("RPM after %d seconds: %d (target %d)\n",
			sample, tachometer * RPM_PER_UNIT, REQUESTED_RPM);
	}
	result = 0;

restore:
	if (restore_automatic())
		return -EIO;
	pr_info("Automatic fan control restored\n");
	return result;
}

static void __exit omnibook_fan_probe_exit(void)
{
	if (curve)
		unregister_pm_notifier(&fan_pm_notifier);
	cancel_delayed_work_sync(&boost_work);
	if (READ_ONCE(active) && !restore_automatic()) {
		WRITE_ONCE(active, false);
		pr_info("Automatic fan control restored\n");
	}
}

module_init(omnibook_fan_probe_init);
module_exit(omnibook_fan_probe_exit);

MODULE_DESCRIPTION("Timed HP OmniBook 8DA8 F.11 fan boost and hardware probe");
MODULE_LICENSE("GPL");
