// SPDX-License-Identifier: MIT
// main.m — Reference host CLI & conformance checker for MacBonDriver (.bundle)

#import "MacBonDriver.h"
#include <stdio.h>
#include <string.h>

@interface MBDHostEventCollector : NSObject <MacBonDriverDelegate>
@property (atomic, readonly) NSUInteger lockEventCount;
@end

@implementation MBDHostEventCollector {
    NSUInteger _lockEventCount;
}
- (NSUInteger)lockEventCount {
    @synchronized(self) {
        return _lockEventCount;
    }
}
- (void)bonDriver:(id<MacBonDriver>)driver
  didReceiveEvent:(MBDEventType)event
         userInfo:(nullable NSDictionary<NSString *, id> *)userInfo {
    (void)driver;
    (void)userInfo;
    if (event == MBDEventSignalLockChanged) {
        @synchronized(self) {
            _lockEventCount++;
        }
    }
}
@end

static BOOL CheckCondition(BOOL cond, const char *label) {
    if (cond) {
        printf("  [PASS] %s\n", label);
        return YES;
    } else {
        fprintf(stderr, "  [FAIL] %s\n", label);
        return NO;
    }
}

static int RunDriverInfo(NSBundle *bundle, id<MacBonDriver> driver) {
    NSDictionary *info = bundle.infoDictionary;
    printf("Bundle:        %s\n", bundle.bundlePath.UTF8String);
    printf("Principal:     %s\n", NSStringFromClass(bundle.principalClass).UTF8String);
    printf("API Version:   %lu\n", (unsigned long)[bundle.principalClass apiVersion]);
    printf("Display Name:  %s\n", driver.tunerName.UTF8String);
    printf("Driver ID:     %s\n", [info[MBDInfoDriverIdentifierKey] description].UTF8String);
    printf("Systems:       %s\n", [[info[MBDInfoSupportedSystemsKey] componentsJoinedByString:@", "] UTF8String]);
    printf("Capabilities:  %s\n", [[info[MBDInfoCapabilitiesKey] componentsJoinedByString:@", "] UTF8String]);

    printf("\nTuning Spaces & Channels:\n");
    for (NSUInteger s = 0; ; s++) {
        NSString *spaceName = [driver tuningSpaceNameAtIndex:s];
        if (!spaceName) break;
        printf("  Space [%lu]: %s\n", (unsigned long)s, spaceName.UTF8String);
        for (NSUInteger c = 0; ; c++) {
            NSString *chName = [driver channelNameInSpace:s channel:c];
            if (!chName) break;
            NSDictionary *chInfo = nil;
            if ([driver respondsToSelector:@selector(channelInfoForSpace:channel:)]) {
                chInfo = [driver channelInfoForSpace:s channel:c];
            }
            uint32_t freq = [chInfo[MBDChannelInfoFrequencyKHzKey] unsignedIntValue];
            uint16_t sid = [chInfo[MBDChannelInfoStreamIDKey] unsignedShortValue];
            printf("    Ch [%lu]: %-24s (freq=%u kHz, stream_id=%u)\n",
                   (unsigned long)c, chName.UTF8String, freq, sid);
        }
    }
    return 0;
}

