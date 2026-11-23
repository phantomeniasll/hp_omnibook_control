// SPDX-License-Identifier: GPL-2.0-only
#define pr_fmt(fmt) KBUILD_MODNAME ": " fmt

#include <linux/acpi.h>
#include <linux/dmi.h>
#include <linux/init.h>
#include <linux/module.h>
#include <linux/slab.h>

#include "../../driver/omnibook-acpi.h"

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

static int __init query_init(void)
{
	if (!dmi_match(DMI_SYS_VENDOR, "HP") ||
	    !dmi_match(DMI_BOARD_NAME, "8DA8"))
		return -ENODEV;
	if (!omnibook_has_method(NULL, "\\GBCO", 0))
		return -ENODEV;

	read_policy("\\GTCS");
	return read_policy("\\GBCO") < 0 ? -EIO : 0;
}

static void __exit query_exit(void)
{
}

module_init(query_init);
module_exit(query_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("HP OmniBook 8DA8 battery policy diagnostic");
