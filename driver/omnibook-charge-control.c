// SPDX-License-Identifier: GPL-2.0-only
#define pr_fmt(fmt) KBUILD_MODNAME ": " fmt

#include <linux/acpi.h>
#include <linux/dmi.h>
#include <linux/init.h>
#include <linux/jiffies.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/slab.h>
#include <linux/suspend.h>
#include <linux/workqueue.h>

#include "omnibook-acpi.h"

#define CHARGE_AUTO 4
#define CHARGE_INHIBIT 5
#define LEASE_TIME (60 * HZ)

static DEFINE_MUTEX(charge_lock);
static bool ready;
static bool writes_allowed;
static bool allow_untested_bios;
static bool owned;
static bool inhibited;
static bool suspended;
static unsigned long lease_until;
static void expire_inhibit(struct work_struct *work);
static DECLARE_DELAYED_WORK(expiry, expire_inhibit);

module_param(allow_untested_bios, bool, 0400);

static int sbco(unsigned int mode)
{
	union acpi_object argument = { .integer = {
		.type = ACPI_TYPE_INTEGER, .value = mode << 8,
	} };
	struct acpi_object_list args = { .count = 1, .pointer = &argument };
	struct acpi_buffer output = { ACPI_ALLOCATE_BUFFER, NULL };
	union acpi_object *reply;
	acpi_status status;
	int result = -EIO;

	status = acpi_evaluate_object(NULL, "\\SBCO", &args, &output);
	reply = output.pointer;
	if (ACPI_SUCCESS(status) && reply && reply->type == ACPI_TYPE_PACKAGE &&
	    reply->package.count >= 2 &&
	    reply->package.elements[0].type == ACPI_TYPE_INTEGER &&
	    !reply->package.elements[0].integer.value)
		result = 0;
	kfree(output.pointer);
	return result;
}

static int gbco(void)
{
	struct acpi_buffer output = { ACPI_ALLOCATE_BUFFER, NULL };
	union acpi_object *reply, *payload;
	acpi_status status;
	int result = -EIO;

	status = acpi_evaluate_object(NULL, "\\GBCO", NULL, &output);
	reply = output.pointer;
	if (ACPI_SUCCESS(status) && reply && reply->type == ACPI_TYPE_PACKAGE &&
	    reply->package.count >= 3 &&
	    reply->package.elements[0].type == ACPI_TYPE_INTEGER &&
	    !reply->package.elements[0].integer.value) {
		payload = &reply->package.elements[2];
		if (payload->type == ACPI_TYPE_BUFFER &&
		    payload->buffer.length && payload->buffer.pointer)
			result = payload->buffer.pointer[0];
	}
	kfree(output.pointer);
	return result;
}

static int restore_charge(void)
{
	int mode;

	if (!owned)
		return 0;
	lease_until = jiffies;
	if (sbco(CHARGE_AUTO))
		goto retry;
	mode = gbco();
	if (mode != 0 && mode != 1)
		goto retry;
	owned = false;
	inhibited = false;
	pr_info("Automatic charging restored\n");
	module_put(THIS_MODULE);
	return 0;
retry:
	pr_warn_ratelimited("Could not restore automatic charging, retrying\n");
	mod_delayed_work(system_wq, &expiry, 5 * HZ);
	return -EIO;
}

static void expire_inhibit(struct work_struct *work)
{
	unsigned long now;

	mutex_lock(&charge_lock);
	if (!ready || !owned)
		goto out;
	now = jiffies;
	if (time_before(now, lease_until))
		mod_delayed_work(system_wq, &expiry, lease_until - now);
	else
		restore_charge();
out:
	mutex_unlock(&charge_lock);
}

