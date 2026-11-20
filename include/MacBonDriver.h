// SPDX-License-Identifier: MIT
// MacBonDriver.h — macOS Userland USB DTV Tuner Driver (.bundle) SDK Header
// Specification Version: 1.0

#ifndef MAC_BON_DRIVER_H
#define MAC_BON_DRIVER_H

#import <Foundation/Foundation.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

#define MacBonDriverAPIVersion 1U
#define MBD_UNUSED __attribute__((unused))

/// Invalid tuning space or channel index (analogous to 0xFFFFFFFF in IBonDriver2).
static const NSUInteger MBDInvalidIndex MBD_UNUSED = NSNotFound;

/// Standard MPEG-TS packet length in bytes.
static const NSUInteger MBDTSPacketSize MBD_UNUSED = 188U;

// ---------------------------------------------------------------------------
// Error Domain & Codes
// ---------------------------------------------------------------------------

static NSErrorDomain const MBDErrorDomain MBD_UNUSED = @"jp.macbondriver.error";

typedef NS_ERROR_ENUM(MBDErrorDomain, MBDErrorCode) {
    MBDErrorUnknown = 1,
    MBDErrorInvalidArgument = 2,
    MBDErrorUnsupported = 3,
    MBDErrorIncompatibleAPIVersion = 4,
    MBDErrorNotOpen = 5,
    MBDErrorAlreadyOpen = 6,
    MBDErrorDeviceNotFound = 7,
    MBDErrorDeviceBusy = 8,
    MBDErrorDeviceDisconnected = 9,
    MBDErrorUSBTransferFailed = 10,
    MBDErrorFirmwareMissing = 11,
    MBDErrorFirmwareLoadFailed = 12,
    MBDErrorConfigInvalid = 13,
    MBDErrorInvalidSpaceOrChannel = 14,
    MBDErrorTuneFailed = 15,
    MBDErrorTuneTimeout = 16,
    MBDErrorBufferTooSmall = 17,
    MBDErrorNoStreamData = 18,
    MBDErrorLNBNotSupported = 19,
    MBDErrorCardReaderNotPresent = 20,
    MBDErrorCardNotPresent = 21,
    MBDErrorCardProtocol = 22,
    MBDErrorCardTimeout = 23,
    MBDErrorHostDaemonUnavailable = 24,
};

// ---------------------------------------------------------------------------
// Info.plist Metadata Keys
// ---------------------------------------------------------------------------

typedef NSString * MBDInfoPlistKey NS_TYPED_EXTENSIBLE_ENUM;

static MBDInfoPlistKey const MBDInfoAPIVersionKey MBD_UNUSED = @"MBDAPIVersion";
static MBDInfoPlistKey const MBDInfoDisplayNameKey MBD_UNUSED = @"MBDDisplayName";
static MBDInfoPlistKey const MBDInfoDriverIdentifierKey MBD_UNUSED = @"MBDDriverIdentifier";
static MBDInfoPlistKey const MBDInfoSupportedSystemsKey MBD_UNUSED = @"MBDSupportedSystems";
static MBDInfoPlistKey const MBDInfoCapabilitiesKey MBD_UNUSED = @"MBDCapabilities";
static MBDInfoPlistKey const MBDInfoUSBMatchListKey MBD_UNUSED = @"MBDUSBMatchList";
static MBDInfoPlistKey const MBDInfoRequiresExternalHostKey MBD_UNUSED = @"MBDRequiresExternalHost";
static MBDInfoPlistKey const MBDInfoConfigFileNameKey MBD_UNUSED = @"MBDConfigFileName";

// ---------------------------------------------------------------------------
// Driver Initialization Option Keys
// ---------------------------------------------------------------------------

typedef NSString * MBDDriverOptionKey NS_TYPED_EXTENSIBLE_ENUM;

