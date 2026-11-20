// SPDX-License-Identifier: MIT
// SampleUSBDriver.m — Reference MacBonDriver (.bundle) implementation

#import "MacBonDriver.h"
#include <pthread.h>
#include <string.h>

static const NSUInteger kChunkPackets = 64;
static const NSUInteger kChunkBytes = MBDTSPacketSize * kChunkPackets;
static const NSUInteger kMaxQueueChunks = 32;

static NSError *MBDMakeError(MBDErrorCode code, NSString *description) {
    return [NSError errorWithDomain:MBDErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description ?: @"MacBonDriver error"}];
}

static uint32_t MBDCRC32MPEG2(const uint8_t *data, size_t len) {
    uint32_t crc = 0xFFFFFFFFU;
    for (size_t i = 0; i < len; i++) {
        crc ^= ((uint32_t)data[i]) << 24;
        for (int b = 0; b < 8; b++) {
            crc = (crc & 0x80000000U) ? ((crc << 1) ^ 0x04C11DB7U) : (crc << 1);
        }
    }
    return crc;
}

static void MBDWritePATPacket(uint8_t pkt[188], uint8_t cc, uint16_t tsid, uint16_t serviceId, uint16_t pmtPid) {
    memset(pkt, 0xFF, 188);
    pkt[0] = 0x47;
    pkt[1] = 0x40; // PUSI=1, PID=0x0000
    pkt[2] = 0x00;
    pkt[3] = (uint8_t)(0x10 | (cc & 0x0F));
    pkt[4] = 0x00; // pointer_field

    uint8_t *sec = &pkt[5];
    sec[0] = 0x00; // table_id = PAT
    sec[1] = 0xB0; // section_syntax_indicator=1, section_length=13
    sec[2] = 13;
    sec[3] = (uint8_t)(tsid >> 8);
    sec[4] = (uint8_t)(tsid & 0xFF);
    sec[5] = 0xC1; // version 0, current_next=1
    sec[6] = 0x00;
    sec[7] = 0x00;
    sec[8] = (uint8_t)(serviceId >> 8);
    sec[9] = (uint8_t)(serviceId & 0xFF);
    sec[10] = (uint8_t)(0xE0 | ((pmtPid >> 8) & 0x1F));
    sec[11] = (uint8_t)(pmtPid & 0xFF);
    uint32_t crc = MBDCRC32MPEG2(sec, 12);
    sec[12] = (uint8_t)(crc >> 24);
    sec[13] = (uint8_t)(crc >> 16);
    sec[14] = (uint8_t)(crc >> 8);
    sec[15] = (uint8_t)(crc & 0xFF);
}

static void MBDWritePayloadPacket(uint8_t pkt[188], uint16_t pid, uint8_t cc, uint8_t fillByte) {
    pkt[0] = 0x47;
    pkt[1] = (uint8_t)((pid >> 8) & 0x1F);
    pkt[2] = (uint8_t)(pid & 0xFF);
    pkt[3] = (uint8_t)(0x10 | (cc & 0x0F));
    memset(&pkt[4], fillByte, 184);
}

@interface MBDSampleUSBDriver : NSObject <
    MacBonDriver,
    MacBonDriverMultiTuner,
    MacBonDriverLNBControl,
    MacBonDriverTSMF,
    MacBonDriverSmartCard
>
@end

