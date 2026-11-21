// SPDX-License-Identifier: GPL-2.0-only
// SQR100Driver.mm — PIXELA XIT-SQR100 MacBonDriver (.bundle) implementation
//
// Hardware: ITE IT9303FN USB bridge (06b8:106b) + Sony CXD2856ER demodulator
//           + Sony CXD6866AER tuner + IT930x UART built-in smart card reader.
// Supports: ISDB-C (J.83 Annex C + TSMF), ISDB-T (UHF / CATV), ISDB-S (BS/CS),
//           and direct ISO/IEC 7816-4 APDU access to the built-in B-CAS slot.

#import "MacBonDriver.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <iterator>
#include <pthread.h>
#include <thread>
#include <vector>

#include <libusb.h>

extern "C" {
#include "usb.h"
#include "it930x.h"
#include "cxd2856er.h"
#include "cxd6866.h"
#include "tsmf.h"
#include "ts_sync.h"
}
#include "cxd2856er_cn_table.hpp"

namespace {

constexpr uint16_t kSQR100VendorID = 0x06B8;
constexpr uint16_t kSQR100ProductID = 0x106B;
constexpr size_t kSyncPackets = 4;
constexpr size_t kSyncBytes = MBDTSPacketSize * kSyncPackets;
constexpr size_t kUSBReadSize = 32768;
constexpr NSUInteger kMaxQueueChunks = 64;

// ISO/IEC 7816-3 T=1 constants for IT930x UART smart card reader
constexpr uint8_t kT1NAD = 0x00;
constexpr uint8_t kT1IBlock = 0x00;
constexpr uint8_t kT1ISeq = 0x40;
constexpr uint8_t kT1IChain = 0x20;
constexpr uint8_t kT1RBlock = 0x80;
constexpr uint8_t kT1RSeq = 0x10;
constexpr uint8_t kT1SBlock = 0xC0;
constexpr uint8_t kT1SResp = 0x20;
constexpr uint8_t kT1SResynch = 0x00;
constexpr uint8_t kT1SIFS = 0x01;
constexpr uint8_t kT1SWTX = 0x03;
constexpr size_t kCardFrameMax = 255;
constexpr unsigned int kCardPollMs = 5;
constexpr unsigned int kCardATRTimeoutMs = 1000;
constexpr unsigned int kCardBlockTimeoutMs = 500;
constexpr unsigned int kCardOpTimeoutMs = 3000;
constexpr unsigned int kCardMaxRetries = 3;
constexpr int kCardNoMedium = -10001;

NSError *SQRMakeError(MBDErrorCode code, NSString *message, int osErr = 0) {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[NSLocalizedDescriptionKey] = message ?: @"XIT-SQR100 driver error";
    if (osErr != 0) {
        info[NSUnderlyingErrorKey] = [NSError errorWithDomain:NSPOSIXErrorDomain
                                                         code:(osErr < 0 ? -osErr : osErr)
                                                     userInfo:nil];
    }
    return [NSError errorWithDomain:MBDErrorDomain code:code userInfo:info];
}

uint16_t CalcCRC16(const uint8_t *data, size_t len) {
    uint16_t crc = 0xFFFF;
    for (size_t i = 0; i < len; i++) {
        uint16_t v = static_cast<uint16_t>(data[i]) << 8;
        for (int b = 0; b < 8; b++) {
            crc = ((crc ^ v) & 0x8000) ? static_cast<uint16_t>((crc << 1) ^ 0x1021)
                                       : static_cast<uint16_t>(crc << 1);
            v <<= 1;
        }
    }
    return crc;
}

struct SQRCardAtrParams {
    enum it930x_uart_baudrate baudrate = IT930X_UART_BAUDRATE_9600;
    uint8_t ifsc = 32;
    bool useCRC = false;
    unsigned int blockTimeoutMs = kCardBlockTimeoutMs;
};

int ParseATR(const std::vector<uint8_t> &atr, size_t &expectedLen, SQRCardAtrParams &params) {
    if (atr.size() < 2) return -EAGAIN;
    if (atr[0] != 0x3B && atr[0] != 0x3F) return -EBADMSG;

    uint8_t iface = atr[1] >> 4;
    const size_t histLen = atr[1] & 0x0F;
    size_t off = 2;
    unsigned int group = 1;
    bool nonT0 = false;
    bool t1Group = false;
    params = SQRCardAtrParams{};

    while (iface) {
        uint8_t ta = 0, tb = 0, tc = 0;
        bool hasTA = false, hasTB = false, hasTC = false;
        if (iface & 0x01) { if (off >= atr.size()) return -EAGAIN; ta = atr[off++]; hasTA = true; }
        if (iface & 0x02) { if (off >= atr.size()) return -EAGAIN; tb = atr[off++]; hasTB = true; }
        if (iface & 0x04) { if (off >= atr.size()) return -EAGAIN; tc = atr[off++]; hasTC = true; }

        if (group == 1 && hasTA) {
            switch (ta) {
            case 0x11: params.baudrate = IT930X_UART_BAUDRATE_9600; break;
            case 0x12: params.baudrate = IT930X_UART_BAUDRATE_19200; break;
            case 0x13: params.baudrate = IT930X_UART_BAUDRATE_38400; break;
            default: return -EOPNOTSUPP;
            }
        }
        if (t1Group && group >= 3) {
            if (hasTA && ta >= 1 && ta <= 254) params.ifsc = ta;
            if (hasTB) {
                unsigned int bwi = tb >> 4;
                unsigned int bwt = bwi < 5 ? (100U << bwi) : kCardOpTimeoutMs;
                params.blockTimeoutMs = std::min(kCardOpTimeoutMs, std::max(kCardBlockTimeoutMs, bwt));
            }
            if (hasTC) params.useCRC = (tc & 0x01) != 0;
        }
        if (iface & 0x08) {
            if (off >= atr.size()) return -EAGAIN;
            uint8_t td = atr[off++];
            uint8_t proto = td & 0x0F;
            nonT0 = nonT0 || (proto != 0);
            t1Group = (proto == 1);
            iface = td >> 4;
            group++;
        } else {
            iface = 0;
        }
    }

    expectedLen = off + histLen + (nonT0 ? 1 : 0);
    if (expectedLen > 33) return -EBADMSG;
    if (atr.size() < expectedLen) return -EAGAIN;
    if (atr.size() > expectedLen) return -EBADMSG;

    if (nonT0) {
        uint8_t x = 0;
        for (size_t i = 1; i < atr.size(); i++) x ^= atr[i];
        if (x != 0) return -EBADMSG;
    }
    return 0;
}

MBDBroadcastSystem ParseSystemString(NSString *sysStr) {
    if ([sysStr isEqualToString:@"ISDB-T"]) return MBDBroadcastSystemISDBT;
    if ([sysStr isEqualToString:@"ISDB-S"]) return MBDBroadcastSystemISDBS;
    if ([sysStr isEqualToString:@"ISDB-C"]) return MBDBroadcastSystemISDBC;
    if ([sysStr isEqualToString:@"ISDB-S3"]) return MBDBroadcastSystemISDBS3;
    return MBDBroadcastSystemUnspecified;
}

} // namespace

@interface MBDSQR100Driver : NSObject <
    MacBonDriver,
    MacBonDriverMultiTuner,
    MacBonDriverLNBControl,
    MacBonDriverTSMF,
    MacBonDriverSmartCard
>
@end