/// NSURL or NSString path to a custom configuration / channel-set file.
static MBDDriverOptionKey const MBDOptionConfigURLKey MBD_UNUSED = @"MBDOptionConfigURL";
/// NSURL or NSString path to a directory containing device firmware binaries.
static MBDDriverOptionKey const MBDOptionFirmwareDirectoryURLKey MBD_UNUSED = @"MBDOptionFirmwareDirectoryURL";
/// NSNumber (uint32_t) macOS IOKit USB locationID to bind a specific physical USB device.
static MBDDriverOptionKey const MBDOptionUSBDeviceLocationIDKey MBD_UNUSED = @"MBDOptionUSBDeviceLocationID";
/// NSString USB serial number to bind a specific physical USB device.
static MBDDriverOptionKey const MBDOptionUSBSerialNumberKey MBD_UNUSED = @"MBDOptionUSBSerialNumber";
/// NSNumber (NSUInteger) zero-based logical tuner / device index.
static MBDDriverOptionKey const MBDOptionDeviceIndexKey MBD_UNUSED = @"MBDOptionDeviceIndex";
/// NSString or NSURL path to Unix domain socket / XPC Mach service name when using a shared host daemon.
static MBDDriverOptionKey const MBDOptionHostEndpointKey MBD_UNUSED = @"MBDOptionHostEndpoint";

// ---------------------------------------------------------------------------
// Enumerations
// ---------------------------------------------------------------------------

typedef NS_ENUM(NSInteger, MBDWaitResult) {
    /// At least one TS chunk is ready to read.
    MBDWaitResultReady = 0,
    /// Timed out before any TS chunk arrived.
    MBDWaitResultTimeout = 1,
    /// Tuner is closed or stream was stopped/purged while waiting.
    MBDWaitResultClosed = 2,
    /// Fatal stream or USB device error occurred (e.g., disconnect).
    MBDWaitResultError = 3,
};

typedef NS_ENUM(NSInteger, MBDBroadcastSystem) {
    MBDBroadcastSystemUnspecified = 0,
    MBDBroadcastSystemISDBT = 1,
    MBDBroadcastSystemISDBS = 2,
    MBDBroadcastSystemISDBC = 3,
    MBDBroadcastSystemISDBS3 = 4,
};

typedef NS_OPTIONS(NSUInteger, MBDChannelFlags) {
    MBDChannelFlagNone = 0,
    /// Channel carries TSMF-multiplexed transport streams (ISDB-C / CATV).
    MBDChannelFlagTSMF = 1UL << 0,
    /// Driver outputs raw multiplexed TS without demuxing TSMF relative TS.
    MBDChannelFlagRawTSMF = 1UL << 1,
    /// Channel uses CATV pass-through or cable frequency plan.
    MBDChannelFlagCATV = 1UL << 2,
};

typedef NS_ENUM(NSInteger, MBDLNBPowerMode) {
    MBDLNBPowerOff = 0,
    MBDLNBPower15V = 1,
    MBDLNBPower11V = 2,
    MBDLNBPowerAuto = 3,
};

typedef NS_ENUM(NSInteger, MBDEventType) {
    /// Physical USB device was detached or stopped responding.
    MBDEventDeviceDisconnected = 1,
    /// Physical USB device was reattached and is available again.
    MBDEventDeviceReconnected = 2,
    /// Demodulator TS lock state changed.
    MBDEventSignalLockChanged = 3,
    /// Internal TS ring buffer overflowed and dropped packets.
    MBDEventStreamOverflow = 4,
    /// Built-in smart card was inserted, removed, or reset.
    MBDEventSmartCardStateChanged = 5,
    /// Non-fatal or fatal driver error reported asynchronously.
    MBDEventError = 6,
};

// ---------------------------------------------------------------------------
// Structured Dictionary Keys (Statistics / Channel Info / Device Info)
// ---------------------------------------------------------------------------

typedef NSString * MBDSignalStatKey NS_TYPED_EXTENSIBLE_ENUM;

/// NSNumber (double): Carrier-to-noise ratio in dB.
static MBDSignalStatKey const MBDSignalStatCNRKey MBD_UNUSED = @"cnr_db";
/// NSNumber (double): Signal strength / RSSI in dBm.
static MBDSignalStatKey const MBDSignalStatRSSIKey MBD_UNUSED = @"rssi_dbm";
/// NSNumber (BOOL): Whether demodulator reports TS lock.
static MBDSignalStatKey const MBDSignalStatLockedKey MBD_UNUSED = @"locked";
/// NSNumber (double): Bit error rate (0.0 .. 1.0) if available.
static MBDSignalStatKey const MBDSignalStatBERKey MBD_UNUSED = @"ber";
/// NSNumber (uint64_t): Count of ring-buffer overflow drops since open/purge.
static MBDSignalStatKey const MBDSignalStatDroppedChunksKey MBD_UNUSED = @"dropped_chunks";
/// NSNumber (uint64_t): Count of USB transfer errors since open.
static MBDSignalStatKey const MBDSignalStatUSBErrorCountKey MBD_UNUSED = @"usb_error_count";

