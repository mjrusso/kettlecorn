ifeq ($(TARGET),wasm32-unknown-wasi)
TYPE_FLAGS += -DNO_JUMP_TABLE
# NIF_OBJS lists NIF libraries for driver_tab.c; these extend the wasm NIF.
EXTRA_BASE_OBJS += $(OBJDIR)/kettlecorn_bridge.o $(OBJDIR)/kettlecorn_dns.o \
	$(OBJDIR)/kettlecorn_http_nif.o $(OBJDIR)/kettlecorn_tty.o
DRV_OBJS += $(OBJDIR)/inet_drv.o
OS_OBJS := $(filter-out $(OBJDIR)/sys_uds.o,$(OS_OBJS))
endif