@implementation MBDSQR100Driver {
    NSBundle *_bundle;
    NSArray<NSDictionary<NSString *, id> *> *_spaces;
    NSURL *_firmwareDirOverride;
    NSUInteger _deviceIndex;

    // Locks: _hwLock guards USB/bridge/demod/tuner/card control operations.
    // _streamLock guards TS chunk queue and stream condition variable.
    pthread_mutex_t _hwLock;
    pthread_mutex_t _streamLock;
    pthread_cond_t _streamCond;

    // Hardware state
    libusb_context *_usbCtx;
    struct usb_device _usbDev;
    struct device _devDesc;
    struct it930x_bridge _bridge;
    struct cxd2856er_demod _demod;
    struct cxd6866_tuner _tuner;
    BOOL _hwOpen;
    BOOL _backendPowered;
    BOOL _tunerOpen;
    BOOL _demodReady;
    BOOL _tunerReady;
    BOOL _cardOpen;

    // Active tuning state
    NSUInteger _currentSpace;
    NSUInteger _currentChannel;
    MBDBroadcastSystem _currentSystem;
    uint16_t _currentStreamID;
    BOOL _useTSMFFilter;
    BOOL _lastLocked;
    float _cachedCNR;
    std::chrono::steady_clock::time_point _lastStatTime;

    // Streaming thread & TS ring queue
    std::atomic<bool> _streaming;
    std::atomic<bool> _streamFatalError;
    pthread_t _streamThread;
    BOOL _streamThreadValid;
    struct tsmf_filter _tsmfFilter;
    uint8_t _syncRemain[kSyncBytes];
    size_t _syncRemainLen;

    NSMutableArray<NSData *> *_chunkQueue;
    NSData *_activeChunk;
    uint64_t _droppedChunks;
    uint64_t _usbErrorCount;
    uint32_t _streamEpoch;

    // Built-in smart card T=1 session state (protected by _hwLock)
    BOOL _cardInitialized;
    bool _cardUseCRC;
    uint8_t _cardIFSC;
    unsigned int _cardBlockTimeoutMs;
    uint8_t _cardSendSeq;
    uint8_t _cardRecvSeq;
    std::vector<uint8_t> _cardATR;
}

@synthesize delegate = _delegate;

+ (NSUInteger)apiVersion {
    return MacBonDriverAPIVersion;
}

+ (nullable instancetype)driverWithBundle:(NSBundle *)bundle
                                  options:(nullable NSDictionary<MBDDriverOptionKey, id> *)options
                                    error:(NSError * _Nullable * _Nullable)error {
    return [[self alloc] initWithBundle:bundle options:options error:error];
}

- (nullable instancetype)initWithBundle:(NSBundle *)bundle
                                options:(nullable NSDictionary<MBDDriverOptionKey, id> *)options
                                  error:(NSError * _Nullable * _Nullable)error {
    self = [super init];
    if (!self) return nil;

    _bundle = bundle ?: [NSBundle bundleForClass:[self class]];
    _currentSpace = MBDInvalidIndex;
    _currentChannel = MBDInvalidIndex;
    _currentSystem = MBDBroadcastSystemUnspecified;
    _currentStreamID = 0;
    _chunkQueue = [NSMutableArray arrayWithCapacity:kMaxQueueChunks];
    _cardIFSC = 32;
    _cardBlockTimeoutMs = kCardBlockTimeoutMs;
    _streaming.store(false);
    _streamFatalError.store(false);

    pthread_mutexattr_t attr;
    pthread_mutexattr_init(&attr);
    pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
    pthread_mutex_init(&_hwLock, &attr);
    pthread_mutexattr_destroy(&attr);

    pthread_mutex_init(&_streamLock, NULL);
    pthread_cond_init(&_streamCond, NULL);

    NSNumber *devIdx = options[MBDOptionDeviceIndexKey];
    _deviceIndex = devIdx ? devIdx.unsignedIntegerValue : 0;

    id fwOpt = options[MBDOptionFirmwareDirectoryURLKey];
    if ([fwOpt isKindOfClass:[NSURL class]]) {
        _firmwareDirOverride = fwOpt;
    } else if ([fwOpt isKindOfClass:[NSString class]]) {
        _firmwareDirOverride = [NSURL fileURLWithPath:fwOpt];
    }

    if (![self loadChannelSetWithOptions:options error:error]) {
        return nil;
    }
    return self;
}

- (void)dealloc {
    [self closeTuner];
    [self closeSmartCard];
    pthread_cond_destroy(&_streamCond);
    pthread_mutex_destroy(&_streamLock);
    pthread_mutex_destroy(&_hwLock);
}

#pragma mark - Configuration & Firmware Lookup

- (BOOL)loadChannelSetWithOptions:(nullable NSDictionary<MBDDriverOptionKey, id> *)options
                            error:(NSError * _Nullable * _Nullable)error {
    NSURL *chSetURL = nil;
    id customConfig = options[MBDOptionConfigURLKey];
    if ([customConfig isKindOfClass:[NSURL class]]) {
        chSetURL = customConfig;
    } else if ([customConfig isKindOfClass:[NSString class]]) {
        chSetURL = [NSURL fileURLWithPath:customConfig];
    }

    if (!chSetURL) {
        NSString *driverID = _bundle.infoDictionary[MBDInfoDriverIdentifierKey] ?: @"jp.macbondriver.sqr100";
        NSString *cfgName = _bundle.infoDictionary[MBDInfoConfigFileNameKey] ?: @"MBD_SQR100";
        NSString *userPath = [[NSHomeDirectory()
            stringByAppendingPathComponent:@"Library/Application Support/MacBonDriver"]
            stringByAppendingPathComponent:[NSString stringWithFormat:@"%@/%@.ChSet.plist", driverID, cfgName]];
        if ([[NSFileManager defaultManager] fileExistsAtPath:userPath]) {
            chSetURL = [NSURL fileURLWithPath:userPath];
        }
    }
    if (!chSetURL) {
        chSetURL = [_bundle URLForResource:@"MBD_SQR100.ChSet" withExtension:@"plist"];
    }
    if (!chSetURL) {
        if (error) *error = SQRMakeError(MBDErrorConfigInvalid, @"MBD_SQR100.ChSet.plist not found");
        return NO;
    }

    NSDictionary *root = [NSDictionary dictionaryWithContentsOfURL:chSetURL];
    NSArray *spaces = root[@"Spaces"];
    if (![spaces isKindOfClass:[NSArray class]] || spaces.count == 0) {
        if (error) *error = SQRMakeError(MBDErrorConfigInvalid, @"Invalid MBD_SQR100.ChSet.plist");
        return NO;
    }
    _spaces = [spaces copy];
    return YES;
}

- (nullable NSString *)resolveFirmwarePath {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (_firmwareDirOverride) {
        NSString *p = [_firmwareDirOverride URLByAppendingPathComponent:@"it930x-firmware.bin"].path;
        if ([fm fileExistsAtPath:p]) return p;
    }
    NSURL *bundled = [_bundle URLForResource:@"it930x-firmware"
                               withExtension:@"bin"
                                subdirectory:@"firmware"];
    if (bundled && [fm fileExistsAtPath:bundled.path]) {
        return bundled.path;
    }
    NSString *userFw = [NSHomeDirectory()
        stringByAppendingPathComponent:@"Library/Application Support/MacBonDriver/firmware/it930x-firmware.bin"];
    if ([fm fileExistsAtPath:userFw]) return userFw;
    return nil;
}

#pragma mark - Shared Hardware Bridge & Backend Power

- (int)setBackendPowerLocked:(BOOL)enable {
    if (enable) {
        if (_backendPowered) return 0;
        int ret = it930x_write_gpio(&_bridge, 5, true);
        if (ret) return ret;
        msleep(50);
        ret = it930x_write_gpio(&_bridge, 2, false);
        if (ret) return ret;
        msleep(100);
        ret = it930x_write_gpio(&_bridge, 2, true);
        if (ret) return ret;
        msleep(20);
        _backendPowered = YES;
        return 0;
    } else {
        if (!_backendPowered) return 0;
        int r1 = it930x_write_gpio(&_bridge, 5, false);
        int r2 = it930x_write_gpio(&_bridge, 2, false);
        _backendPowered = NO;
        return r1 ? r1 : r2;
    }
}

