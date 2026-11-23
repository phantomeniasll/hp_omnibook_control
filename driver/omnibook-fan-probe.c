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
#include <linux/workqueue.h>

#include "omnibook-acpi.h"

#define FAN_CONTROL 0x93
#define FAN_TARGET 0x94
#define FAN_TACHOMETER 0x95
#define FAN_OVERRIDE BIT(4)
#define RPM_PER_UNIT 50
#define REQUESTED_RPM 4500
#define MAX_OWNERSHIP (120 * HZ)
#define FIRMWARE_INTERVAL (8 * HZ)
#define ACPI_TEMP_MIN 2732
#define ACPI_TEMP_LIMIT 3482
#define MIN_CURVE_RPM 3000
#define CURVE_LEASE_SECONDS 6

static acpi_handle pci0;
static bool allow_untested_bios;
static bool writes_allowed;
static bool ready;
static bool curve;
static bool active;
static bool owns_override;
static bool recovering;
static bool cooling_off;
static bool suspended;
static int active_target;
static int firmware_floor;
static unsigned long lease_until;
static unsigned long ownership_until;
static unsigned long firmware_until;
static DEFINE_MUTEX(fan_lock);

module_param(allow_untested_bios, bool, 0400);
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

static int clear_override(void)
{
	int attempt, control;

	for (attempt = 0; attempt < 3; attempt++) {
		set_override(false);
		control = mailbox_read(FAN_CONTROL);
		if (control >= 0 && control != U8_MAX && !(control & FAN_OVERRIDE))
			return 0;
		msleep(100);
	}

	pr_warn_ratelimited("Could not verify automatic fan control, retrying\n");
	return -EIO;
}

static bool safe_to_boost(void)
{
	unsigned long long temperature;

	return ACPI_SUCCESS(acpi_evaluate_integer(NULL, "\\_TZ_.TZS0._TMP", NULL, &temperature)) &&
	       temperature >= ACPI_TEMP_MIN && temperature < ACPI_TEMP_LIMIT;
}

static void monitor_override(struct work_struct *work);
static DECLARE_DELAYED_WORK(override_work, monitor_override);

static int handoff_get(char *buffer, const struct kernel_param *parameter)
{
	int length;

	mutex_lock(&fan_lock);
	length = sysfs_emit(buffer, "%s\n", recovering ? "recovering" :
			   active ? "override" : "firmware");
	mutex_unlock(&fan_lock);
	return length;
}

static const struct kernel_param_ops handoff_ops = { .get = handoff_get };
module_param_cb(handoff, &handoff_ops, NULL, 0444);

/* Hold a module reference from the first attempted write through verified restore. */
static int restore_fan(void)
{
	if (!owns_override)
		return 0;
	recovering = true;
	if (clear_override()) {
		mod_delayed_work(system_wq, &override_work, HZ);
		return -EIO;
	}
	WRITE_ONCE(active, false);
	recovering = false;
	cooling_off = true;
	firmware_until = jiffies + FIRMWARE_INTERVAL;
	owns_override = false;
	pr_info("Automatic fan control restored\n");
	module_put(THIS_MODULE);
	return 0;
}

static void monitor_override(struct work_struct *work)
{
	int tachometer, control;

	mutex_lock(&fan_lock);
	if (!ready || !owns_override)
		goto out;

	if (recovering || !active || time_after_eq(jiffies, lease_until) ||
	    time_after_eq(jiffies, ownership_until) || !safe_to_boost())
		goto restore;
	tachometer = mailbox_read(FAN_TACHOMETER);
	control = mailbox_read(FAN_CONTROL);
	if (tachometer <= 0 || tachometer == U8_MAX ||
	    control < 0 || control == U8_MAX || !(control & FAN_OVERRIDE) ||
	    mailbox_read(FAN_TARGET) != active_target / RPM_PER_UNIT)
		goto restore;
	mod_delayed_work(system_wq, &override_work, HZ);
	goto out;
restore:
	restore_fan();
out:
	mutex_unlock(&fan_lock);
}

static int cancel_boost(const char *value, const struct kernel_param *parameter)
{
	int result;
	bool requested;

	if (kstrtobool(value, &requested) || !requested)
		return -EINVAL;
	mutex_lock(&fan_lock);
	result = ready ? restore_fan() : -ENODEV;
	mutex_unlock(&fan_lock);
	return result;
}

static const struct kernel_param_ops cancel_boost_ops = { .set = cancel_boost };
module_param_cb(cancel, &cancel_boost_ops, NULL, 0200);