@implementation MBDSampleUSBDriver {
    NSBundle *_bundle;
    NSArray<NSDictionary<NSString *, id> *> *_spaces;
    NSUInteger _deviceIndex;

    pthread_mutex_t _ctrlLock;
    pthread_mutex_t _streamLock;
    pthread_cond_t _streamCond;
    pthread_mutex_t _cardLock;

    BOOL _tunerOpen;
    NSUInteger _currentSpace;
    NSUInteger _currentChannel;
    uint16_t _currentStreamID;
    MBDLNBPowerMode _lnbMode;

    NSMutableArray<NSData *> *_chunkQueue;
    NSData *_activeChunk;
    uint64_t _droppedChunks;
    uint32_t _streamEpoch;

    dispatch_source_t _producerTimer;
    dispatch_queue_t _producerQueue;
    uint8_t _patCC;
    uint8_t _videoCC;

    BOOL _cardOpen;
    NSData *_cardATR;
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
    if (!self) {
        return nil;
    }

    _bundle = bundle ?: [NSBundle bundleForClass:[self class]];
    _currentSpace = MBDInvalidIndex;
    _currentChannel = MBDInvalidIndex;
    _currentStreamID = 0;
    _lnbMode = MBDLNBPowerOff;
    _chunkQueue = [NSMutableArray arrayWithCapacity:kMaxQueueChunks];
    _producerQueue = dispatch_queue_create("jp.macbondriver.sample-usb.producer", DISPATCH_QUEUE_SERIAL);

    NSNumber *devIdx = options[MBDOptionDeviceIndexKey];
    _deviceIndex = devIdx ? devIdx.unsignedIntegerValue : 0;

    pthread_mutex_init(&_ctrlLock, NULL);
    pthread_mutex_init(&_streamLock, NULL);
    pthread_cond_init(&_streamCond, NULL);
    pthread_mutex_init(&_cardLock, NULL);

    static const uint8_t kSampleBCASATR[] = {
        0x3B, 0xF0, 0x12, 0x00, 0xFF, 0x91, 0x81, 0xB1,
        0x7C, 0x45, 0x1F, 0x03, 0x99
    };
    _cardATR = [NSData dataWithBytes:kSampleBCASATR length:sizeof(kSampleBCASATR)];

    if (![self loadChannelSetWithOptions:options error:error]) {
        return nil;
    }
    return self;
}

- (void)dealloc {
    [self closeTuner];
    [self closeSmartCard];
    pthread_mutex_destroy(&_cardLock);
    pthread_cond_destroy(&_streamCond);
    pthread_mutex_destroy(&_streamLock);
    pthread_mutex_destroy(&_ctrlLock);
}

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
        chSetURL = [_bundle URLForResource:@"MBD_SampleUSB.ChSet" withExtension:@"plist"];
    }
    if (!chSetURL) {
        if (error) {
            *error = MBDMakeError(MBDErrorConfigInvalid, @"MBD_SampleUSB.ChSet.plist not found in bundle Resources");
        }
        return NO;
    }

    NSDictionary *root = [NSDictionary dictionaryWithContentsOfURL:chSetURL];
    NSArray *spaces = root[@"Spaces"];
    if (![spaces isKindOfClass:[NSArray class]] || spaces.count == 0) {
        if (error) {
            *error = MBDMakeError(MBDErrorConfigInvalid, @"Invalid ChSet.plist structure");
        }
        return NO;
    }
    _spaces = [spaces copy];
    return YES;
}

#pragma mark - MacBonDriver Core

- (NSString *)tunerName {
    NSString *display = _bundle.infoDictionary[MBDInfoDisplayNameKey];
    return display ?: @"Sample USB ISDB-T/S/C Driver";
}

- (BOOL)isTunerOpen {
    pthread_mutex_lock(&_ctrlLock);
    BOOL open = _tunerOpen;
    pthread_mutex_unlock(&_ctrlLock);
    return open;
}

- (NSUInteger)currentSpace {
    pthread_mutex_lock(&_ctrlLock);
    NSUInteger space = _currentSpace;
    pthread_mutex_unlock(&_ctrlLock);
    return space;
}

- (NSUInteger)currentChannel {
    pthread_mutex_lock(&_ctrlLock);
    NSUInteger ch = _currentChannel;
    pthread_mutex_unlock(&_ctrlLock);
    return ch;
}

- (float)signalLevel {
    pthread_mutex_lock(&_ctrlLock);
    BOOL locked = (_tunerOpen && _currentSpace != MBDInvalidIndex && _currentChannel != MBDInvalidIndex);
    NSUInteger space = _currentSpace;
    pthread_mutex_unlock(&_ctrlLock);
    if (!locked) {
        return 0.0f;
    }
    return (space == 1) ? 16.5f : 28.4f;
}

- (BOOL)openTunerWithError:(NSError * _Nullable * _Nullable)error {
    pthread_mutex_lock(&_ctrlLock);
    if (_tunerOpen) {
        pthread_mutex_unlock(&_ctrlLock);
        if (error) {
            *error = MBDMakeError(MBDErrorAlreadyOpen, @"Tuner is already open");
        }
        return NO;
    }
    _tunerOpen = YES;
    _currentSpace = MBDInvalidIndex;
    _currentChannel = MBDInvalidIndex;
    _currentStreamID = 0;

    pthread_mutex_lock(&_streamLock);
    [_chunkQueue removeAllObjects];
    _activeChunk = nil;
    _droppedChunks = 0;
    _streamEpoch++;
    pthread_mutex_unlock(&_streamLock);

    pthread_mutex_unlock(&_ctrlLock);
    return YES;
}