typedef NSString * MBDChannelInfoKey NS_TYPED_EXTENSIBLE_ENUM;

/// NSNumber (MBDBroadcastSystem)
static MBDChannelInfoKey const MBDChannelInfoSystemKey MBD_UNUSED = @"system";
/// NSNumber (uint32_t): Center frequency in kHz.
static MBDChannelInfoKey const MBDChannelInfoFrequencyKHzKey MBD_UNUSED = @"frequency_khz";
/// NSNumber (uint32_t): Channel bandwidth in kHz (e.g., 6000 for ISDB-T/C).
static MBDChannelInfoKey const MBDChannelInfoBandwidthKHzKey MBD_UNUSED = @"bandwidth_khz";
/// NSNumber (uint16_t): Stream ID / TSID / TSMF relative TS index (0 if unused).
static MBDChannelInfoKey const MBDChannelInfoStreamIDKey MBD_UNUSED = @"stream_id";
/// NSNumber (MBDChannelFlags)
static MBDChannelInfoKey const MBDChannelInfoFlagsKey MBD_UNUSED = @"flags";

typedef NSString * MBDDeviceInfoKey NS_TYPED_EXTENSIBLE_ENUM;

/// NSNumber (NSUInteger): Logical device index.
static MBDDeviceInfoKey const MBDDeviceInfoIndexKey MBD_UNUSED = @"index";
/// NSString: Human-readable device or tuner label.
static MBDDeviceInfoKey const MBDDeviceInfoNameKey MBD_UNUSED = @"name";
/// NSNumber (uint16_t): USB Vendor ID.
static MBDDeviceInfoKey const MBDDeviceInfoVendorIDKey MBD_UNUSED = @"vendor_id";
/// NSNumber (uint16_t): USB Product ID.
static MBDDeviceInfoKey const MBDDeviceInfoProductIDKey MBD_UNUSED = @"product_id";
/// NSNumber (uint32_t): macOS USB locationID (0 for virtual/sample devices).
static MBDDeviceInfoKey const MBDDeviceInfoLocationIDKey MBD_UNUSED = @"location_id";
/// NSString: USB serial number if available.
static MBDDeviceInfoKey const MBDDeviceInfoSerialNumberKey MBD_UNUSED = @"serial_number";
/// NSArray<NSString *>: Supported broadcast systems (e.g., @[@"ISDB-T", @"ISDB-S", @"ISDB-C"]).
static MBDDeviceInfoKey const MBDDeviceInfoSystemsKey MBD_UNUSED = @"systems";
/// NSNumber (BOOL): YES if currently opened by a client.
static MBDDeviceInfoKey const MBDDeviceInfoInUseKey MBD_UNUSED = @"in_use";

// ---------------------------------------------------------------------------
// Delegate Protocol (Hotplug & Async Events)
// ---------------------------------------------------------------------------

@protocol MacBonDriver;

@protocol MacBonDriverDelegate <NSObject>
@optional
/// Delivered on an arbitrary background queue unless documented otherwise.
/// Hosts updating UI MUST dispatch to the main queue.
- (void)bonDriver:(id<MacBonDriver>)driver
  didReceiveEvent:(MBDEventType)event
         userInfo:(nullable NSDictionary<NSString *, id> *)userInfo;
@end

// ---------------------------------------------------------------------------
// Core Protocol: MacBonDriver (IBonDriver + IBonDriver2 equivalent)
// ---------------------------------------------------------------------------

/// Core protocol that every MacBonDriver .bundle's NSPrincipalClass MUST adopt.
///
/// Naming requirement: To avoid Objective-C runtime class name collisions when
/// loading multiple .bundle drivers into the same process, each driver MUST
/// give its principal class and all internal classes a unique vendor/driver
/// prefix (e.g., MBDSQR100Driver, MBDPX4Driver).
@protocol MacBonDriver <NSObject>

@required

/// Returns MacBonDriverAPIVersion supported by this bundle.
+ (NSUInteger)apiVersion;