- (BOOL)ensureHardwareOpenLocked:(NSError * _Nullable * _Nullable)error {
    if (_hwOpen) return YES;

    NSString *fwPath = [self resolveFirmwarePath];
    if (!fwPath) {
        if (error) *error = SQRMakeError(MBDErrorFirmwareMissing, @"it930x-firmware.bin not found");
        return NO;
    }

    int ret = libusb_init(&_usbCtx);
    if (ret != 0) {
        if (error) *error = SQRMakeError(MBDErrorUSBTransferFailed, @"libusb_init failed", ret);
        return NO;
    }

    memset(&_usbDev, 0, sizeof(_usbDev));
    ret = sqr100_usb_open(_usbCtx, &_usbDev);
    if (ret != 0) {
        libusb_exit(_usbCtx);
        _usbCtx = NULL;
        if (error) {
            MBDErrorCode code = (ret == -ENODEV) ? MBDErrorDeviceNotFound : MBDErrorDeviceBusy;
            *error = SQRMakeError(code, @"Failed to open XIT-SQR100 USB device (06b8:106b)", ret);
        }
        return NO;
    }

    _devDesc.name = "XIT-SQR100";
    memset(&_bridge, 0, sizeof(_bridge));
    _bridge.dev = &_devDesc;
    _bridge.bus.dev = &_devDesc;
    _bridge.bus.type = ITEDTV_BUS_USB;
    _bridge.bus.usb.dev = &_usbDev;
    _bridge.bus.usb.ctrl_timeout = 3000;
    _bridge.config.xfer_size = 188 * 816;
    _bridge.config.i2c_speed = 7;
    _bridge.bcas_is_extend = true;
    for (size_t i = 0; i < 5; i++) {
        _bridge.config.input[i].port_number = (u8)i;
    }
    _bridge.config.input[0].enable = true;
    _bridge.config.input[0].is_parallel = false;
    _bridge.config.input[0].i2c_bus = 3;
    _bridge.config.input[0].i2c_addr = 0x64;
    _bridge.config.input[0].packet_len = 188;
    _bridge.config.input[0].sync_byte = 0x47;

    ret = itedtv_bus_init(&_bridge.bus);
    if (!ret) ret = it930x_init(&_bridge);
    if (!ret) ret = it930x_raise(&_bridge);
    if (!ret) ret = it930x_load_firmware(&_bridge, fwPath.fileSystemRepresentation);
    if (!ret) ret = it930x_init_warm(&_bridge);

    const int pins[] = {5, 2, 7};
    for (size_t i = 0; !ret && i < 3; i++) {
        ret = it930x_set_gpio_mode(&_bridge, pins[i], IT930X_GPIO_OUT, true);
        if (!ret) ret = it930x_write_gpio(&_bridge, pins[i], pins[i] == 7);
    }

    if (ret != 0) {
        it930x_term(&_bridge);
        itedtv_bus_term(&_bridge.bus);
        sqr100_usb_close(&_usbDev);
        libusb_exit(_usbCtx);
        _usbCtx = NULL;
        if (error) *error = SQRMakeError(MBDErrorFirmwareLoadFailed, @"IT9303FN bridge initialization failed", ret);
        return NO;
    }

    _hwOpen = YES;
    return YES;
}

- (void)releaseHardwareIfUnusedLocked {
    if (_tunerOpen || _cardOpen || !_hwOpen) return;
    [self setBackendPowerLocked:NO];
    it930x_term(&_bridge);
    itedtv_bus_term(&_bridge.bus);
    sqr100_usb_close(&_usbDev);
    if (_usbCtx) {
        libusb_exit(_usbCtx);
        _usbCtx = NULL;
    }
    _hwOpen = NO;
}

#pragma mark - MacBonDriver Core

- (NSString *)tunerName {
    NSString *display = _bundle.infoDictionary[MBDInfoDisplayNameKey];
    return display ?: @"PIXELA XIT-SQR100 (ISDB-T/S/C)";
}

- (BOOL)isTunerOpen {
    pthread_mutex_lock(&_hwLock);
    BOOL open = _tunerOpen;
    pthread_mutex_unlock(&_hwLock);
    return open;
}

- (NSUInteger)currentSpace {
    pthread_mutex_lock(&_hwLock);
    NSUInteger s = _currentSpace;
    pthread_mutex_unlock(&_hwLock);
    return s;
}

- (NSUInteger)currentChannel {
    pthread_mutex_lock(&_hwLock);
    NSUInteger c = _currentChannel;
    pthread_mutex_unlock(&_hwLock);
    return c;
}

- (float)signalLevel {
    pthread_mutex_lock(&_hwLock);
    if (!_tunerOpen || _currentSpace == MBDInvalidIndex || _currentChannel == MBDInvalidIndex) {
        pthread_mutex_unlock(&_hwLock);
        return 0.0f;
    }

    auto now = std::chrono::steady_clock::now();
    auto elapsedMs = std::chrono::duration_cast<std::chrono::milliseconds>(now - _lastStatTime).count();
    if (elapsedMs < 250 && _lastStatTime.time_since_epoch().count() > 0) {
        float cached = _cachedCNR;
        pthread_mutex_unlock(&_hwLock);
        return cached;
    }

    float cnr = 0.0f;
    if (_currentSystem == MBDBroadcastSystemISDBT) {
        u16 raw = 0;
        if (cxd2856er_read_cnr_raw_isdbt(&_demod, &raw) == 0 && raw > 0) {
            cnr = (float)(std::log10((double)raw) * 10.0 - 9.031);
            if (cnr < 0.0f) cnr = 0.0f;
        }
    } else if (_currentSystem == MBDBroadcastSystemISDBS) {
        u16 raw = 0;
        if (cxd2856er_read_cnr_raw_isdbs(&_demod, &raw) == 0) {
            auto it = std::lower_bound(std::begin(px4::cxd2856er_isdbs_cn_table),
                                       std::end(px4::cxd2856er_isdbs_cn_table),
                                       raw,
                                       [](const px4::Cxd2856erCnTableIsdbS &entry, u16 sample) {
                                           return entry.val > sample;
                                       });
            if (it == std::end(px4::cxd2856er_isdbs_cn_table)) --it;
            cnr = (float)it->cnr / 1000.0f;
        }
    } else if (_currentSystem == MBDBroadcastSystemISDBC) {
        bool locked = false;
        if (cxd2856er_is_ts_locked_isdbc(&_demod, &locked) == 0) {
            _lastLocked = locked ? YES : NO;
            cnr = locked ? 30.0f : 0.0f;
        }
    }

    _cachedCNR = cnr;
    _lastStatTime = now;
    pthread_mutex_unlock(&_hwLock);
    return cnr;
}

- (BOOL)openTunerWithError:(NSError * _Nullable * _Nullable)error {
    pthread_mutex_lock(&_hwLock);
    if (_tunerOpen) {
        pthread_mutex_unlock(&_hwLock);
        if (error) *error = SQRMakeError(MBDErrorAlreadyOpen, @"XIT-SQR100 tuner is already open");
        return NO;
    }

    if (![self ensureHardwareOpenLocked:error]) {
        pthread_mutex_unlock(&_hwLock);
        return NO;
    }

    int ret = [self setBackendPowerLocked:YES];
    if (ret != 0) {
        [self releaseHardwareIfUnusedLocked];
        pthread_mutex_unlock(&_hwLock);
        if (error) *error = SQRMakeError(MBDErrorUSBTransferFailed, @"Failed to power on tuner backend", ret);
        return NO;
    }

    memset(&_demod, 0, sizeof(_demod));
    _demod.dev = &_devDesc;
    _demod.i2c = &_bridge.i2c_master[2];
    _demod.i2c_addr.slvx = 0x66;
    _demod.i2c_addr.slvt = 0x64;
    _demod.config.xtal = 24000;
    _demod.config.tuner_i2c = true;
    _demod.config.serial_ts_clock = true;

    memset(&_tuner, 0, sizeof(_tuner));
    _tuner.dev = &_devDesc;
    _tuner.i2c = &_demod.i2c_master;
    _tuner.i2c_addr = 0x60;
    _tuner.config.xtal = 24000;
    _tuner.config.loop_filter_internal = true;
    _tuner.config.refout_enable = true;

    _demodReady = NO;
    _tunerReady = NO;

    ret = cxd2856er_init(&_demod);
    if (!ret) {
        _demodReady = YES;
        ret = cxd2856er_write_slvx_reg(&_demod, 0x08, 1);
    }
    if (!ret) {
        ret = cxd6866_init(&_tuner);
        _tunerReady = (ret == 0);
    }
    if (!ret) ret = cxd2856er_write_slvx_reg(&_demod, 0x08, 0);
    if (!ret) ret = cxd2856er_write_slvt_reg(&_demod, 0x00, 0);
    if (!ret) ret = cxd2856er_write_slvt_reg_mask(&_demod, 0xC4, 0x80, 0x88);
    if (!ret) ret = cxd2856er_write_slvt_reg(&_demod, 0x00, 0xA0);
    if (!ret) ret = cxd2856er_write_slvt_reg_mask(&_demod, 0xB9, 1, 1);

    if (ret != 0) {
        if (_tunerReady) { cxd6866_term(&_tuner); _tunerReady = NO; }
        if (_demodReady) { cxd2856er_term(&_demod); _demodReady = NO; }
        [self releaseHardwareIfUnusedLocked];
        pthread_mutex_unlock(&_hwLock);
        if (error) *error = SQRMakeError(MBDErrorUSBTransferFailed, @"CXD2856ER/CXD6866 initialization failed", ret);
        return NO;
    }

    _tunerOpen = YES;
    _currentSpace = MBDInvalidIndex;
    _currentChannel = MBDInvalidIndex;
    _currentSystem = MBDBroadcastSystemUnspecified;
    _currentStreamID = 0;
    _lastLocked = NO;
    _cachedCNR = 0.0f;
    _streamFatalError.store(false);

    pthread_mutex_lock(&_streamLock);
    [_chunkQueue removeAllObjects];
    _activeChunk = nil;
    _droppedChunks = 0;
    _usbErrorCount = 0;
    _streamEpoch++;
    pthread_mutex_unlock(&_streamLock);

    pthread_mutex_unlock(&_hwLock);
    return YES;
}

