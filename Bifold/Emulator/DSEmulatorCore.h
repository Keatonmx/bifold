//
//  DSEmulatorCore.h
//  Bifold
//
//  Objective-C++ bridge around the melonDS core (melonDS::NDS). Swift never
//  touches melonDS types directly; everything goes through this class.
//
//  Threading: the core is NOT thread-safe. EmulatorSession owns a dedicated
//  emulation thread and serialises every call into this object through its
//  own lock. The only members safe to read from any thread are the immutable
//  dimension properties.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Bit positions match melonDS's key mask layout (NDS::SetKeyMask input:
/// bits 0-9 are the GBA-style keys, bit 10 = X, bit 11 = Y). The mask handed
/// to `setKeys:` is "pressed" bits; the bridge inverts it for the hardware's
/// active-low register.
typedef NS_OPTIONS(uint32_t, DSKeyMask) {
    DSKeyMaskA      NS_SWIFT_NAME(a)      = 1u << 0,
    DSKeyMaskB      NS_SWIFT_NAME(b)      = 1u << 1,
    DSKeyMaskSelect NS_SWIFT_NAME(select) = 1u << 2,
    DSKeyMaskStart  NS_SWIFT_NAME(start)  = 1u << 3,
    DSKeyMaskRight  NS_SWIFT_NAME(right)  = 1u << 4,
    DSKeyMaskLeft   NS_SWIFT_NAME(left)   = 1u << 5,
    DSKeyMaskUp     NS_SWIFT_NAME(up)     = 1u << 6,
    DSKeyMaskDown   NS_SWIFT_NAME(down)   = 1u << 7,
    DSKeyMaskR      NS_SWIFT_NAME(r)      = 1u << 8,
    DSKeyMaskL      NS_SWIFT_NAME(l)      = 1u << 9,
    DSKeyMaskX      NS_SWIFT_NAME(x)      = 1u << 10,
    DSKeyMaskY      NS_SWIFT_NAME(y)      = 1u << 11,
};

/// Why the emulated console stopped running (mirrors Platform::StopReason).
typedef NS_ENUM(NSInteger, DSStopReason) {
    DSStopReasonUnknown = 0,
    DSStopReasonExternal = 1,
    DSStopReasonGBAModeNotSupported = 2,
    DSStopReasonBadExceptionRegion = 3,
    DSStopReasonPowerOff = 4,
};

/// What the emulated microphone hears when the MIC button is NOT held
/// (the held button always feeds blow noise).
typedef NS_ENUM(NSInteger, DSMicMode) {
    DSMicModeSilence = 0,
    /// Blow-noise only while the MIC button is held (default).
    DSMicModeBlow = 1,
    /// The phone's real microphone, fed via `submitMicSamples:count:`.
    DSMicModeExternal = 2,
};

@class DSEmulatorCore;

@protocol DSEmulatorCoreDelegate <NSObject>
@optional
/// Called on the emulation thread after the cart's battery save was written to disk.
- (void)emulatorCoreDidWriteSaveData:(DSEmulatorCore *)core;
/// Called on the emulation thread when the emulated console stopped
/// (power-off from software, unsupported mode, crash region).
- (void)emulatorCore:(DSEmulatorCore *)core didStopWithReason:(DSStopReason)reason;
@end

@interface DSEmulatorCore : NSObject

/// `saveDirectory` receives battery saves (`<rom base>.sav`).
/// `systemDirectory` is where melonDS keeps its own local files
/// (Wi-Fi settings and similar) — pass a stable folder.
- (instancetype)initWithSaveDirectory:(NSURL *)saveDirectory
                      systemDirectory:(NSURL *)systemDirectory NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, weak, nullable) id<DSEmulatorCoreDelegate> delegate;

#pragma mark - Video

/// 256 × 192, each screen.
@property (nonatomic, readonly) NSUInteger videoWidth;
@property (nonatomic, readonly) NSUInteger videoHeight;

/// Copies the front buffers (RGBA8, R in the low byte — use
/// MTLPixelFormatRGBA8Unorm) into the provided 256*192 pixel buffers.
/// Returns NO while no frame has been produced yet.
- (BOOL)copyTopScreen:(uint32_t *)top bottomScreen:(uint32_t *)bottom;

#pragma mark - ROM

@property (nonatomic, readonly) BOOL isROMLoaded;
/// Header title (up to 12 ASCII chars, e.g. "MARIOKART DS").
@property (nonatomic, readonly, copy) NSString *gameTitle;
/// 4-char game code, e.g. "AMCE".
@property (nonatomic, readonly, copy) NSString *gameCode;
/// The cart banner's English title (up to 3 lines separated by newlines).
@property (nonatomic, readonly, copy, nullable) NSString *bannerTitle;
/// The cart's 32×32 icon as RGBA8 bytes (32*32*4), or nil if absent.
- (nullable NSData *)bannerIconRGBA;

/// Loads a .nds ROM, attaches its battery save from the save directory,
/// resets and direct-boots. Creates a fresh console instance per load.
- (BOOL)loadROMAtURL:(NSURL *)romURL error:(NSError **)error NS_SWIFT_NAME(loadROM(at:));
- (void)unloadROM;
- (void)reset;

