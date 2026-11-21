// SPDX-License-Identifier: GPL-2.0-only
#include "usb.h"

int sqr100_usb_open(libusb_context *context, struct usb_device *usb)
{
	usb->handle = libusb_open_device_with_vid_pid(context, 0x06b8, 0x106b);
	if (!usb->handle) {
		fprintf(stderr, "USB 06b8:106b を開けません。\n");
		return -ENODEV;
	}
	int status = libusb_claim_interface(usb->handle, 0);
	if (status != 0) {
		fprintf(stderr, "USB interface 0: %s\n", libusb_error_name(status));
		libusb_close(usb->handle);
		return -EIO;
	}
	return 0;
}

void sqr100_usb_close(struct usb_device *usb)
{
	libusb_release_interface(usb->handle, 0);
	libusb_close(usb->handle);
}

static int transfer(struct itedtv_bus *bus, unsigned char endpoint,
		    void *buffer, int capacity, int *length, unsigned timeout)
{
	*length = 0;
	int status = libusb_bulk_transfer(bus->usb.dev->handle, endpoint,
					  buffer, capacity, length, timeout);
	switch (status) {
	case LIBUSB_SUCCESS: return 0;
	case LIBUSB_ERROR_TIMEOUT: return -ETIMEDOUT;
	case LIBUSB_ERROR_NO_DEVICE: return -ENODEV;
	case LIBUSB_ERROR_INTERRUPTED: return -EINTR;
	default:
		fprintf(stderr, "USB endpoint %02x: %s\n", endpoint, libusb_error_name(status));
		return -EIO;
	}
}

static int control_out(struct itedtv_bus *bus, void *buffer, int length)
{
	int sent;
	int ret = transfer(bus, 0x02, buffer, length, &sent, bus->usb.ctrl_timeout);
	return ret ? ret : sent == length ? 0 : -EIO;
}

static int control_in(struct itedtv_bus *bus, void *buffer, int *length)
{
	return transfer(bus, 0x81, buffer, *length, length, bus->usb.ctrl_timeout);
}

static int stream_in(struct itedtv_bus *bus, void *buffer, int *length, int timeout)
{
	return transfer(bus, 0x84, buffer, *length, length, timeout);
}

int itedtv_bus_init(struct itedtv_bus *bus)
{
	bus->usb.max_bulk_size = libusb_get_max_packet_size(
		libusb_get_device(bus->usb.dev->handle), 0x84);
	if (bus->usb.max_bulk_size < 0)
		return -EIO;

	bus->ops.ctrl_tx = control_out;
	bus->ops.ctrl_rx = control_in;
	bus->ops.stream_rx = stream_in;
	return 0;
}

int itedtv_bus_term(struct itedtv_bus *bus)
{
	bus->ops = (struct itedtv_bus_operations){0};
	return 0;
}

int request_firmware(const struct firmware **fw, const char *path, struct device *dev)
{
	(void)dev;
	FILE *file = fopen(path, "rb");
	if (!file)
		return -errno;

	int ret = -EIO;
	if (fseek(file, 0, SEEK_END) != 0)
		goto close;
	long size = ftell(file);
	if (size <= 0 || fseek(file, 0, SEEK_SET) != 0)
		goto close;

	struct firmware *image = malloc(sizeof(*image) + (size_t)size);
	if (!image) {
		ret = -ENOMEM;
		goto close;
	}
	u8 *data = (u8 *)(image + 1);
	if (fread(data, 1, (size_t)size, file) != (size_t)size) {
		free(image);
		goto close;
	}

	/* IT930x のローダーに渡す前に、全ブロックの境界を検証する。 */
	size_t offset = 0;
	while (offset < (size_t)size) {
		size_t remaining = (size_t)size - offset;
		const u8 *block = data + offset;
		if (remaining < 4 || block[0] != 3)
			break;
		size_t header = 4 + 3 * block[3];
		if (header > remaining)
			break;
		size_t payload = 0;
		for (size_t i = 6; i < header; i += 3)
			payload += block[i];
		if (!payload || payload > remaining - header || header + payload > UINT8_MAX)
			break;
		offset += header + payload;
	}
	if (offset != (size_t)size) {
		free(image);
		ret = -EBADMSG;
		goto close;
	}
	image->size = (size_t)size;
	image->data = data;
	*fw = image;
	ret = 0;
close:
	fclose(file);
	return ret;
}

void release_firmware(const struct firmware *fw)
{
	free((void *)fw);
}