- (void)stopStreamThread {
    _streaming.store(false);
    if (_streamThreadValid) {
        pthread_join(_streamThread, NULL);
        _streamThreadValid = NO;
    }
}

- (void)closeTuner {
    [self stopStreamThread];

    pthread_mutex_lock(&_hwLock);
    if (_tunerOpen) {
        if (_tunerReady) { cxd6866_term(&_tuner); _tunerReady = NO; }
        if (_demodReady) { cxd2856er_term(&_demod); _demodReady = NO; }
        _tunerOpen = NO;
        _currentSpace = MBDInvalidIndex;
        _currentChannel = MBDInvalidIndex;
        _currentSystem = MBDBroadcastSystemUnspecified;
        _currentStreamID = 0;
        _lastLocked = NO;
        _cachedCNR = 0.0f;
        [self releaseHardwareIfUnusedLocked];
    }

    pthread_mutex_lock(&_streamLock);
    [_chunkQueue removeAllObjects];
    _activeChunk = nil;
    _streamEpoch++;
    pthread_cond_broadcast(&_streamCond);
    pthread_mutex_unlock(&_streamLock);

    pthread_mutex_unlock(&_hwLock);
}

- (nullable NSString *)tuningSpaceNameAtIndex:(NSUInteger)space {
    if (space >= _spaces.count) return nil;
    return _spaces[space][@"Name"];
}

- (nullable NSString *)channelNameInSpace:(NSUInteger)space channel:(NSUInteger)channel {
    if (space >= _spaces.count) return nil;
    NSArray *channels = _spaces[space][@"Channels"];
    if (![channels isKindOfClass:[NSArray class]] || channel >= channels.count) return nil;
    return channels[channel][@"Name"];
}

- (BOOL)setSpace:(NSUInteger)space
         channel:(NSUInteger)channel
           error:(NSError * _Nullable * _Nullable)error {
    return [self setSpace:space channel:channel streamID:0 overrideStreamID:NO error:error];
}

- (BOOL)setSpace:(NSUInteger)space
         channel:(NSUInteger)channel
        streamID:(uint16_t)streamID
           error:(NSError * _Nullable * _Nullable)error {
    return [self setSpace:space channel:channel streamID:streamID overrideStreamID:YES error:error];
}

- (BOOL)setSpace:(NSUInteger)space
         channel:(NSUInteger)channel
        streamID:(uint16_t)streamID
overrideStreamID:(BOOL)overrideStreamID
           error:(NSError * _Nullable * _Nullable)error {
    // Stop capture thread outside _hwLock to prevent lock inversion
    [self stopStreamThread];

    pthread_mutex_lock(&_hwLock);
    if (!_tunerOpen) {
        pthread_mutex_unlock(&_hwLock);
        if (error) *error = SQRMakeError(MBDErrorNotOpen, @"Tuner is not open");
        return NO;
    }
    if (space >= _spaces.count) {
        pthread_mutex_unlock(&_hwLock);
        if (error) *error = SQRMakeError(MBDErrorInvalidSpaceOrChannel, @"Space index out of range");
        return NO;
    }
    NSDictionary *spaceDict = _spaces[space];
    NSArray *channels = spaceDict[@"Channels"];
    if (![channels isKindOfClass:[NSArray class]] || channel >= channels.count) {
        pthread_mutex_unlock(&_hwLock);
        if (error) *error = SQRMakeError(MBDErrorInvalidSpaceOrChannel, @"Channel index out of range");
        return NO;
    }

    NSDictionary *chDict = channels[channel];
    MBDBroadcastSystem sys = ParseSystemString(spaceDict[@"System"]);
    uint32_t freqKHz = [chDict[@"FrequencyKHz"] unsignedIntValue];
    uint32_t bwKHz = chDict[@"BandwidthKHz"] ? [chDict[@"BandwidthKHz"] unsignedIntValue] : 6000;
    uint16_t effectiveSID = overrideStreamID ? streamID : (uint16_t)[chDict[@"StreamID"] unsignedShortValue];

    MBDChannelFlags flags = MBDChannelFlagNone;
    for (NSString *f in chDict[@"Flags"]) {
        if ([f isEqualToString:@"TSMF"]) flags |= MBDChannelFlagTSMF;
        else if ([f isEqualToString:@"RawTSMF"]) flags |= MBDChannelFlagRawTSMF;
        else if ([f isEqualToString:@"CATV"]) flags |= MBDChannelFlagCATV;
    }

    union cxd2856er_system_params params = {};
    int ret = 0;
    if (sys == MBDBroadcastSystemISDBC) {
        params.isdbc_if_config = 0x12EEEF;
        ret = cxd2856er_wakeup(&_demod, CXD2856ER_ISDB_C_SYSTEM, &params);
        if (!ret) ret = cxd6866_set_params_t(&_tuner, CXD6866_ISDB_T_SYSTEM, freqKHz, 6);
    } else if (sys == MBDBroadcastSystemISDBT) {
        params.bandwidth = (bwKHz >= 7500) ? 8 : (bwKHz >= 6500 ? 7 : 6);
        ret = cxd2856er_wakeup(&_demod, CXD2856ER_ISDB_T_SYSTEM, &params);
        if (!ret) ret = cxd6866_set_params_t(&_tuner, CXD6866_ISDB_T_SYSTEM, freqKHz, 6);
    } else if (sys == MBDBroadcastSystemISDBS) {
        ret = cxd2856er_wakeup(&_demod, CXD2856ER_ISDB_S_SYSTEM, &params);
        if (!ret) ret = cxd6866_set_params_s(&_tuner, CXD6866_ISDB_S_SYSTEM, freqKHz, 28860);
        if (!ret) {
            ret = (effectiveSID < 12)
                ? cxd2856er_set_slot_isdbs(&_demod, effectiveSID)
                : cxd2856er_set_tsid_isdbs(&_demod, effectiveSID);
        }
    } else {
        pthread_mutex_unlock(&_hwLock);
        if (error) *error = SQRMakeError(MBDErrorUnsupported, @"Unsupported broadcast system");
        return NO;
    }

    if (!ret) ret = cxd2856er_post_tune(&_demod);
    if (ret != 0) {
        pthread_mutex_unlock(&_hwLock);
        if (error) *error = SQRMakeError(MBDErrorTuneFailed, @"Hardware tuning failed", ret);
        return NO;
    }

    // Poll TS lock briefly (up to 1.2s)
    bool locked = false;
    for (int attempt = 0; attempt < 12; attempt++) {
        bool unlocked = false;
        if (sys == MBDBroadcastSystemISDBC) {
            ret = cxd2856er_is_ts_locked_isdbc(&_demod, &locked);
        } else if (sys == MBDBroadcastSystemISDBT) {
            ret = cxd2856er_is_ts_locked_isdbt(&_demod, &locked, &unlocked);
        } else if (sys == MBDBroadcastSystemISDBS) {
            ret = cxd2856er_is_ts_locked_isdbs(&_demod, &locked);
        }
        if (ret != 0 || locked || unlocked) break;
        msleep(100);
    }

    int purgeRet = it930x_purge_psb(&_bridge, 1000);
    (void)purgeRet;

    _currentSpace = space;
    _currentChannel = channel;
    _currentSystem = sys;
    _currentStreamID = effectiveSID;
    _lastLocked = locked ? YES : NO;
    _lastStatTime = std::chrono::steady_clock::time_point{};
    _syncRemainLen = 0;
    _streamFatalError.store(false);

    _useTSMFFilter = (sys == MBDBroadcastSystemISDBC) &&
                     ((flags & MBDChannelFlagTSMF) != 0) &&
                     ((flags & MBDChannelFlagRawTSMF) == 0);
    if (_useTSMFFilter) {
        int streamIdx = (effectiveSID <= TSMF_STREAM_MAX) ? (int)effectiveSID : 0;
        tsmf_filter_init(&_tsmfFilter, streamIdx, false, 0);
    }

    pthread_mutex_lock(&_streamLock);
    [_chunkQueue removeAllObjects];
    _activeChunk = nil;
    _streamEpoch++;
    pthread_cond_broadcast(&_streamCond);
    pthread_mutex_unlock(&_streamLock);

    // Start USB bulk IN stream reader thread
    _streaming.store(true);
    if (pthread_create(&_streamThread, NULL, SQRStreamThreadEntry, (__bridge void *)self) == 0) {
        _streamThreadValid = YES;
    } else {
        _streaming.store(false);
    }

    pthread_mutex_unlock(&_hwLock);

    id<MacBonDriverDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:@selector(bonDriver:didReceiveEvent:userInfo:)]) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            [delegate bonDriver:self
                didReceiveEvent:MBDEventSignalLockChanged
                       userInfo:@{@"locked": @(locked), @"space": @(space), @"channel": @(channel)}];
        });
    }
    return YES;
}