- (void)closeTuner {
    pthread_mutex_lock(&_ctrlLock);
    [self stopProducerLocked];
    _tunerOpen = NO;
    _currentSpace = MBDInvalidIndex;
    _currentChannel = MBDInvalidIndex;
    _currentStreamID = 0;
    _lnbMode = MBDLNBPowerOff;

    pthread_mutex_lock(&_streamLock);
    [_chunkQueue removeAllObjects];
    _activeChunk = nil;
    _streamEpoch++;
    pthread_cond_broadcast(&_streamCond);
    pthread_mutex_unlock(&_streamLock);

    pthread_mutex_unlock(&_ctrlLock);
}

- (nullable NSString *)tuningSpaceNameAtIndex:(NSUInteger)space {
    if (space >= _spaces.count) {
        return nil;
    }
    return _spaces[space][@"Name"];
}

- (nullable NSString *)channelNameInSpace:(NSUInteger)space channel:(NSUInteger)channel {
    if (space >= _spaces.count) {
        return nil;
    }
    NSArray *channels = _spaces[space][@"Channels"];
    if (![channels isKindOfClass:[NSArray class]] || channel >= channels.count) {
        return nil;
    }
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
    pthread_mutex_lock(&_ctrlLock);
    if (!_tunerOpen) {
        pthread_mutex_unlock(&_ctrlLock);
        if (error) {
            *error = MBDMakeError(MBDErrorNotOpen, @"Tuner must be open before tuning");
        }
        return NO;
    }
    if (space >= _spaces.count) {
        pthread_mutex_unlock(&_ctrlLock);
        if (error) {
            *error = MBDMakeError(MBDErrorInvalidSpaceOrChannel, @"Tuning space index out of range");
        }
        return NO;
    }
    NSArray *channels = _spaces[space][@"Channels"];
    if (![channels isKindOfClass:[NSArray class]] || channel >= channels.count) {
        pthread_mutex_unlock(&_ctrlLock);
        if (error) {
            *error = MBDMakeError(MBDErrorInvalidSpaceOrChannel, @"Channel index out of range");
        }
        return NO;
    }

    NSDictionary *chDict = channels[channel];
    NSNumber *defaultStreamID = chDict[@"StreamID"];
    uint16_t effectiveStreamID = overrideStreamID
        ? streamID
        : (uint16_t)(defaultStreamID ? defaultStreamID.unsignedShortValue : (uint16_t)(0x4000U + space * 16U + channel));

    _currentSpace = space;
    _currentChannel = channel;
    _currentStreamID = effectiveStreamID;

    pthread_mutex_lock(&_streamLock);
    [_chunkQueue removeAllObjects];
    _droppedChunks = 0;
    _streamEpoch++;
    pthread_cond_broadcast(&_streamCond);
    pthread_mutex_unlock(&_streamLock);

    // Emit initial chunk immediately and start periodic TS producer
    [self enqueueSyntheticChunkWithStreamID:effectiveStreamID channel:(uint8_t)channel];
    [self startProducerLockedWithStreamID:effectiveStreamID channel:(uint8_t)channel];
    pthread_mutex_unlock(&_ctrlLock);

    id<MacBonDriverDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:@selector(bonDriver:didReceiveEvent:userInfo:)]) {
        dispatch_async(_producerQueue, ^{
            [delegate bonDriver:self
                didReceiveEvent:MBDEventSignalLockChanged
                       userInfo:@{@"locked": @YES, @"space": @(space), @"channel": @(channel)}];
        });
    }
    return YES;
}

- (void)startProducerLockedWithStreamID:(uint16_t)streamID channel:(uint8_t)channel {
    [self stopProducerLocked];
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _producerQueue);
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_MSEC),
                              15 * NSEC_PER_MSEC,
                              2 * NSEC_PER_MSEC);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        typeof(self) strongSelf = weakSelf;
        if (strongSelf) {
            [strongSelf enqueueSyntheticChunkWithStreamID:streamID channel:channel];
        }
    });
    _producerTimer = timer;
    dispatch_resume(timer);
}

- (void)stopProducerLocked {
    if (_producerTimer) {
        dispatch_source_cancel(_producerTimer);
        _producerTimer = nil;
    }
}

