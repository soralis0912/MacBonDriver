CC := xcrun clang
CFLAGS := -fobjc-arc -mmacosx-version-min=12.0 -Wall -Wextra -Werror -O2 -Iinclude
FRAMEWORKS := -framework Foundation

BUILD_DIR := build
SAMPLE_BUNDLE := $(BUILD_DIR)/MBD_SampleUSB.bundle
SAMPLE_EXEC := $(SAMPLE_BUNDLE)/Contents/MacOS/MBD_SampleUSB
HOST_BIN := $(BUILD_DIR)/mbd-host

.PHONY: all bundle host test info clean

all: bundle host

bundle: $(SAMPLE_EXEC)

$(SAMPLE_EXEC): samples/sample_driver/SampleUSBDriver.m samples/sample_driver/Info.plist samples/sample_driver/MBD_SampleUSB.ChSet.plist include/MacBonDriver.h
	mkdir -p "$(SAMPLE_BUNDLE)/Contents/MacOS" "$(SAMPLE_BUNDLE)/Contents/Resources"
	$(CC) -bundle $(CFLAGS) $(FRAMEWORKS) samples/sample_driver/SampleUSBDriver.m -o "$(SAMPLE_EXEC)"
	cp samples/sample_driver/Info.plist "$(SAMPLE_BUNDLE)/Contents/Info.plist"
	cp samples/sample_driver/MBD_SampleUSB.ChSet.plist "$(SAMPLE_BUNDLE)/Contents/Resources/MBD_SampleUSB.ChSet.plist"

host: $(HOST_BIN)

$(HOST_BIN): samples/sample_host/main.m include/MacBonDriver.h
	mkdir -p "$(BUILD_DIR)"
	$(CC) $(CFLAGS) $(FRAMEWORKS) samples/sample_host/main.m -o "$(HOST_BIN)"

test: all
	./$(HOST_BIN) --conformance "$(SAMPLE_BUNDLE)"

info: all
	./$(HOST_BIN) --info "$(SAMPLE_BUNDLE)"

clean:
	rm -rf "$(BUILD_DIR)"