#pragma mark - USB Stream Reader Thread

static void *SQRStreamThreadEntry(void *ctx) {
    @autoreleasepool {
        MBDSQR100Driver *driver = (__bridge MBDSQR100Driver *)ctx;
        [driver runStreamLoop];
    }
    return NULL;
}

- (void)enqueueAlignedTS:(const uint8_t *)bytes length:(size_t)length {
    if (length == 0 || (length % MBDTSPacketSize) != 0) return;

    NSData *chunk = nil;
    if (!_useTSMFFilter) {
        chunk = [NSData dataWithBytes:bytes length:length];
    } else {
        NSMutableData *filtered = [NSMutableData dataWithCapacity:length];
        for (size_t off = 0; off + MBDTSPacketSize <= length; off += MBDTSPacketSize) {
            const u8 *out = NULL;
            size_t outSize = tsmf_filter_packet(&_tsmfFilter, bytes + off, &out);
            if (outSize > 0 && out != _tsmfFilter.tlv_out && (outSize % MBDTSPacketSize) == 0) {
                [filtered appendBytes:out length:outSize];
            }
        }
        if (filtered.length == 0) return;
        chunk = filtered;
    }

    pthread_mutex_lock(&_streamLock);
    if (_chunkQueue.count >= kMaxQueueChunks) {
        [_chunkQueue removeObjectAtIndex:0];
        _droppedChunks++;
    }
    [_chunkQueue addObject:chunk];
    pthread_cond_signal(&_streamCond);
    pthread_mutex_unlock(&_streamLock);
}

- (void)runStreamLoop {
    std::vector<uint8_t> buf(kUSBReadSize + kSyncBytes);

    while (_streaming.load()) {
        if (_syncRemainLen > 0) {
            memcpy(buf.data(), _syncRemain, _syncRemainLen);
        }
        int received = (int)kUSBReadSize;
        int ret = itedtv_bus_stream_rx(&_bridge.bus, buf.data() + _syncRemainLen, &received, 250);
        if (!_streaming.load()) break;

        if (ret == -ETIMEDOUT || ret == -EINTR) {
            continue;
        }
        if (ret == -ENODEV) {
            _streamFatalError.store(true);
            pthread_mutex_lock(&_streamLock);
            _usbErrorCount++;
            pthread_cond_broadcast(&_streamCond);
            pthread_mutex_unlock(&_streamLock);

            id<MacBonDriverDelegate> delegate = self.delegate;
            if ([delegate respondsToSelector:@selector(bonDriver:didReceiveEvent:userInfo:)]) {
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                    [delegate bonDriver:self didReceiveEvent:MBDEventDeviceDisconnected userInfo:nil];
                });
            }
            break;
        }
        if (ret != 0) {
            pthread_mutex_lock(&_streamLock);
            _usbErrorCount++;
            pthread_mutex_unlock(&_streamLock);
            continue;
        }

        size_t total = _syncRemainLen + (size_t)received;
        size_t start = 0;
        while (total - start >= kSyncBytes &&
               !(px4_ts_has_plain_sync(buf[start]) &&
                 px4_ts_has_plain_sync(buf[start + 188]) &&
                 px4_ts_has_plain_sync(buf[start + 2 * 188]) &&
                 px4_ts_has_plain_sync(buf[start + 3 * 188]))) {
            start++;
        }

        size_t end = start;
        if (total - start >= kSyncBytes) {
            while (total - end >= MBDTSPacketSize && px4_ts_has_plain_sync(buf[end])) {
                end += MBDTSPacketSize;
            }
            if (end > start) {
                [self enqueueAlignedTS:buf.data() + start length:(end - start)];
            }
        }

        size_t rem = total - end;
        if (rem >= kSyncBytes) rem = kSyncBytes - 1;
        if (rem > 0) {
            memcpy(_syncRemain, buf.data() + (total - rem), rem);
        }
        _syncRemainLen = rem;
    }
}

#pragma mark - TS Stream Consumer Path

- (MBDWaitResult)waitTSStreamWithTimeoutMs:(uint32_t)timeoutMs {
    pthread_mutex_lock(&_streamLock);
    if (_streamFatalError.load()) {
        pthread_mutex_unlock(&_streamLock);
        return MBDWaitResultError;
    }
    if (!_tunerOpen) {
        pthread_mutex_unlock(&_streamLock);
        return MBDWaitResultClosed;
    }
    if (_chunkQueue.count > 0) {
        pthread_mutex_unlock(&_streamLock);
        return MBDWaitResultReady;
    }
    if (timeoutMs == 0) {
        pthread_mutex_unlock(&_streamLock);
        return MBDWaitResultTimeout;
    }

    uint32_t startEpoch = _streamEpoch;
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    uint64_t addNs = (uint64_t)timeoutMs * 1000000ULL;
    ts.tv_sec += (time_t)(addNs / 1000000000ULL);
    ts.tv_nsec += (long)(addNs % 1000000000ULL);
    if (ts.tv_nsec >= 1000000000L) {
        ts.tv_sec += 1;
        ts.tv_nsec -= 1000000000L;
    }

    int rc = 0;
    while (_tunerOpen && !_streamFatalError.load() && _streamEpoch == startEpoch && _chunkQueue.count == 0 && rc == 0) {
        rc = pthread_cond_timedwait(&_streamCond, &_streamLock, &ts);
    }

    MBDWaitResult res;
    if (_streamFatalError.load()) res = MBDWaitResultError;
    else if (!_tunerOpen || _streamEpoch != startEpoch) res = MBDWaitResultClosed;
    else if (_chunkQueue.count > 0) res = MBDWaitResultReady;
    else res = MBDWaitResultTimeout;

    pthread_mutex_unlock(&_streamLock);
    return res;
}

- (NSUInteger)readyStreamCount {
    pthread_mutex_lock(&_streamLock);
    NSUInteger c = _chunkQueue.count;
    pthread_mutex_unlock(&_streamLock);
    return c;
}

- (BOOL)getTSStreamChunk:(const uint8_t * _Nullable * _Nonnull)outBytes
                  length:(NSUInteger *)outLength
          remainingCount:(nullable NSUInteger *)outRemaining
                   error:(NSError * _Nullable * _Nullable)error {
    if (!outBytes || !outLength) {
        if (error) *error = SQRMakeError(MBDErrorInvalidArgument, @"outBytes and outLength must not be NULL");
        return NO;
    }
    pthread_mutex_lock(&_streamLock);
    if (!_tunerOpen) {
        pthread_mutex_unlock(&_streamLock);
        *outBytes = NULL;
        *outLength = 0;
        if (outRemaining) *outRemaining = 0;
        if (error) *error = SQRMakeError(MBDErrorNotOpen, @"Tuner is not open");
        return NO;
    }
    if (_chunkQueue.count == 0) {
        *outBytes = NULL;
        *outLength = 0;
        if (outRemaining) *outRemaining = 0;
        pthread_mutex_unlock(&_streamLock);
        return YES;
    }
    _activeChunk = _chunkQueue.firstObject;
    [_chunkQueue removeObjectAtIndex:0];
    *outBytes = (const uint8_t *)_activeChunk.bytes;
    *outLength = _activeChunk.length;
    if (outRemaining) *outRemaining = _chunkQueue.count;
    pthread_mutex_unlock(&_streamLock);
    return YES;
}