#pragma mark - Execution

/// Runs exactly one emulated frame (~16.72 ms of DS time).
- (void)runFrame;
@property (nonatomic, readonly) uint32_t frameCounter;
/// NO after the emulated console stopped itself (see the delegate callback).
@property (nonatomic, readonly) BOOL consoleRunning;

/// Replace the full key state ("pressed" bits set).
- (void)setKeys:(DSKeyMask)keys;

/// Stylus press at DS touchscreen coordinates (x 0…255, y 0…191).
- (void)touchScreenAtX:(NSInteger)x y:(NSInteger)y NS_SWIFT_NAME(touchScreen(x:y:));
- (void)releaseScreen;

/// Closing the lid puts most games to sleep; opening it wakes them.
- (void)setLidClosed:(BOOL)closed;

#pragma mark - Microphone

@property (nonatomic) DSMicMode micMode;
/// The MIC button: while active, blow noise feeds the emulated microphone.
- (void)setMicActive:(BOOL)active;
/// Real-microphone feed (mono s16, ~48 kHz); any thread, lock-free.
- (void)submitMicSamples:(const int16_t *)samples count:(NSUInteger)count;

#pragma mark - Rumble Pak

/// Insert the Slot-2 Rumble Pak on the next ROM load.
@property (nonatomic) BOOL insertRumblePak;
/// YES while the emulated pak's motor should be spinning.
@property (nonatomic, readonly) BOOL rumbleActive;

#pragma mark - DSi

/// Boot in DSi mode on the next ROM load. Needs the user's own dumps in the
/// system folder: bios7.bin, bios9.bin, firmware.bin, bios7i.bin,
/// bios9i.bin, nand.bin. Falls back to DS mode when anything is missing.
@property (nonatomic) BOOL dsiModeEnabled;
/// YES when the running console actually booted as a DSi.
@property (nonatomic, readonly) BOOL consoleIsDSi;
/// Required DSi files not found in the system folder (empty = ready).
+ (NSArray<NSString *> *)missingDSiFiles;

/// Bit 0 = outer camera, bit 1 = inner. While nonzero the session feeds
/// phone camera frames in.
@property (nonatomic, readonly) NSInteger cameraActiveMask;
/// Latest phone frame, BGRA (iOS capture layout), any size; converted and
/// scaled to the DSi's 640×480 YUY2. Any thread.
- (void)submitCameraFrameBGRA:(const uint32_t *)pixels width:(NSInteger)width height:(NSInteger)height;

#pragma mark - Audio

/// Fixed 48 kHz: the core resamples its own mixer output.
@property (nonatomic, readonly) NSUInteger audioSampleRate;
/// Number of stereo frames currently buffered by the core.
- (NSUInteger)availableAudioFrames;
/// Copies up to `frames` interleaved stereo int16 frames into `out`. Returns frames written.
- (NSUInteger)readAudioFrames:(int16_t *)out count:(NSUInteger)frames NS_SWIFT_NAME(readAudioFrames(_:count:));
- (void)clearAudio;

#pragma mark - Save states

- (BOOL)saveStateToURL:(NSURL *)url NS_SWIFT_NAME(saveState(to:));
- (BOOL)loadStateFromURL:(NSURL *)url NS_SWIFT_NAME(loadState(from:));
- (nullable NSData *)serializeState;
- (BOOL)deserializeState:(NSData *)data;

#pragma mark - Battery save

/// Battery saves are written as the game writes them; this forces a final
/// write of the current SRAM contents (call before backup/exit).
- (void)flushSaveData;

#pragma mark - Local wireless

/// One discovered session on the network.
extern NSString* const DSWirelessSessionName;
extern NSString* const DSWirelessSessionAddress;
extern NSString* const DSWirelessSessionPlayers;
extern NSString* const DSWirelessSessionMaxPlayers;

/// Switches DS local wireless between off (dummy) and the LAN backend.
+ (void)wirelessSetEnabled:(BOOL)enabled;
+ (BOOL)wirelessEnabled;
/// Browse for sessions on the network (call while the sheet is open).
+ (BOOL)wirelessStartDiscovery;
+ (void)wirelessEndDiscovery;
+ (NSArray<NSDictionary<NSString *, id> *> *)wirelessDiscoveryList;
/// Host a session; other phones on the Wi-Fi can then join it.
+ (BOOL)wirelessHostWithName:(NSString *)playerName maxPlayers:(NSInteger)maxPlayers;
+ (BOOL)wirelessJoinWithName:(NSString *)playerName hostAddress:(NSString *)address;
+ (void)wirelessEndSession;
+ (NSInteger)wirelessNumPlayers;

#pragma mark - Misc

/// Copies the current top-screen framebuffer into a fresh RGBA8 buffer
/// (used for save-state thumbnails).
- (NSData *)copyTopScreenData;
@property (class, nonatomic, readonly) NSString *coreVersion;

@end

NS_ASSUME_NONNULL_END