static int set_curve_target(const char *value, const struct kernel_param *parameter)
{
	int rpm, control, tachometer, current_target, result;

	if (kstrtoint(value, 10, &rpm) || rpm < MIN_CURVE_RPM ||
	    rpm > REQUESTED_RPM || rpm % RPM_PER_UNIT)
		return -EINVAL;
	mutex_lock(&fan_lock);
	result = -ENODEV;
	if (!ready)
		goto out;
	result = -EOPNOTSUPP;
	if (!writes_allowed)
		goto out;
	result = -EBUSY;
	if (suspended)
		goto out;
	if (recovering)
		goto out;
	if (!safe_to_boost()) {
		restore_fan();
		goto out;
	}
	if (owns_override && (!active || time_after_eq(jiffies, ownership_until) ||
			      time_after_eq(jiffies, lease_until))) {
		restore_fan();
		result = -EAGAIN;
		goto out;
	}
	if (cooling_off && time_before(jiffies, firmware_until)) {
		result = -EAGAIN;
		goto out;
	}
	cooling_off = false;

	control = mailbox_read(FAN_CONTROL);
	tachometer = mailbox_read(FAN_TACHOMETER);
	current_target = mailbox_read(FAN_TARGET);
	result = -EIO;
	if (control < 0 || control == U8_MAX || tachometer < 0 || tachometer == U8_MAX ||
	    current_target < 0 || current_target == U8_MAX)
		goto restore;
	if (!owns_override) {
		if (control & FAN_OVERRIDE) {
			result = -EBUSY;
			goto out;
		}
		firmware_floor = max(tachometer, current_target) * RPM_PER_UNIT;
	}
	if (rpm <= firmware_floor) {
		result = -EALREADY;
		goto restore;
	}
	if (owns_override && !(control & FAN_OVERRIDE))
		goto restore;

	if (!owns_override) {
		if (!try_module_get(THIS_MODULE))
			goto out;
		owns_override = true;
		ownership_until = jiffies + MAX_OWNERSHIP;
		if (set_override(true))
			goto restore;
	}
	if (current_target != rpm / RPM_PER_UNIT &&
	    mailbox_write(FAN_TARGET, rpm / RPM_PER_UNIT))
		goto restore;
	control = mailbox_read(FAN_CONTROL);
	if (control < 0 || control == U8_MAX || !(control & FAN_OVERRIDE) ||
	    mailbox_read(FAN_TARGET) != rpm / RPM_PER_UNIT)
		goto restore;

	active_target = rpm;
	lease_until = jiffies + CURVE_LEASE_SECONDS * HZ;
	if (!active) {
		WRITE_ONCE(active, true);
		mod_delayed_work(system_wq, &override_work, HZ);
	}
	result = 0;
	goto out;

restore:
	restore_fan();
out:
	mutex_unlock(&fan_lock);
	return result;
}

static const struct kernel_param_ops curve_target_ops = { .set = set_curve_target };
module_param_cb(target, &curve_target_ops, NULL, 0200);

static int pause_for_sleep(struct notifier_block *notifier, unsigned long event, void *data)
{
	int result = 0;

	mutex_lock(&fan_lock);
	if (ready && (event == PM_SUSPEND_PREPARE || event == PM_HIBERNATION_PREPARE)) {
		suspended = true;
		result = restore_fan();
		if (result)
			suspended = false;
	} else if (event == PM_POST_SUSPEND || event == PM_POST_HIBERNATION) {
		suspended = false;
	}
	mutex_unlock(&fan_lock);
	return result ? NOTIFY_BAD : NOTIFY_OK;
}

static struct notifier_block fan_pm_notifier = { .notifier_call = pause_for_sleep };

static int __init omnibook_fan_probe_init(void)
{
	int sample, control, target, result;

	if (!dmi_match(DMI_SYS_VENDOR, "HP") ||
	    !dmi_match(DMI_BOARD_NAME, "8DA8"))
		return -ENODEV;

	if (ACPI_FAILURE(acpi_get_handle(NULL, "\\_SB.PCI0", &pci0)) ||
	    !omnibook_has_method(pci0, "RDMB", 1) ||
	    !omnibook_has_method(pci0, "WRMB", 2) ||
	    !omnibook_has_method(pci0, "AOMB", 3) ||
	    !omnibook_has_method(NULL, "\\_TZ_.TZS0._TMP", 0)) {
		pr_info("Expected ACPI fan or temperature methods were not found\n");
		return -ENODEV;
	}

	control = mailbox_read(FAN_CONTROL);
	target = mailbox_read(FAN_TARGET);
	sample = mailbox_read(FAN_TACHOMETER);
	if (control < 0 || control == U8_MAX || target < 0 || target == U8_MAX ||
	    sample < 0 || sample == U8_MAX) {
		pr_info("Fan mailbox did not return valid readings\n");
		return -ENODEV;
	}

	writes_allowed = curve && (dmi_match(DMI_BIOS_VERSION, "F.11") || allow_untested_bios);
	pr_info("Fan firmware access: %s; tachometer %d RPM, target %d RPM\n",
		writes_allowed ? "curve control" : "read-only",
		sample * RPM_PER_UNIT, target * RPM_PER_UNIT);
	result = register_pm_notifier(&fan_pm_notifier);
	if (!result) {
		mutex_lock(&fan_lock);
		ready = true;
		mutex_unlock(&fan_lock);
	}
	return result;
}

static void __exit omnibook_fan_probe_exit(void)
{
	mutex_lock(&fan_lock);
	ready = false;
	mutex_unlock(&fan_lock);
	unregister_pm_notifier(&fan_pm_notifier);
	cancel_delayed_work_sync(&override_work);
	mutex_lock(&fan_lock);
	/* Normal removal is impossible until the ownership reference is released. */
	WARN_ON_ONCE(owns_override);
	mutex_unlock(&fan_lock);
}

module_init(omnibook_fan_probe_init);
module_exit(omnibook_fan_probe_exit);

MODULE_DESCRIPTION("HP OmniBook 8DA8 fan control with bounded firmware ownership");
MODULE_LICENSE("GPL");