static int RunConformanceSuite(NSBundle *bundle, id<MacBonDriver> driver) {
    BOOL ok = YES;
    NSError *error = nil;
    printf("Running MacBonDriver v%u conformance checks on %s...\n",
           MacBonDriverAPIVersion, bundle.bundlePath.lastPathComponent.UTF8String);

    NSDictionary *info = bundle.infoDictionary;
    ok &= CheckCondition([info[MBDInfoAPIVersionKey] unsignedIntegerValue] == MacBonDriverAPIVersion,
                         "Info.plist MBDAPIVersion matches SDK");
    ok &= CheckCondition([info[MBDInfoDisplayNameKey] isKindOfClass:[NSString class]],
                         "Info.plist MBDDisplayName is present");
    ok &= CheckCondition(!driver.isTunerOpen,
                         "driverWithBundle: does not open USB device prematurely");
    ok &= CheckCondition(driver.currentSpace == MBDInvalidIndex && driver.currentChannel == MBDInvalidIndex,
                         "Untuned currentSpace/currentChannel equal MBDInvalidIndex");
    ok &= CheckCondition([driver tuningSpaceNameAtIndex:0] != nil,
                         "Enumerates tuning spaces while closed");
    ok &= CheckCondition([driver channelNameInSpace:0 channel:0] != nil,
                         "Enumerates channels while closed");

    MBDHostEventCollector *collector = [[MBDHostEventCollector alloc] init];
    driver.delegate = collector;

    ok &= CheckCondition([driver openTunerWithError:&error] && driver.isTunerOpen,
                         "openTunerWithError: succeeds and sets tunerOpen=YES");

    NSError *boundsErr = nil;
    BOOL badTune = [driver setSpace:999 channel:0 error:&boundsErr];
    ok &= CheckCondition(!badTune && boundsErr.code == MBDErrorInvalidSpaceOrChannel,
                         "Out-of-range space returns MBDErrorInvalidSpaceOrChannel");

    ok &= CheckCondition([driver setSpace:0 channel:0 error:&error],
                         "setSpace:0 channel:0 succeeds");
    ok &= CheckCondition(driver.currentSpace == 0 && driver.currentChannel == 0,
                         "currentSpace and currentChannel update after tuning");
    ok &= CheckCondition(driver.signalLevel > 0.0f,
                         "signalLevel reports positive CNR (dB) when locked");

    MBDWaitResult waitRes = [driver waitTSStreamWithTimeoutMs:500];
    ok &= CheckCondition(waitRes == MBDWaitResultReady,
                         "waitTSStreamWithTimeoutMs: returns MBDWaitResultReady");

    const uint8_t *chunkBytes = NULL;
    NSUInteger chunkLen = 0;
    NSUInteger remaining = 0;
    ok &= CheckCondition([driver getTSStreamChunk:&chunkBytes length:&chunkLen remainingCount:&remaining error:&error],
                         "getTSStreamChunk: succeeds");
    ok &= CheckCondition(chunkBytes != NULL && chunkLen > 0 && (chunkLen % MBDTSPacketSize == 0) && chunkBytes[0] == 0x47,
                         "TS chunk is 188-byte aligned and starts with sync byte 0x47");

    // Verify copy path and buffer-too-small check
    [driver waitTSStreamWithTimeoutMs:500];
    uint8_t tinyBuf[16];
    NSUInteger bytesRead = 0;
    NSError *smallErr = nil;
    BOOL smallRes = [driver readTSStreamIntoBuffer:tinyBuf capacity:sizeof(tinyBuf) bytesRead:&bytesRead remainingCount:NULL error:&smallErr];
    ok &= CheckCondition(!smallRes && smallErr.code == MBDErrorBufferTooSmall,
                         "readTSStreamIntoBuffer: rejects undersized buffer with MBDErrorBufferTooSmall");

    uint8_t copyBuf[65536];
    ok &= CheckCondition([driver readTSStreamIntoBuffer:copyBuf capacity:sizeof(copyBuf) bytesRead:&bytesRead remainingCount:NULL error:&error] &&
                         bytesRead > 0 && (bytesRead % MBDTSPacketSize == 0) && copyBuf[0] == 0x47,
                         "readTSStreamIntoBuffer: copies valid 188-byte aligned TS chunk");

    // Verify optional protocols if supported
    if ([driver conformsToProtocol:@protocol(MacBonDriverMultiTuner)]) {
        id<MacBonDriverMultiTuner> multi = (id<MacBonDriverMultiTuner>)driver;
        ok &= CheckCondition(multi.totalDeviceCount >= 1 && multi.activeDeviceCount >= 1 && multi.enumerateDevices.count >= 1,
                             "MacBonDriverMultiTuner enumerates devices and counts");
    }

    if ([driver conformsToProtocol:@protocol(MacBonDriverLNBControl)]) {
        id<MacBonDriverLNBControl> lnb = (id<MacBonDriverLNBControl>)driver;
        if (lnb.supportsLNBPower) {
            ok &= CheckCondition([lnb setLNBPowerMode:MBDLNBPower15V error:&error] && lnb.currentLNBPowerMode == MBDLNBPower15V,
                                 "MacBonDriverLNBControl switches LNB power mode");
        } else {
            NSError *lnbErr = nil;
            BOOL unsupported = ![lnb setLNBPowerMode:MBDLNBPower15V error:&lnbErr] &&
                               lnbErr.code == MBDErrorLNBNotSupported;
            ok &= CheckCondition(unsupported,
                                 "MacBonDriverLNBControl rejects 15V with MBDErrorLNBNotSupported when unsupported");
        }
    }

    if ([driver conformsToProtocol:@protocol(MacBonDriverTSMF)]) {
        id<MacBonDriverTSMF> tsmf = (id<MacBonDriverTSMF>)driver;
        NSUInteger tsmfSpace = MBDInvalidIndex;
        for (NSUInteger s = 0; ; s++) {
            if (![driver tuningSpaceNameAtIndex:s]) break;
            if ([driver respondsToSelector:@selector(channelInfoForSpace:channel:)]) {
                NSDictionary *ci = [driver channelInfoForSpace:s channel:0];
                if (([ci[MBDChannelInfoFlagsKey] unsignedIntegerValue] & MBDChannelFlagTSMF) != 0) {
                    tsmfSpace = s;
                    break;
                }
            }
        }
        if (tsmfSpace != MBDInvalidIndex) {
            ok &= CheckCondition([tsmf setSpace:tsmfSpace channel:0 streamID:1 error:&error] && tsmf.currentStreamID == 1,
                                 "MacBonDriverTSMF overrides Stream ID on ISDB-C TSMF channel");
        }
    }

    if ([driver conformsToProtocol:@protocol(MacBonDriverSmartCard)]) {
        id<MacBonDriverSmartCard> sc = (id<MacBonDriverSmartCard>)driver;
        BOOL present = NO;
        NSData *atr = nil;
        uint8_t cmdBytes[] = {0x90, 0x30, 0x00, 0x00, 0x00};
        NSData *cmd = [NSData dataWithBytes:cmdBytes length:sizeof(cmdBytes)];
        ok &= CheckCondition([sc openSmartCardWithError:&error] && sc.isCardOpen,
                             "MacBonDriverSmartCard opens smart card session");
        BOOL statusOK = [sc isCardPresent:&present atr:&atr error:&error];
        ok &= CheckCondition(statusOK, "MacBonDriverSmartCard queries card presence");
        if (statusOK && present) {
            ok &= CheckCondition(atr.length > 0,
                                 "MacBonDriverSmartCard returns non-empty ATR");
            NSData *resp = [sc transmitAPDU:cmd error:&error];
            const uint8_t *rb = (const uint8_t *)resp.bytes;
            ok &= CheckCondition(resp.length >= 2 && rb[resp.length - 2] == 0x90 && rb[resp.length - 1] == 0x00,
                                 "MacBonDriverSmartCard transmits APDU and returns SW 90 00");
        } else if (statusOK) {
            ok &= CheckCondition(YES, "MacBonDriverSmartCard reports no smart card inserted");
        }
        [sc closeSmartCard];
    }

    // Verify concurrent waitTSStream wakeup on closeTuner without deadlock
    [driver purgeTSStream];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 40 * NSEC_PER_MSEC),
                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        [driver closeTuner];
    });
    MBDWaitResult closeWake = [driver waitTSStreamWithTimeoutMs:2000];
    ok &= CheckCondition(closeWake == MBDWaitResultClosed || closeWake == MBDWaitResultReady,
                         "closeTuner wakes concurrent waitTSStream without deadlock");

    // Idempotent second closeTuner
    [driver closeTuner];
    ok &= CheckCondition(!driver.isTunerOpen,
                         "closeTuner is idempotent");

    if (ok) {
        printf("All conformance checks PASSED.\n");
        return 0;
    } else {
        fprintf(stderr, "One or more conformance checks FAILED.\n");
        return 1;
    }
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSString *bundlePath = @"build/MBD_SampleUSB.bundle";
        BOOL conformance = YES;
        BOOL infoOnly = NO;

        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--info") == 0) {
                infoOnly = YES;
                conformance = NO;
            } else if (strcmp(argv[i], "--conformance") == 0) {
                conformance = YES;
            } else {
                bundlePath = [NSString stringWithUTF8String:argv[i]];
            }
        }

        NSURL *bundleURL = [NSURL fileURLWithPath:bundlePath];
        NSBundle *bundle = [NSBundle bundleWithURL:bundleURL];
        if (!bundle) {
            fprintf(stderr, "Failed to open bundle at %s\n", bundlePath.UTF8String);
            return 1;
        }

        NSError *error = nil;
        if (![bundle loadAndReturnError:&error]) {
            fprintf(stderr, "Failed to load bundle: %s\n", error.localizedDescription.UTF8String);
            return 1;
        }

        Class principal = bundle.principalClass;
        if (![principal conformsToProtocol:@protocol(MacBonDriver)] ||
            [principal apiVersion] != MacBonDriverAPIVersion) {
            fprintf(stderr, "Principal class does not conform to MacBonDriver v%u\n", MacBonDriverAPIVersion);
            return 1;
        }

        id<MacBonDriver> driver = [principal driverWithBundle:bundle options:nil error:&error];
        if (!driver) {
            fprintf(stderr, "Failed to instantiate driver: %s\n", error.localizedDescription.UTF8String);
            return 1;
        }

        if (infoOnly) {
            return RunDriverInfo(bundle, driver);
        }
        int status = RunDriverInfo(bundle, driver);
        printf("\n");
        if (conformance) {
            status = RunConformanceSuite(bundle, driver);
        }
        return status;
    }
}
