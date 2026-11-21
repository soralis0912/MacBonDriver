// SPDX-License-Identifier: GPL-2.0-only
#pragma once

#include <errno.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef int8_t s8;
typedef int16_t s16;
typedef int32_t s32;
typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;

struct device {
	const char *name;
};

struct firmware {
	size_t size;
	const u8 *data;
};

int request_firmware(const struct firmware **fw, const char *path, struct device *dev);
void release_firmware(const struct firmware *fw);

struct mutex {
	pthread_mutex_t handle;
};

static inline void mutex_init(struct mutex *lock) { pthread_mutex_init(&lock->handle, NULL); }
static inline void mutex_destroy(struct mutex *lock) { pthread_mutex_destroy(&lock->handle); }
static inline void mutex_lock(struct mutex *lock) { pthread_mutex_lock(&lock->handle); }
static inline void mutex_unlock(struct mutex *lock) { pthread_mutex_unlock(&lock->handle); }

static inline void msleep(unsigned ms)
{
	struct timespec delay = {ms / 1000, (long)(ms % 1000) * 1000000};
	while (nanosleep(&delay, &delay) < 0 && errno == EINTR) {}
}

#define ARRAY_SIZE(array) (sizeof(array) / sizeof((array)[0]))
#define kmalloc(size, flags) malloc(size)
#define kzalloc(size, flags) calloc(1, size)
#define kfree(ptr) free(ptr)
#define dev_info(dev, ...) fprintf(stderr, __VA_ARGS__)
#define dev_err(dev, ...) fprintf(stderr, __VA_ARGS__)
#define dev_warn(dev, ...) fprintf(stderr, __VA_ARGS__)
#define dev_dbg(dev, ...) do {} while (0)