- (BOOL)readTSStreamIntoBuffer:(uint8_t *)buffer
                      capacity:(NSUInteger)capacity
                     bytesRead:(NSUInteger *)outBytesRead
                remainingCount:(nullable NSUInteger *)outRemaining
                         error:(NSError * _Nullable * _Nullable)error {
    if (!buffer || !outBytesRead) {
        if (error) *error = SQRMakeError(MBDErrorInvalidArgument, @"buffer and outBytesRead must not be NULL");
        return NO;
    }
    pthread_mutex_lock(&_streamLock);
    if (!_tunerOpen) {
        pthread_mutex_unlock(&_streamLock);
        *outBytesRead = 0;
        if (outRemaining) *outRemaining = 0;
        if (error) *error = SQRMakeError(MBDErrorNotOpen, @"Tuner is not open");
        return NO;
    }
    if (_chunkQueue.count == 0) {
        *outBytesRead = 0;
        if (outRemaining) *outRemaining = 0;
        pthread_mutex_unlock(&_streamLock);
        return YES;
    }
    NSData *nextChunk = _chunkQueue.firstObject;
    if (capacity < nextChunk.length) {
        *outBytesRead = 0;
        if (outRemaining) *outRemaining = _chunkQueue.count;
        pthread_mutex_unlock(&_streamLock);
        if (error) *error = SQRMakeError(MBDErrorBufferTooSmall, @"Destination buffer is smaller than TS chunk");
        return NO;
    }
    memcpy(buffer, nextChunk.bytes, nextChunk.length);
    [_chunkQueue removeObjectAtIndex:0];
    *outBytesRead = nextChunk.length;
    if (outRemaining) *outRemaining = _chunkQueue.count;
    pthread_mutex_unlock(&_streamLock);
    return YES;
}

- (void)purgeTSStream {
    pthread_mutex_lock(&_streamLock);
    [_chunkQueue removeAllObjects];
    _activeChunk = nil;
    _streamEpoch++;
    pthread_cond_broadcast(&_streamCond);
    pthread_mutex_unlock(&_streamLock);
}

#pragma mark - Optional Diagnostics & Channel Info

- (nullable NSDictionary<MBDSignalStatKey, NSNumber *> *)signalStatistics {
    float cnr = self.signalLevel;
    pthread_mutex_lock(&_streamLock);
    uint64_t dropped = _droppedChunks;
    uint64_t usbErrs = _usbErrorCount;
    pthread_mutex_unlock(&_streamLock);

    return @{
        MBDSignalStatCNRKey: @(cnr),
        MBDSignalStatLockedKey: @(_lastLocked || cnr > 0.0f),
        MBDSignalStatDroppedChunksKey: @(dropped),
        MBDSignalStatUSBErrorCountKey: @(usbErrs),
    };
}

- (nullable NSDictionary<MBDChannelInfoKey, id> *)channelInfoForSpace:(NSUInteger)space
                                                              channel:(NSUInteger)channel {
    if (space >= _spaces.count) return nil;
    NSDictionary *spaceDict = _spaces[space];
    NSArray *channels = spaceDict[@"Channels"];
    if (![channels isKindOfClass:[NSArray class]] || channel >= channels.count) return nil;
    NSDictionary *ch = channels[channel];
    MBDChannelFlags flags = MBDChannelFlagNone;
    for (NSString *f in ch[@"Flags"]) {
        if ([f isEqualToString:@"TSMF"]) flags |= MBDChannelFlagTSMF;
        else if ([f isEqualToString:@"RawTSMF"]) flags |= MBDChannelFlagRawTSMF;
        else if ([f isEqualToString:@"CATV"]) flags |= MBDChannelFlagCATV;
    }
    return @{
        MBDChannelInfoSystemKey: @(ParseSystemString(spaceDict[@"System"])),
        MBDChannelInfoFrequencyKHzKey: ch[@"FrequencyKHz"] ?: @(0),
        MBDChannelInfoBandwidthKHzKey: ch[@"BandwidthKHz"] ?: @(6000),
        MBDChannelInfoStreamIDKey: ch[@"StreamID"] ?: @(0),
        MBDChannelInfoFlagsKey: @(flags),
    };
}

#pragma mark - MacBonDriverMultiTuner

- (NSArray<NSDictionary<MBDDeviceInfoKey, id> *> *)enumerateDevices {
    NSMutableArray<NSDictionary<MBDDeviceInfoKey, id> *> *results = [NSMutableArray array];
    libusb_context *ctx = NULL;
    if (libusb_init(&ctx) != 0) return results;

    libusb_device **list = NULL;
    ssize_t count = libusb_get_device_list(ctx, &list);
    NSUInteger idx = 0;
    for (ssize_t i = 0; i < count; i++) {
        struct libusb_device_descriptor desc;
        if (libusb_get_device_descriptor(list[i], &desc) == 0 &&
            desc.idVendor == kSQR100VendorID && desc.idProduct == kSQR100ProductID) {
            uint32_t loc = ((uint32_t)libusb_get_bus_number(list[i]) << 16) |
                           (uint32_t)libusb_get_device_address(list[i]);
            [results addObject:@{
                MBDDeviceInfoIndexKey: @(idx),
                MBDDeviceInfoNameKey: [NSString stringWithFormat:@"PIXELA XIT-SQR100 #%lu", (unsigned long)idx],
                MBDDeviceInfoVendorIDKey: @(kSQR100VendorID),
                MBDDeviceInfoProductIDKey: @(kSQR100ProductID),
                MBDDeviceInfoLocationIDKey: @(loc),
                MBDDeviceInfoSystemsKey: @[@"ISDB-C", @"ISDB-T", @"ISDB-S"],
                MBDDeviceInfoInUseKey: @(idx == _deviceIndex ? self.isTunerOpen : NO),
            }];
            idx++;
        }
    }
    if (list) libusb_free_device_list(list, 1);
    libusb_exit(ctx);
    return results;
}

- (NSUInteger)totalDeviceCount {
    return [self enumerateDevices].count;
}

- (NSUInteger)activeDeviceCount {
    return self.isTunerOpen ? 1 : 0;
}

#pragma mark - MacBonDriverLNBControl

- (BOOL)supportsLNBPower {
    // XIT-SQR100 hardware does not supply BS/CS antenna power.
    return NO;
}

- (MBDLNBPowerMode)currentLNBPowerMode {
    return MBDLNBPowerOff;
}

- (BOOL)setLNBPowerMode:(MBDLNBPowerMode)mode
                  error:(NSError * _Nullable * _Nullable)error {
    if (mode == MBDLNBPowerOff) return YES;
    if (error) *error = SQRMakeError(MBDErrorLNBNotSupported, @"XIT-SQR100 does not support LNB antenna power");
    return NO;
}

#pragma mark - MacBonDriverTSMF

- (BOOL)supportsTSMF {
    return YES;
}

- (uint16_t)currentStreamID {
    pthread_mutex_lock(&_hwLock);
    uint16_t sid = _currentStreamID;
    pthread_mutex_unlock(&_hwLock);
    return sid;
}

#pragma mark - MacBonDriverSmartCard (IT930x UART T=1)

- (nullable NSString *)cardReaderName {
    return @"PIXELA XIT-SQR100 Built-in B-CAS Reader";
}

- (BOOL)isCardOpen {
    pthread_mutex_lock(&_hwLock);
    BOOL open = _cardOpen;
    pthread_mutex_unlock(&_hwLock);
    return open;
}

- (void)invalidateCardSessionLocked {
    _cardInitialized = NO;
    _cardUseCRC = false;
    _cardIFSC = 32;
    _cardBlockTimeoutMs = kCardBlockTimeoutMs;
    _cardSendSeq = 0;
    _cardRecvSeq = 0;
    _cardATR.clear();
}

