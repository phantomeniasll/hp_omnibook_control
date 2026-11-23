/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef OMNIBOOK_ACPI_H
#define OMNIBOOK_ACPI_H

#include <linux/acpi.h>
#include <linux/slab.h>

static inline bool omnibook_has_method(acpi_handle parent, acpi_string name, u8 args)
{
	struct acpi_device_info *info;
	acpi_handle method;
	bool matches;

	if (ACPI_FAILURE(acpi_get_handle(parent, name, &method)) ||
	    ACPI_FAILURE(acpi_get_object_info(method, &info)))
		return false;
	matches = info->type == ACPI_TYPE_METHOD && info->param_count == args;
	kfree(info);
	return matches;
}

#endif