/// Designated factory method.
/// @param bundle  The NSBundle from which this principal class was loaded.
/// @param options Optional configuration overrides (see MBDOption*Key).
/// @param error   Populated on failure.
+ (nullable instancetype)driverWithBundle:(NSBundle *)bundle
                                  options:(nullable NSDictionary<MBDDriverOptionKey, id> *)options
                                    error:(NSError * _Nullable * _Nullable)error;

/// Human-readable tuner name (equivalent to IBonDriver2::GetTunerName).
@property (nonatomic, readonly, copy) NSString *tunerName;

/// YES while the tuner device is open (equivalent to IBonDriver2::IsTunerOpening).
@property (nonatomic, readonly, getter=isTunerOpen) BOOL tunerOpen;

/// Zero-based active tuning space index, or MBDInvalidIndex if untuned.
@property (nonatomic, readonly) NSUInteger currentSpace;

/// Zero-based active channel index within currentSpace, or MBDInvalidIndex if untuned.
@property (nonatomic, readonly) NSUInteger currentChannel;

/// Current signal level (CNR in dB; 0.0f when unlocked or unavailable).
@property (nonatomic, readonly) float signalLevel;

/// Optional delegate for hotplug and asynchronous stream/card notifications.
@property (nonatomic, weak, nullable) id<MacBonDriverDelegate> delegate;

/// Opens the underlying USB tuner device (or connects to the shared host daemon).
- (BOOL)openTunerWithError:(NSError * _Nullable * _Nullable)error;

/// Stops streaming, releases USB resources, and wakes any blocked waitTSStream call.
/// MUST be idempotent and safe to call even if already closed.
- (void)closeTuner;

/// Returns the tuning space name for the given zero-based index, or nil if out of range.
- (nullable NSString *)tuningSpaceNameAtIndex:(NSUInteger)space;

/// Returns the channel name for the given zero-based (space, channel), or nil if out of range.
- (nullable NSString *)channelNameInSpace:(NSUInteger)space channel:(NSUInteger)channel;

/// Tunes to the specified space and channel, purging stale TS buffers on success.
- (BOOL)setSpace:(NSUInteger)space
         channel:(NSUInteger)channel
           error:(NSError * _Nullable * _Nullable)error;

/// Blocks until at least one TS chunk is available, timeoutMs elapses, or the tuner closes.
/// Passing timeoutMs == 0 performs a non-blocking poll.
- (MBDWaitResult)waitTSStreamWithTimeoutMs:(uint32_t)timeoutMs;

/// Returns the number of TS chunks currently buffered and ready for retrieval.
- (NSUInteger)readyStreamCount;

/// Retrieves the next buffered TS chunk without copying into caller memory.
///
/// The returned byte pointer MUST remain valid on the stream consumer thread
/// until the next call to getTSStreamChunk:, readTSStreamIntoBuffer:,
/// purgeTSStream, or closeTuner.
/// Unless raw mode is active, *outLength MUST be a multiple of 188 bytes and
/// begin with sync byte 0x47.
- (BOOL)getTSStreamChunk:(const uint8_t * _Nullable * _Nonnull)outBytes
                  length:(NSUInteger *)outLength
          remainingCount:(nullable NSUInteger *)outRemaining
                   error:(NSError * _Nullable * _Nullable)error;

/// Copies the next buffered TS chunk into a caller-provided buffer.
/// Fails with MBDErrorBufferTooSmall if capacity is smaller than the next chunk.
- (BOOL)readTSStreamIntoBuffer:(uint8_t *)buffer
                      capacity:(NSUInteger)capacity
                     bytesRead:(NSUInteger *)outBytesRead
                remainingCount:(nullable NSUInteger *)outRemaining
                         error:(NSError * _Nullable * _Nullable)error;

/// Discards all buffered TS chunks and resets internal TS packet sync state.
/// MUST NOT deadlock with a concurrent waitTSStreamWithTimeoutMs: call.
- (void)purgeTSStream;

@optional

/// Returns extended signal and stream diagnostics (see MBDSignalStat*Key).
- (nullable NSDictionary<MBDSignalStatKey, NSNumber *> *)signalStatistics;

/// Returns physical channel parameters for (space, channel) (see MBDChannelInfo*Key).
- (nullable NSDictionary<MBDChannelInfoKey, id> *)channelInfoForSpace:(NSUInteger)space
                                                              channel:(NSUInteger)channel;