- (void)enqueueSyntheticChunkWithStreamID:(uint16_t)streamID channel:(uint8_t)channel {
    NSMutableData *chunk = [NSMutableData dataWithLength:kChunkBytes];
    uint8_t *buf = (uint8_t *)chunk.mutableBytes;
    uint16_t serviceId = (uint16_t)(101U + channel);

    pthread_mutex_lock(&_streamLock);
    for (NSUInteger i = 0; i < kChunkPackets; i++) {
        uint8_t *pkt = buf + (i * MBDTSPacketSize);
        if (i % 16 == 0) {
            MBDWritePATPacket(pkt, _patCC++, streamID ? streamID : 1, serviceId, 0x0100);
        } else {
            MBDWritePayloadPacket(pkt, 0x0101, _videoCC++, (uint8_t)(0xA0 + channel));
        }
    }
    if (_chunkQueue.count >= kMaxQueueChunks) {
        [_chunkQueue removeObjectAtIndex:0];
        _droppedChunks++;
    }
    [_chunkQueue addObject:chunk];
    pthread_cond_signal(&_streamCond);
    pthread_mutex_unlock(&_streamLock);
}

#pragma mark - TS Stream Path

- (MBDWaitResult)waitTSStreamWithTimeoutMs:(uint32_t)timeoutMs {
    pthread_mutex_lock(&_streamLock);
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
    uint64_t addNsec = (uint64_t)timeoutMs * 1000000ULL;
    ts.tv_sec += (time_t)(addNsec / 1000000000ULL);
    ts.tv_nsec += (long)(addNsec % 1000000000ULL);
    if (ts.tv_nsec >= 1000000000L) {
        ts.tv_sec += 1;
        ts.tv_nsec -= 1000000000L;
    }

    int rc = 0;
    while (_tunerOpen && _streamEpoch == startEpoch && _chunkQueue.count == 0 && rc == 0) {
        rc = pthread_cond_timedwait(&_streamCond, &_streamLock, &ts);
    }

    MBDWaitResult result;
    if (!_tunerOpen || _streamEpoch != startEpoch) {
        result = MBDWaitResultClosed;
    } else if (_chunkQueue.count > 0) {
        result = MBDWaitResultReady;
    } else {
        result = MBDWaitResultTimeout;
    }
    pthread_mutex_unlock(&_streamLock);
    return result;
}

- (NSUInteger)readyStreamCount {
    pthread_mutex_lock(&_streamLock);
    NSUInteger count = _chunkQueue.count;
    pthread_mutex_unlock(&_streamLock);
    return count;
}

