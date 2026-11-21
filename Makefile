CC := xcrun clang
CXX := xcrun clang++
COMMON_FLAGS := -mmacosx-version-min=12.0 -O2 -Iinclude
OBJC_FLAGS := -fobjc-arc -Wall -Wextra -Werror $(COMMON_FLAGS)
OBJCXX_FLAGS := -fobjc-arc -std=c++17 -Wall -Wextra $(COMMON_FLAGS)
FRAMEWORKS := -framework Foundation

BUILD_DIR := build
SAMPLE_BUNDLE := $(BUILD_DIR)/MBD_SampleUSB.bundle
SAMPLE_EXEC := $(SAMPLE_BUNDLE)/Contents/MacOS/MBD_SampleUSB
HOST_BIN := $(BUILD_DIR)/mbd-host

SQR100_DIR := samples/sqr100_driver
SQR100_HW := $(SQR100_DIR)/hw
SQR100_BUNDLE := $(BUILD_DIR)/MBD_SQR100.bundle
SQR100_EXEC := $(SQR100_BUNDLE)/Contents/MacOS/MBD_SQR100
SQR100_OBJ_DIR := $(BUILD_DIR)/sqr100_obj
SQR100_C_SRCS := $(SQR100_HW)/usb.c $(SQR100_HW)/it930x.c $(SQR100_HW)/cxd2856er.c $(SQR100_HW)/cxd6866.c $(SQR100_HW)/tsmf.c
SQR100_C_OBJS := $(patsubst $(SQR100_HW)/%.c,$(SQR100_OBJ_DIR)/%.o,$(SQR100_C_SRCS))

LIBUSB_CFLAGS := $(shell pkg-config --cflags libusb-1.0 2>/dev/null)
LIBUSB_LIBS := $(shell pkg-config --libs libusb-1.0 2>/dev/null)
LIBUSB_LIBDIR := $(shell pkg-config --variable=libdir libusb-1.0 2>/dev/null)

.PHONY: all bundle sqr100 host test test-sqr100 info clean

all: bundle sqr100 host

bundle: $(SAMPLE_EXEC)

$(SAMPLE_EXEC): samples/sample_driver/SampleUSBDriver.m samples/sample_driver/Info.plist samples/sample_driver/MBD_SampleUSB.ChSet.plist include/MacBonDriver.h
	mkdir -p "$(SAMPLE_BUNDLE)/Contents/MacOS" "$(SAMPLE_BUNDLE)/Contents/Resources"
	$(CC) -bundle $(OBJC_FLAGS) $(FRAMEWORKS) samples/sample_driver/SampleUSBDriver.m -o "$(SAMPLE_EXEC)"
	cp samples/sample_driver/Info.plist "$(SAMPLE_BUNDLE)/Contents/Info.plist"
	cp samples/sample_driver/MBD_SampleUSB.ChSet.plist "$(SAMPLE_BUNDLE)/Contents/Resources/MBD_SampleUSB.ChSet.plist"

$(SQR100_OBJ_DIR)/%.o: $(SQR100_HW)/%.c
	mkdir -p "$(SQR100_OBJ_DIR)"
	$(CC) -std=c11 -O2 -mmacosx-version-min=12.0 -fPIC -DPX4_MACOS_USERLAND -I"$(SQR100_HW)" $(LIBUSB_CFLAGS) -c "$<" -o "$@"

sqr100: $(SQR100_EXEC)

$(SQR100_EXEC): $(SQR100_C_OBJS) $(SQR100_DIR)/SQR100Driver.mm $(SQR100_DIR)/Info.plist $(SQR100_DIR)/MBD_SQR100.ChSet.plist $(SQR100_DIR)/it930x-firmware.bin include/MacBonDriver.h
	@test -n "$(LIBUSB_LIBS)" || { echo "libusb-1.0 is required to build MBD_SQR100.bundle (brew install libusb pkg-config)." >&2; exit 1; }
	mkdir -p "$(SQR100_BUNDLE)/Contents/MacOS" "$(SQR100_BUNDLE)/Contents/Resources/firmware"
	$(CXX) -bundle $(OBJCXX_FLAGS) -DPX4_MACOS_USERLAND -I"$(SQR100_HW)" $(LIBUSB_CFLAGS) \
	    $(FRAMEWORKS) $(SQR100_DIR)/SQR100Driver.mm $(SQR100_C_OBJS) \
	    $(LIBUSB_LIBS) -Wl,-rpath,$(LIBUSB_LIBDIR) -lpthread -o "$(SQR100_EXEC)"
	cp $(SQR100_DIR)/Info.plist "$(SQR100_BUNDLE)/Contents/Info.plist"
	cp $(SQR100_DIR)/MBD_SQR100.ChSet.plist "$(SQR100_BUNDLE)/Contents/Resources/MBD_SQR100.ChSet.plist"
	cp $(SQR100_DIR)/it930x-firmware.bin "$(SQR100_BUNDLE)/Contents/Resources/firmware/it930x-firmware.bin"

host: $(HOST_BIN)

$(HOST_BIN): samples/sample_host/main.m include/MacBonDriver.h
	mkdir -p "$(BUILD_DIR)"
	$(CC) $(OBJC_FLAGS) $(FRAMEWORKS) samples/sample_host/main.m -o "$(HOST_BIN)"

test: bundle host
	./$(HOST_BIN) --conformance "$(SAMPLE_BUNDLE)"

test-sqr100: sqr100 host
	./$(HOST_BIN) --conformance "$(SQR100_BUNDLE)"

info: bundle sqr100 host
	./$(HOST_BIN) --info "$(SAMPLE_BUNDLE)"
	@echo ""
	./$(HOST_BIN) --info "$(SQR100_BUNDLE)"

clean:
	rm -rf "$(BUILD_DIR)"
