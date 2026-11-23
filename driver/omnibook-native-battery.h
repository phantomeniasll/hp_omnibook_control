/* SPDX-License-Identifier: GPL-2.0-only */
#include <linux/build_bug.h>
#include <linux/crc32.h>
#include "omnibook_native_read.hex"

#define HP_BIOS_SET "1F4C91EB-DC5C-460B-951D-C7CB9B4B8D5E"
#define HP_BATTERY_SETTING "Battery Health Manager"
#define HP_BATTERY_ON "Maximize my battery health On"
#define HP_BATTERY_OFF "Maximize my battery health Off"
#define HP_READ_METHOD "\\_SB.WMID.OBBQ"
#define HP_ENUM_INSTANCES 89

static u32 native_table_index;
static bool native_table_loaded;
static int native_instance = -1;
static int native_state = -ENODEV;

static bool __init native_supported(void)
{
	struct acpi_table_header *table;
	unsigned int i;

	if (!wmi_has_guid(HP_BIOS_SET) || !acpi_has_method(NULL, "\\_SB.WMID.WQBC"))
		return false;

	/* The mailbox layout is verified for the 8DA8 HP WMI table. */
	for (i = 1; i <= 64; i++) {
		bool matches;

		if (ACPI_FAILURE(acpi_get_table(ACPI_SIG_SSDT, i, &table)))
			break;
		matches = table->length == 30394 &&
			(crc32_le(~0U, (const u8 *)table, table->length) ^ ~0U) == 0xba1ad9f1;
		acpi_put_table(table);
		if (matches)
			return true;
	}
	pr_info("Native Battery Health Manager unavailable: unrecognized HP WMI SSDT\n");
	return false;
}

static int native_read(unsigned int instance)
{
	union acpi_object arg = {
		.integer.type = ACPI_TYPE_INTEGER,
		.integer.value = instance,
	};
	struct acpi_object_list args = { 1, &arg };
	struct acpi_buffer output = { ACPI_ALLOCATE_BUFFER, NULL };
	const union acpi_object *reply;
	acpi_status status;
	int result = -EIO;

	status = acpi_evaluate_object(NULL, HP_READ_METHOD, &args, &output);
	reply = output.pointer;
	if (ACPI_SUCCESS(status) && reply && reply->type == ACPI_TYPE_STRING) {
		if (reply->string.length == sizeof(HP_BATTERY_ON) - 1 &&
		    !memcmp(reply->string.pointer, HP_BATTERY_ON, sizeof(HP_BATTERY_ON) - 1))
			result = 1;
		else if (reply->string.length == sizeof(HP_BATTERY_OFF) - 1 &&
			 !memcmp(reply->string.pointer, HP_BATTERY_OFF, sizeof(HP_BATTERY_OFF) - 1))
			result = 0;
	}
	kfree(output.pointer);
	return result;
}

static void native_unload(void)
{
	if (native_table_loaded && ACPI_FAILURE(acpi_unload_table(native_table_index)))
		pr_warn("Could not unload the native battery reader\n");
	native_table_loaded = false;
}

static struct acpi_table_header *__init native_reuse_table(void)
{
	struct acpi_table_header *table;
	unsigned int i;

	for (i = 1; i <= 128; i++) {
		if (ACPI_FAILURE(acpi_get_table(ACPI_SIG_SSDT, i, &table)))
			break;
		if (table->length == sizeof(omnibook_native_read_aml_code) &&
		    !memcmp(table, omnibook_native_read_aml_code, table->length))
			return table;
		acpi_put_table(table);
	}
	return NULL;
}

static void __init native_init(void)
{
	struct acpi_table_header *table, *registered;
	acpi_handle handle;
	bool reused;
	int instance, state;
	acpi_status status;

	if (!native_supported())
		return;
	if (ACPI_SUCCESS(acpi_get_handle(NULL, HP_READ_METHOD, &handle))) {
		pr_warn("Native Battery Health Manager skipped: %s already exists\n",
			HP_READ_METHOD);
		return;
	}

	table = native_reuse_table();
	reused = table != NULL;
	if (!reused)
		table = kmemdup(omnibook_native_read_aml_code,
				sizeof(omnibook_native_read_aml_code), GFP_KERNEL);
	if (!table)
		return;

	native_table_index = U32_MAX;
	status = acpi_load_table(table, &native_table_index);
	/* ACPICA retains the catalogued buffer even after namespace unload.
	 * On reload it may reuse that buffer and leave our new copy unused.
	 */
	if (reused) {
		acpi_put_table(table);
	} else if (native_table_index == U32_MAX ||
	    ACPI_FAILURE(acpi_get_table_by_index(native_table_index, &registered))) {
		kfree(table);
	} else {
		if (registered != table)
			kfree(table);
		acpi_put_table(registered);
	}
	if (ACPI_FAILURE(status))
		return;
	native_table_loaded = true;

	/* Try the observed slot first, then validate any shifted enumeration. */
	instance = 79;
	state = native_read(instance);
	if (state < 0) {
		for (instance = 0; instance < HP_ENUM_INSTANCES; instance++) {
			if (instance == 79)
				continue;
			state = native_read(instance);
			if (state >= 0)
				break;
		}
	}
	if (state < 0) {
		native_unload();
		return;
	}
	native_instance = instance;
	native_state = state;
	pr_info("Native Battery Health Manager available (instance %d, %s)\n",
		instance, state ? "on" : "off");
}

static __le16 *native_put_string(__le16 *output, const char *value)
{
	*output++ = cpu_to_le16(strlen(value) * sizeof(*output));
	while (*value)
		*output++ = cpu_to_le16((u8)*value++);
	return output;
}

static int native_write(bool enable)
{
	__le16 payload[sizeof(HP_BATTERY_SETTING) + sizeof(HP_BATTERY_OFF) +
		       sizeof("<utf-16/>")];
	__le16 *end = payload;
	struct acpi_buffer output = { ACPI_ALLOCATE_BUFFER, NULL };
	struct acpi_buffer input = { .pointer = payload };
	const union acpi_object *reply;
	acpi_status status;
	int result = -EIO;

	BUILD_BUG_ON(sizeof(HP_BATTERY_ON) > sizeof(HP_BATTERY_OFF));
	end = native_put_string(end, HP_BATTERY_SETTING);
	end = native_put_string(end, enable ? HP_BATTERY_ON : HP_BATTERY_OFF);
	end = native_put_string(end, "<utf-16/>");
	input.length = (end - payload) * sizeof(*end);
	status = wmi_evaluate_method(HP_BIOS_SET, 0, 1, &input, &output);
	reply = output.pointer;
	if (ACPI_SUCCESS(status) && reply && reply->type == ACPI_TYPE_INTEGER &&
	    !reply->integer.value)
		result = 0;
	kfree(output.pointer);
	return result;
}