- (BOOL)getTSStreamChunk:(const uint8_t * _Nullable * _Nonnull)outBytes
                  length:(NSUInteger *)outLength
          remainingCount:(nullable NSUInteger *)outRemaining
                   error:(NSError * _Nullable * _Nullable)error {
    if (!outBytes || !outLength) {
        if (error) {
            *error = MBDMakeError(MBDErrorInvalidArgument, @"outBytes and outLength must not be NULL");
        }
        return NO;
    }

    pthread_mutex_lock(&_streamLock);
    if (!_tunerOpen) {
        pthread_mutex_unlock(&_streamLock);
        *outBytes = NULL;
        *outLength = 0;
        if (outRemaining) *outRemaining = 0;
        if (error) {
            *error = MBDMakeError(MBDErrorNotOpen, @"Tuner is not open");
        }
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
    if (outRemaining) {
        *outRemaining = _chunkQueue.count;
    }
    pthread_mutex_unlock(&_streamLock);
    return YES;
}

- (BOOL)readTSStreamIntoBuffer:(uint8_t *)buffer
                      capacity:(NSUInteger)capacity
                     bytesRead:(NSUInteger *)outBytesRead
                remainingCount:(nullable NSUInteger *)outRemaining
                         error:(NSError * _Nullable * _Nullable)error {
    if (!buffer || !outBytesRead) {
        if (error) {
            *error = MBDMakeError(MBDErrorInvalidArgument, @"buffer and outBytesRead must not be NULL");
        }
        return NO;
    }

    pthread_mutex_lock(&_streamLock);
    if (!_tunerOpen) {
        pthread_mutex_unlock(&_streamLock);
        *outBytesRead = 0;
        if (outRemaining) *outRemaining = 0;
        if (error) {
            *error = MBDMakeError(MBDErrorNotOpen, @"Tuner is not open");
        }
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
        if (error) {
            *error = MBDMakeError(MBDErrorBufferTooSmall, @"Destination buffer is smaller than TS chunk");
        }
        return NO;
    }

    memcpy(buffer, nextChunk.bytes, nextChunk.length);
    [_chunkQueue removeObjectAtIndex:0];
    *outBytesRead = nextChunk.length;
    if (outRemaining) {
        *outRemaining = _chunkQueue.count;
    }
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
    BOOL locked = (cnr > 0.0f);
    pthread_mutex_lock(&_streamLock);
    uint64_t dropped = _droppedChunks;
    pthread_mutex_unlock(&_streamLock);

    return @{
        MBDSignalStatCNRKey: @(cnr),
        MBDSignalStatRSSIKey: locked ? @(-52.0) : @(-100.0),
        MBDSignalStatLockedKey: @(locked),
        MBDSignalStatBERKey: @(0.0),
        MBDSignalStatDroppedChunksKey: @(dropped),
        MBDSignalStatUSBErrorCountKey: @(0ULL),
    };
}

- (nullable NSDictionary<MBDChannelInfoKey, id> *)channelInfoForSpace:(NSUInteger)space
                                                              channel:(NSUInteger)channel {
    if (space >= _spaces.count) {
        return nil;
    }
    NSDictionary *spaceDict = _spaces[space];
    NSArray *channels = spaceDict[@"Channels"];
    if (![channels isKindOfClass:[NSArray class]] || channel >= channels.count) {
        return nil;
    }
    NSDictionary *ch = channels[channel];
    NSString *sysStr = spaceDict[@"System"];
    MBDBroadcastSystem sys = MBDBroadcastSystemUnspecified;
    if ([sysStr isEqualToString:@"ISDB-T"]) sys = MBDBroadcastSystemISDBT;
    else if ([sysStr isEqualToString:@"ISDB-S"]) sys = MBDBroadcastSystemISDBS;
    else if ([sysStr isEqualToString:@"ISDB-C"]) sys = MBDBroadcastSystemISDBC;
    else if ([sysStr isEqualToString:@"ISDB-S3"]) sys = MBDBroadcastSystemISDBS3;

    MBDChannelFlags flags = MBDChannelFlagNone;
    for (NSString *flagName in ch[@"Flags"]) {
        if ([flagName isEqualToString:@"TSMF"]) flags |= MBDChannelFlagTSMF;
        else if ([flagName isEqualToString:@"RawTSMF"]) flags |= MBDChannelFlagRawTSMF;
        else if ([flagName isEqualToString:@"CATV"]) flags |= MBDChannelFlagCATV;
    }

    return @{
        MBDChannelInfoSystemKey: @(sys),
        MBDChannelInfoFrequencyKHzKey: ch[@"FrequencyKHz"] ?: @(0),
        MBDChannelInfoBandwidthKHzKey: ch[@"BandwidthKHz"] ?: @(6000),
        MBDChannelInfoStreamIDKey: ch[@"StreamID"] ?: @(0),
        MBDChannelInfoFlagsKey: @(flags),
    };
}

#pragma mark - MacBonDriverMultiTuner

- (NSUInteger)totalDeviceCount {
    return 1;
}

- (NSUInteger)activeDeviceCount {
    return self.isTunerOpen ? 1 : 0;
}

- (NSArray<NSDictionary<MBDDeviceInfoKey, id> *> *)enumerateDevices {
    return @[
        @{
            MBDDeviceInfoIndexKey: @(_deviceIndex),
            MBDDeviceInfoNameKey: @"Sample USB ISDB-T/S/C Receiver #0",
            MBDDeviceInfoVendorIDKey: @(0x06B8),
            MBDDeviceInfoProductIDKey: @(0x106B),
            MBDDeviceInfoLocationIDKey: @(0x01100000U),
            MBDDeviceInfoSerialNumberKey: @"MBD-SAMPLE-0001",
            MBDDeviceInfoSystemsKey: @[@"ISDB-T", @"ISDB-S", @"ISDB-C"],
            MBDDeviceInfoInUseKey: @(self.isTunerOpen),
        }
    ];
}

#pragma mark - MacBonDriverLNBControl

- (BOOL)supportsLNBPower {
    return YES;
}

- (MBDLNBPowerMode)currentLNBPowerMode {
    pthread_mutex_lock(&_ctrlLock);
    MBDLNBPowerMode mode = _lnbMode;
    pthread_mutex_unlock(&_ctrlLock);
    return mode;
}

- (BOOL)setLNBPowerMode:(MBDLNBPowerMode)mode
                  error:(NSError * _Nullable * _Nullable)error {
    pthread_mutex_lock(&_ctrlLock);
    if (!_tunerOpen) {
        pthread_mutex_unlock(&_ctrlLock);
        if (error) {
            *error = MBDMakeError(MBDErrorNotOpen, @"Tuner must be open to control LNB power");
        }
        return NO;
    }
    _lnbMode = mode;
    pthread_mutex_unlock(&_ctrlLock);
    return YES;
}

#pragma mark - MacBonDriverTSMF

- (BOOL)supportsTSMF {
    return YES;
}

- (uint16_t)currentStreamID {
    pthread_mutex_lock(&_ctrlLock);
    uint16_t sid = _currentStreamID;
    pthread_mutex_unlock(&_ctrlLock);
    return sid;
}

#pragma mark - MacBonDriverSmartCard

- (nullable NSString *)cardReaderName {
    return @"Sample USB Built-in Smart Card Reader";
}

- (BOOL)isCardOpen {
    pthread_mutex_lock(&_cardLock);
    BOOL open = _cardOpen;
    pthread_mutex_unlock(&_cardLock);
    return open;
}

- (BOOL)openSmartCardWithError:(NSError * _Nullable * _Nullable)error {
    pthread_mutex_lock(&_cardLock);
    if (_cardOpen) {
        pthread_mutex_unlock(&_cardLock);
        if (error) {
            *error = MBDMakeError(MBDErrorAlreadyOpen, @"Smart card session is already open");
        }
        return NO;
    }
    _cardOpen = YES;
    pthread_mutex_unlock(&_cardLock);
    return YES;
}

- (void)closeSmartCard {
    pthread_mutex_lock(&_cardLock);
    _cardOpen = NO;
    pthread_mutex_unlock(&_cardLock);
}

- (BOOL)isCardPresent:(BOOL *)outPresent
                  atr:(NSData * _Nullable * _Nullable)outATR
                error:(NSError * _Nullable * _Nullable)error {
    if (!outPresent) {
        if (error) {
            *error = MBDMakeError(MBDErrorInvalidArgument, @"outPresent must not be NULL");
        }
        return NO;
    }
    pthread_mutex_lock(&_cardLock);
    if (!_cardOpen) {
        pthread_mutex_unlock(&_cardLock);
        if (error) {
            *error = MBDMakeError(MBDErrorNotOpen, @"Smart card session is not open");
        }
        return NO;
    }
    *outPresent = YES;
    if (outATR) {
        *outATR = _cardATR;
    }
    pthread_mutex_unlock(&_cardLock);
    return YES;
}

- (BOOL)resetSmartCardReturningATR:(NSData * _Nullable * _Nullable)outATR
                             error:(NSError * _Nullable * _Nullable)error {
    pthread_mutex_lock(&_cardLock);
    if (!_cardOpen) {
        pthread_mutex_unlock(&_cardLock);
        if (error) {
            *error = MBDMakeError(MBDErrorNotOpen, @"Smart card session is not open");
        }
        return NO;
    }
    if (outATR) {
        *outATR = _cardATR;
    }
    pthread_mutex_unlock(&_cardLock);
    return YES;
}

- (nullable NSData *)transmitAPDU:(NSData *)commandAPDU
                            error:(NSError * _Nullable * _Nullable)error {
    if (!commandAPDU || commandAPDU.length < 4 || commandAPDU.length > 512) {
        if (error) {
            *error = MBDMakeError(MBDErrorInvalidArgument, @"Command APDU length must be 4..512 bytes");
        }
        return nil;
    }
    pthread_mutex_lock(&_cardLock);
    if (!_cardOpen) {
        pthread_mutex_unlock(&_cardLock);
        if (error) {
            *error = MBDMakeError(MBDErrorNotOpen, @"Smart card session is not open");
        }
        return nil;
    }
    pthread_mutex_unlock(&_cardLock);

    // Return synthetic response payload + SW1=0x90, SW2=0x00 (Normal processing)
    static const uint8_t kOKResponse[] = {
        0x00, 0x3A, 0x00, 0x00, 0x21, 0x00, 0x90, 0x00
    };
    return [NSData dataWithBytes:kOKResponse length:sizeof(kOKResponse)];
}

@end