- (int)waitCardDataReadyLocked:(std::chrono::steady_clock::time_point)deadline {
    while (std::chrono::steady_clock::now() < deadline) {
        bool ready = false;
        int ret = it930x_bcas_check_ready(&_bridge, &ready);
        if (ret || ready) return ret;
        msleep(kCardPollMs);
    }
    return -ETIMEDOUT;
}

- (int)sendT1BlockLocked:(uint8_t)pcb data:(const uint8_t *)data length:(size_t)len {
    if (len > 254 || (len && !data)) return -EINVAL;
    std::vector<uint8_t> frame;
    frame.reserve(3 + len + (_cardUseCRC ? 2 : 1));
    frame.push_back(kT1NAD);
    frame.push_back(pcb);
    frame.push_back((uint8_t)len);
    if (len) frame.insert(frame.end(), data, data + len);

    if (_cardUseCRC) {
        uint16_t crc = CalcCRC16(frame.data(), frame.size());
        frame.push_back((uint8_t)(crc >> 8));
        frame.push_back((uint8_t)(crc & 0xFF));
    } else {
        uint8_t lrc = 0;
        for (uint8_t b : frame) lrc ^= b;
        frame.push_back(lrc);
    }
    if (frame.size() > kCardFrameMax) return -EMSGSIZE;
    return it930x_bcas_send_data(&_bridge, frame.data(), (u8)frame.size());
}

- (int)receiveT1BlockLocked:(uint8_t &)pcb data:(std::vector<uint8_t> &)data
                   deadline:(std::chrono::steady_clock::time_point)deadline {
    std::vector<uint8_t> frame;
    size_t expected = 0;
    while (std::chrono::steady_clock::now() < deadline) {
        int ret = [self waitCardDataReadyLocked:deadline];
        if (ret) return ret;
        u8 chunk[255];
        u8 chunkLen = sizeof(chunk);
        ret = it930x_bcas_get_data(&_bridge, chunk, &chunkLen);
        if (ret) return ret;
        if (chunkLen > 0) {
            frame.insert(frame.end(), chunk, chunk + chunkLen);
            if (frame.size() >= 3) expected = 3 + frame[2] + (_cardUseCRC ? 2 : 1);
            if (expected && frame.size() >= expected) break;
        }
        msleep(kCardPollMs);
    }
    if (!expected || frame.size() < expected) return -ETIMEDOUT;
    if (frame.size() > expected) frame.resize(expected);
    if (frame[0] != kT1NAD) return -EPROTO;

    if (_cardUseCRC) {
        uint16_t exp = CalcCRC16(frame.data(), frame.size() - 2);
        uint16_t got = ((uint16_t)frame[frame.size() - 2] << 8) | frame.back();
        if (exp != got) return -EBADMSG;
    } else {
        uint8_t lrc = 0;
        for (uint8_t b : frame) lrc ^= b;
        if (lrc != 0) return -EBADMSG;
    }
    pcb = frame[1];
    data.assign(frame.begin() + 3, frame.begin() + 3 + frame[2]);
    return 0;
}

- (int)exchangeT1BlockLocked:(uint8_t)pcb sendData:(const uint8_t *)sendData sendLen:(size_t)sendLen
                     recvPCB:(uint8_t &)recvPCB recvData:(std::vector<uint8_t> &)recvData
                    deadline:(std::chrono::steady_clock::time_point)deadline {
    for (unsigned int retry = 0; retry < kCardMaxRetries; retry++) {
        if (std::chrono::steady_clock::now() >= deadline) return -ETIMEDOUT;
        int ret = [self sendT1BlockLocked:pcb data:sendData length:sendLen];
        if (ret) return ret;

        auto blockDeadline = std::min(deadline,
            std::chrono::steady_clock::now() + std::chrono::milliseconds(_cardBlockTimeoutMs));
        ret = [self receiveT1BlockLocked:recvPCB data:recvData deadline:blockDeadline];
        if (!ret) {
            while (recvPCB == (kT1SBlock | kT1SWTX)) {
                if (recvData.size() != 1 || recvData[0] == 0) return -EPROTO;
                uint8_t mult = recvData[0];
                ret = [self sendT1BlockLocked:(kT1SBlock | kT1SResp | kT1SWTX) data:&mult length:1];
                if (ret) return ret;
                ret = [self receiveT1BlockLocked:recvPCB data:recvData deadline:deadline];
                if (ret) break;
            }
            if (!ret) return 0;
        }
        if (ret != -ETIMEDOUT && ret != -EBADMSG) return ret;
    }
    return -ETIMEDOUT;
}

- (int)resetCardSessionLocked {
    [self invalidateCardSessionLocked];
    bool detected = false;
    int ret = it930x_bcas_detect_card(&_bridge, &detected);
    if (ret) return ret;
    if (!detected) return kCardNoMedium;

    std::vector<uint8_t> atr;
    SQRCardAtrParams params;
    for (int attempt = 0; attempt < 2; attempt++) {
        atr.clear();
        params = SQRCardAtrParams{};
        ret = it930x_bcas_reset_card(&_bridge);
        if (ret) return ret;

        auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(kCardATRTimeoutMs);
        size_t expectedLen = 0;
        ret = -ETIMEDOUT;
        while (std::chrono::steady_clock::now() < deadline) {
            ret = [self waitCardDataReadyLocked:deadline];
            if (ret) break;
            u8 chunk[33];
            u8 chunkLen = sizeof(chunk);
            ret = it930x_bcas_get_data(&_bridge, chunk, &chunkLen);
            if (ret) break;
            if (chunkLen > 0) {
                if (atr.size() + chunkLen > 33) { ret = -EBADMSG; break; }
                atr.insert(atr.end(), chunk, chunk + chunkLen);
                ret = ParseATR(atr, expectedLen, params);
                if (ret == 0 && atr.size() == expectedLen) break;
                if (ret != -EAGAIN) break;
            }
            msleep(kCardPollMs);
        }
        if (ret == 0) break;
        if (ret != -EBADMSG || attempt != 0) return ret;
    }

    ret = it930x_bcas_set_baudrate(&_bridge, params.baudrate);
    if (ret) return ret;

    _cardATR = atr;
    _cardIFSC = params.ifsc;
    _cardUseCRC = params.useCRC;
    _cardBlockTimeoutMs = params.blockTimeoutMs;
    _cardSendSeq = 0;
    _cardRecvSeq = 0;

    bool isACAS = (params.baudrate == IT930X_UART_BAUDRATE_38400);
    uint8_t ifsd = isACAS ? 254 : (_cardUseCRC ? 250 : 251);
    auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(kCardOpTimeoutMs);
    uint8_t rpcb = 0;
    std::vector<uint8_t> rdata;

    if (!isACAS) {
        ret = [self exchangeT1BlockLocked:(kT1SBlock | kT1SResynch) sendData:nullptr sendLen:0
                                  recvPCB:rpcb recvData:rdata deadline:deadline];
        if (ret || rpcb != (kT1SBlock | kT1SResp | kT1SResynch) || !rdata.empty()) {
            [self invalidateCardSessionLocked];
            return ret ? ret : -EPROTO;
        }
    }
    ret = [self exchangeT1BlockLocked:(kT1SBlock | kT1SIFS) sendData:&ifsd sendLen:1
                              recvPCB:rpcb recvData:rdata deadline:deadline];
    if (ret || rpcb != (kT1SBlock | kT1SResp | kT1SIFS) || rdata.size() != 1 || rdata[0] != ifsd) {
        [self invalidateCardSessionLocked];
        return ret ? ret : -EPROTO;
    }

    _cardInitialized = YES;
    return 0;
}