static int charge_set(const char *value, const struct kernel_param *parameter)
{
	bool requested;
	int mode, result;

	if (kstrtobool(value, &requested))
		return -EINVAL;
	mutex_lock(&charge_lock);
	if (!ready) {
		result = -ENODEV;
		goto out;
	}
	if (!requested) {
		result = restore_charge();
		goto out;
	}
	result = -EOPNOTSUPP;
	if (!writes_allowed)
		goto out;
	result = -EBUSY;
	if (suspended)
		goto out;
	if (owned) {
		if (inhibited && time_before(jiffies, lease_until))
			goto renew;
		goto out;
	}
	mode = gbco();
	if (mode != 0 && mode != 1)
		goto out;
	if (!try_module_get(THIS_MODULE))
		goto out;
	owned = true;
	if (!sbco(CHARGE_INHIBIT)) {
		mode = gbco();
		if (mode >= 4 && mode <= 6) {
			inhibited = true;
			pr_info("Charging paused\n");
			goto renew;
		}
	}
	restore_charge();
	result = -EIO;
	goto out;
renew:
	lease_until = jiffies + LEASE_TIME;
	mod_delayed_work(system_wq, &expiry, LEASE_TIME);
	result = 0;
out:
	mutex_unlock(&charge_lock);
	return result;
}

static int charge_get(char *buffer, const struct kernel_param *parameter)
{
	int length;

	mutex_lock(&charge_lock);
	length = ready ? sysfs_emit(buffer, "%c\n", inhibited ? 'Y' : 'N') : -ENODEV;
	mutex_unlock(&charge_lock);
	return length;
}

static const struct kernel_param_ops charge_ops = {
	.set = charge_set,
	.get = charge_get,
};
module_param_cb(inhibit, &charge_ops, NULL, 0644);

static int suspend_charge(struct notifier_block *block, unsigned long event, void *data)
{
	int result = 0;

	mutex_lock(&charge_lock);
	if (!ready)
		goto out;
	switch (event) {
	case PM_SUSPEND_PREPARE:
	case PM_HIBERNATION_PREPARE:
		suspended = true;
		result = restore_charge();
		if (result)
			suspended = false;
		break;
	case PM_POST_SUSPEND:
	case PM_POST_HIBERNATION:
		suspended = false;
		break;
	}
out:
	mutex_unlock(&charge_lock);
	return result ? NOTIFY_BAD : NOTIFY_OK;
}

static struct notifier_block sleep_notifier = { .notifier_call = suspend_charge };

static int __init charge_init(void)
{
	int mode, result;

	if (!dmi_match(DMI_SYS_VENDOR, "HP") ||
	    !dmi_match(DMI_BOARD_NAME, "8DA8"))
		return -ENODEV;
	if (!omnibook_has_method(NULL, "\\GBCO", 0) ||
	    !omnibook_has_method(NULL, "\\SBCO", 1)) {
		pr_info("Expected ACPI charging methods were not found\n");
		return -ENODEV;
	}
	mode = gbco();
	if (mode < 0 || mode > 6) {
		pr_info("ACPI did not return a recognized charging mode\n");
		return -ENODEV;
	}
	writes_allowed = dmi_match(DMI_BIOS_VERSION, "F.11") || allow_untested_bios;
	pr_info("Battery firmware access: %s\n", writes_allowed ? "pause control" : "read-only");

	result = register_pm_notifier(&sleep_notifier);
	if (!result) {
		mutex_lock(&charge_lock);
		ready = true;
		mutex_unlock(&charge_lock);
	}
	return result;
}

static void __exit charge_exit(void)
{
	mutex_lock(&charge_lock);
	ready = false;
	mutex_unlock(&charge_lock);
	unregister_pm_notifier(&sleep_notifier);
	cancel_delayed_work_sync(&expiry);
	mutex_lock(&charge_lock);
	/* Normal removal is impossible until the ownership reference is released. */
	WARN_ON_ONCE(owned);
	mutex_unlock(&charge_lock);
}

module_init(charge_init);
module_exit(charge_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Lease-based HP OmniBook 8DA8 charge inhibit control");
