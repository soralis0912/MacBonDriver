// SPDX-License-Identifier: GPL-2.0-only
#pragma once

#include <libusb.h>
#include "itedtv_bus.h"

struct usb_device {
	libusb_device_handle *handle;
};

int sqr100_usb_open(libusb_context *context, struct usb_device *usb);
void sqr100_usb_close(struct usb_device *usb);