@end

// ---------------------------------------------------------------------------
// Optional Extension Protocol: Multi-Tuner & Device Enumeration (IBonDriver3)
// ---------------------------------------------------------------------------

@protocol MacBonDriverMultiTuner <MacBonDriver>
@required

/// Total number of logical tuner devices managed by this driver (GetTotalDeviceNum).
@property (nonatomic, readonly) NSUInteger totalDeviceCount;

/// Number of logical tuner devices currently open/active (GetActiveDeviceNum).
@property (nonatomic, readonly) NSUInteger activeDeviceCount;

/// Enumerates discovered logical tuner devices (see MBDDeviceInfo*Key).
- (NSArray<NSDictionary<MBDDeviceInfoKey, id> *> *)enumerateDevices;

@end

// ---------------------------------------------------------------------------
// Optional Extension Protocol: LNB Power Control (IBonDriver3)
// ---------------------------------------------------------------------------

@protocol MacBonDriverLNBControl <MacBonDriver>
@required

/// YES if the hardware supports LNB power supply control (e.g., NO for XIT-SQR100).
@property (nonatomic, readonly) BOOL supportsLNBPower;

/// Current LNB power mode.
@property (nonatomic, readonly) MBDLNBPowerMode currentLNBPowerMode;

/// Sets LNB power mode. Returns NO with MBDErrorLNBNotSupported if unsupported.
- (BOOL)setLNBPowerMode:(MBDLNBPowerMode)mode
                  error:(NSError * _Nullable * _Nullable)error;

@end

// ---------------------------------------------------------------------------
// Optional Extension Protocol: TSMF / Stream ID Selection (ISDB-S / ISDB-C)
// ---------------------------------------------------------------------------

@protocol MacBonDriverTSMF <MacBonDriver>
@required

/// YES if the driver supports explicit Stream ID / TSMF relative TS selection.
@property (nonatomic, readonly) BOOL supportsTSMF;

/// Active Stream ID (BS TSID or TSMF relative TS selector; 0 if unspecified).
@property (nonatomic, readonly) uint16_t currentStreamID;

/// Tunes to (space, channel) with an explicit Stream ID / TSID override.
- (BOOL)setSpace:(NSUInteger)space
         channel:(NSUInteger)channel
        streamID:(uint16_t)streamID
           error:(NSError * _Nullable * _Nullable)error;

@end

// ---------------------------------------------------------------------------
// Optional Extension Protocol: Built-in Smart Card Reader (B-CAS / APDU)
// ---------------------------------------------------------------------------

/// Direct ISO/IEC 7816-4 APDU access for USB tuners with an integrated smart
/// card slot (e.g., IT930x UART card reader on XIT-SQR100, PX-W3U4, PX-Q3U4).
///
/// Drivers implementing this protocol MUST keep shared hardware power rails
/// active while EITHER the tuner OR the smart card session is open, and MUST
/// serialize shared USB control endpoint transactions internally.
@protocol MacBonDriverSmartCard <MacBonDriver>
@required

/// Human-readable smart card reader name (e.g., "XIT-SQR100 Built-in B-CAS Reader").
@property (nonatomic, readonly, copy, nullable) NSString *cardReaderName;

/// YES while the smart card session is open.
@property (nonatomic, readonly, getter=isCardOpen) BOOL cardOpen;

/// Opens a session to the built-in smart card reader.
- (BOOL)openSmartCardWithError:(NSError * _Nullable * _Nullable)error;

/// Closes the smart card session (idempotent).
- (void)closeSmartCard;

/// Queries card presence and (if present and initialized) returns its ATR bytes.
- (BOOL)isCardPresent:(BOOL *)outPresent
                  atr:(NSData * _Nullable * _Nullable)outATR
                error:(NSError * _Nullable * _Nullable)error;

/// Performs a cold/warm card reset (e.g., T=1 initialization) and returns the ATR.
- (BOOL)resetSmartCardReturningATR:(NSData * _Nullable * _Nullable)outATR
                             error:(NSError * _Nullable * _Nullable)error;

/// Sends a raw ISO/IEC 7816-4 command APDU and returns the response APDU (data + SW1/SW2).
- (nullable NSData *)transmitAPDU:(NSData *)commandAPDU
                            error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END

#endif /* MAC_BON_DRIVER_H */
