obj-m := omnibook-fan-probe.o
obj-m += omnibook-charge-control.o

IASL ?= iasl
quiet_cmd_omnibook_asl = IASL    $@
      cmd_omnibook_asl = $(IASL) -tc -p $(basename $@) $<

targets += omnibook_native_read.hex
$(obj)/omnibook_native_read.hex: $(src)/omnibook_native_read.asl FORCE
	$(call if_changed,omnibook_asl)

$(obj)/omnibook-charge-control.o: $(obj)/omnibook_native_read.hex
