// SPDX-License-Identifier: GPL-2.0-only
#define pr_fmt(fmt) KBUILD_MODNAME ": " fmt

#include <linux/acpi.h>
#include <linux/delay.h>
#include <linux/dmi.h>
#include <linux/init.h>
#include <linux/module.h>
#include <linux/slab.h>

static bool test_inhibit;
static bool restore_after_test;
module_param(test_inhibit, bool, 0400);
module_param(restore_after_test, bool, 0400);

static int read_policy(char *path)
{
	struct acpi_buffer output = { ACPI_ALLOCATE_BUFFER, NULL };
	const union acpi_object *reply;
	const union acpi_object *data;
	acpi_status status;
	int result = -EIO;

	status = acpi_evaluate_object(NULL, path, NULL, &output);
	if (ACPI_FAILURE(status)) {
		pr_info("%s: %s\n", path, acpi_format_exception(status));
		goto out;
	}
	reply = output.pointer;
	if (!reply || reply->type != ACPI_TYPE_PACKAGE ||
	    reply->package.count < 2 ||
	    reply->package.elements[0].type != ACPI_TYPE_INTEGER) {
		pr_info("%s: invalid reply\n", path);
		goto out;
	}
	if (reply->package.elements[0].integer.value || reply->package.count < 3) {
		pr_info("%s: firmware status 0x%llx\n", path,
			reply->package.elements[0].integer.value);
		goto out;
	}
	data = &reply->package.elements[2];
	if (data->type != ACPI_TYPE_BUFFER || data->buffer.length < 4 ||
	    !data->buffer.pointer) {
		pr_info("%s: missing payload\n", path);
		goto out;
	}
	pr_info("%s: %4ph\n", path, data->buffer.pointer);
	result = data->buffer.pointer[0];
out:
	kfree(output.pointer);
	return result;
}

static int set_charge_mode(unsigned int mode)
{
	union acpi_object argument = { .integer = {
		.type = ACPI_TYPE_INTEGER,
		.value = mode << 8,
	} };
	struct acpi_object_list args = { .count = 1, .pointer = &argument };
	struct acpi_buffer output = { ACPI_ALLOCATE_BUFFER, NULL };
	const union acpi_object *reply;
	int result = -EIO;
	acpi_status status;

	status = acpi_evaluate_object(NULL, "\\SBCO", &args, &output);
	reply = output.pointer;
	if (ACPI_SUCCESS(status) && reply && reply->type == ACPI_TYPE_PACKAGE &&
	    reply->package.count >= 2 &&
	    reply->package.elements[0].type == ACPI_TYPE_INTEGER) {
		pr_info("SBCO mode 0x%02x returned firmware status 0x%llx\n",
			mode, reply->package.elements[0].integer.value);
		if (!reply->package.elements[0].integer.value)
			result = 0;
	} else {
		pr_info("SBCO mode 0x%02x failed: %s\n", mode, acpi_format_exception(status));
	}
	kfree(output.pointer);
	return result;
}

static int try_charge_inhibit(int initial)
{
	int paused = -EIO, restored, attempt;

	if (initial != 0 && initial != 1) {
		pr_info("Skipping inhibit test because firmware was not in automatic mode\n");
		return -EBUSY;
	}
	if (!set_charge_mode(5)) {
		pr_info("Reading back temporary inhibit\n");
		paused = read_policy("\\GBCO");
		if (paused >= 4 && paused <= 6)
			msleep(6000);
	}

	for (attempt = 0; attempt < 2; attempt++) {
		if (set_charge_mode(4))
			continue;
		restored = read_policy("\\GBCO");
		if (restored == 0 || restored == 1) {
			pr_info("Automatic charging restored (firmware mode 0x%02x)\n", restored);
			return paused >= 4 && paused <= 6 ? 0 : -EOPNOTSUPP;
		}
	}
	pr_err("Unable to verify automatic charging after the test\n");
	return -EIO;
}

static int __init query_init(void)
{
	int mode;

	if (!dmi_match(DMI_SYS_VENDOR, "HP") ||
	    !dmi_match(DMI_BOARD_NAME, "8DA8") ||
	    !dmi_match(DMI_BIOS_VERSION, "F.11"))
		return -ENODEV;

	read_policy("\\GTCS");
	mode = read_policy("\\GBCO");
	if (restore_after_test) {
		if (test_inhibit || (mode != 0 && mode != 1 && mode != 4))
			return -EBUSY;
		if (set_charge_mode(4))
			return -EIO;
		mode = read_policy("\\GBCO");
		return mode == 0 || mode == 1 ? 0 : -EIO;
	}
	return test_inhibit ? try_charge_inhibit(mode) : 0;
}

static void __exit query_exit(void)
{
}

module_init(query_init);
module_exit(query_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("HP OmniBook 8DA8 battery policy diagnostic");