- (BOOL)openSmartCardWithError:(NSError * _Nullable * _Nullable)error {
    pthread_mutex_lock(&_hwLock);
    if (_cardOpen) {
        pthread_mutex_unlock(&_hwLock);
        if (error) *error = SQRMakeError(MBDErrorAlreadyOpen, @"Smart card session is already open");
        return NO;
    }

    if (![self ensureHardwareOpenLocked:error]) {
        pthread_mutex_unlock(&_hwLock);
        return NO;
    }

    int ret = [self setBackendPowerLocked:YES];
    if (!ret) ret = it930x_bcas_init(&_bridge);
    // XIT-SQR100 requires GPIO H7 Low to receive ATR from the built-in slot.
    if (!ret) ret = it930x_write_gpio(&_bridge, 7, false);

    if (ret != 0) {
        [self releaseHardwareIfUnusedLocked];
        pthread_mutex_unlock(&_hwLock);
        if (error) *error = SQRMakeError(MBDErrorCardProtocol, @"Failed to initialize IT930x smart card UART", ret);
        return NO;
    }

    _cardOpen = YES;
    [self invalidateCardSessionLocked];

    bool detected = false;
    if (it930x_bcas_detect_card(&_bridge, &detected) == 0 && detected) {
        (void)[self resetCardSessionLocked];
    }

    pthread_mutex_unlock(&_hwLock);
    return YES;
}

- (void)closeSmartCard {
    pthread_mutex_lock(&_hwLock);
    if (_cardOpen) {
        _cardOpen = NO;
        [self invalidateCardSessionLocked];
        [self releaseHardwareIfUnusedLocked];
    }
    pthread_mutex_unlock(&_hwLock);
}

- (BOOL)isCardPresent:(BOOL *)outPresent
                  atr:(NSData * _Nullable * _Nullable)outATR
                error:(NSError * _Nullable * _Nullable)error {
    if (!outPresent) {
        if (error) *error = SQRMakeError(MBDErrorInvalidArgument, @"outPresent must not be NULL");
        return NO;
    }
    pthread_mutex_lock(&_hwLock);
    if (!_cardOpen) {
        pthread_mutex_unlock(&_hwLock);
        if (error) *error = SQRMakeError(MBDErrorNotOpen, @"Smart card session is not open");
        return NO;
    }
    bool detected = false;
    int ret = it930x_bcas_detect_card(&_bridge, &detected);
    if (ret != 0) {
        [self invalidateCardSessionLocked];
        pthread_mutex_unlock(&_hwLock);
        if (error) *error = SQRMakeError(MBDErrorCardProtocol, @"Card presence detection failed", ret);
        return NO;
    }
    if (!detected) {
        [self invalidateCardSessionLocked];
        *outPresent = NO;
        if (outATR) *outATR = nil;
        pthread_mutex_unlock(&_hwLock);
        return YES;
    }
    if (!_cardInitialized) {
        ret = [self resetCardSessionLocked];
        if (ret != 0) {
            pthread_mutex_unlock(&_hwLock);
            if (error) *error = SQRMakeError(MBDErrorCardProtocol, @"Card reset failed", ret);
            return NO;
        }
    }
    *outPresent = YES;
    if (outATR) {
        *outATR = [NSData dataWithBytes:_cardATR.data() length:_cardATR.size()];
    }
    pthread_mutex_unlock(&_hwLock);
    return YES;
}

- (BOOL)resetSmartCardReturningATR:(NSData * _Nullable * _Nullable)outATR
                             error:(NSError * _Nullable * _Nullable)error {
    pthread_mutex_lock(&_hwLock);
    if (!_cardOpen) {
        pthread_mutex_unlock(&_hwLock);
        if (error) *error = SQRMakeError(MBDErrorNotOpen, @"Smart card session is not open");
        return NO;
    }
    int ret = [self resetCardSessionLocked];
    if (ret != 0) {
        pthread_mutex_unlock(&_hwLock);
        MBDErrorCode code = (ret == kCardNoMedium) ? MBDErrorCardNotPresent
                          : (ret == -ETIMEDOUT ? MBDErrorCardTimeout : MBDErrorCardProtocol);
        if (error) *error = SQRMakeError(code, @"Smart card reset failed", ret);
        return NO;
    }
    if (outATR) {
        *outATR = [NSData dataWithBytes:_cardATR.data() length:_cardATR.size()];
    }
    pthread_mutex_unlock(&_hwLock);
    return YES;
}

- (nullable NSData *)transmitAPDU:(NSData *)commandAPDU
                            error:(NSError * _Nullable * _Nullable)error {
    if (!commandAPDU || commandAPDU.length < 4 || commandAPDU.length > 512) {
        if (error) *error = SQRMakeError(MBDErrorInvalidArgument, @"APDU length must be 4..512 bytes");
        return nil;
    }
    pthread_mutex_lock(&_hwLock);
    if (!_cardOpen) {
        pthread_mutex_unlock(&_hwLock);
        if (error) *error = SQRMakeError(MBDErrorNotOpen, @"Smart card session is not open");
        return nil;
    }

    bool detected = false;
    int ret = it930x_bcas_detect_card(&_bridge, &detected);
    if (ret != 0 || !detected) {
        [self invalidateCardSessionLocked];
        pthread_mutex_unlock(&_hwLock);
        if (error) *error = SQRMakeError(detected ? MBDErrorCardProtocol : MBDErrorCardNotPresent,
                                         detected ? @"Card detection error" : @"No smart card inserted", ret);
        return nil;
    }
    if (!_cardInitialized) {
        ret = [self resetCardSessionLocked];
        if (ret != 0) {
            pthread_mutex_unlock(&_hwLock);
            if (error) *error = SQRMakeError(MBDErrorCardProtocol, @"Card initialization failed", ret);
            return nil;
        }
    }

    const uint8_t *sendBuf = (const uint8_t *)commandAPDU.bytes;
    size_t sendLen = commandAPDU.length;
    auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(kCardOpTimeoutMs);
    size_t maxInf = kCardFrameMax - 3 - (_cardUseCRC ? 2 : 1);
    size_t sendOff = 0;
    uint8_t lastPCB = 0;
    std::vector<uint8_t> lastData;

    while (sendOff < sendLen) {
        size_t chunkLen = std::min(std::min((size_t)_cardIFSC, maxInf), sendLen - sendOff);
        bool more = (sendOff + chunkLen < sendLen);
        uint8_t pcb = kT1IBlock | (_cardSendSeq ? kT1ISeq : 0) | (more ? kT1IChain : 0);

        bool accepted = false;
        for (unsigned int retry = 0; retry < kCardMaxRetries; retry++) {
            ret = [self exchangeT1BlockLocked:pcb sendData:sendBuf + sendOff sendLen:chunkLen
                                      recvPCB:lastPCB recvData:lastData deadline:deadline];
            if (ret) break;
            if ((lastPCB & 0xC0) == kT1RBlock) {
                bool reqSeq = (lastPCB & kT1RSeq) != 0;
                if (reqSeq == (_cardSendSeq != 0)) continue;
                accepted = true;
                break;
            }
            if ((lastPCB & 0x80) == kT1IBlock && !more) {
                accepted = true;
                break;
            }
            ret = -EPROTO;
            break;
        }
        if (ret || !accepted) {
            [self invalidateCardSessionLocked];
            pthread_mutex_unlock(&_hwLock);
            if (error) *error = SQRMakeError(ret == -ETIMEDOUT ? MBDErrorCardTimeout : MBDErrorCardProtocol,
                                             @"APDU send failed", ret);
            return nil;
        }
        _cardSendSeq ^= 1;
        sendOff += chunkLen;
    }

    std::vector<uint8_t> resp;
    while (true) {
        if (((lastPCB & kT1ISeq) != 0) != (_cardRecvSeq != 0)) {
            [self invalidateCardSessionLocked];
            pthread_mutex_unlock(&_hwLock);
            if (error) *error = SQRMakeError(MBDErrorCardProtocol, @"T=1 receive sequence mismatch");
            return nil;
        }
        resp.insert(resp.end(), lastData.begin(), lastData.end());
        _cardRecvSeq ^= 1;
        if (!(lastPCB & kT1IChain)) break;

        uint8_t rpcb = kT1RBlock | (_cardRecvSeq ? kT1RSeq : 0);
        ret = [self exchangeT1BlockLocked:rpcb sendData:nullptr sendLen:0
                                  recvPCB:lastPCB recvData:lastData deadline:deadline];
        if (ret || (lastPCB & 0x80) != kT1IBlock) {
            [self invalidateCardSessionLocked];
            pthread_mutex_unlock(&_hwLock);
            if (error) *error = SQRMakeError(ret == -ETIMEDOUT ? MBDErrorCardTimeout : MBDErrorCardProtocol,
                                             @"APDU receive failed", ret);
            return nil;
        }
    }

    pthread_mutex_unlock(&_hwLock);
    return [NSData dataWithBytes:resp.data() length:resp.size()];
}

@end
