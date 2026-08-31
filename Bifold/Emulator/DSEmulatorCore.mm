//
//  DSEmulatorCore.mm
//  Bifold
//
//  The melonDS bridge. One melonDS::NDS instance per loaded ROM; every call
//  in here happens under EmulatorSession's lock (see the header).
//

#import "DSEmulatorCore.h"
#include "BifoldCoreState.h"

#include "NDS.h"
#include "NDSCart.h"
#include "GBACart.h"
#include "NDS_Header.h"
#include "Args.h"
#include "GPU.h"
#include "GPU3D_Soft.h"
#include "SPU.h"
#include "SPI.h"
#include "RTC.h"
#include "Savestate.h"
#include "Platform.h"
#include "version.h"

#include <memory>
#include <string>

using namespace melonDS;

static NSString* const BifoldErrorDomain = @"com.redfernsoutpost.bifold.emulator";

static const NSUInteger kScreenWidth = 256;
static const NSUInteger kScreenHeight = 192;
static const double kOutputSampleRate = 48000.0;

@implementation DSEmulatorCore {
    NDS* _nds;
    BifoldCoreState* _state;
    NSURL* _saveDirectory;
    NSString* _gameTitle;
    NSString* _gameCode;
    NSString* _bannerTitle;
    NSData* _bannerIcon;
    std::string _romFileName;
    uint32_t _frameCounter;
    int _lastSaveWrites;
    BOOL _reportedStop;
}

- (instancetype)initWithSaveDirectory:(NSURL *)saveDirectory
                      systemDirectory:(NSURL *)systemDirectory {
    self = [super init];
    if (!self) return nil;
    _saveDirectory = saveDirectory;
    _gameTitle = @"";
    _gameCode = @"";
    _state = new BifoldCoreState();

    NSFileManager* fm = NSFileManager.defaultManager;
    [fm createDirectoryAtURL:saveDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtURL:systemDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    BifoldPlatform::SystemDirectory = std::string(systemDirectory.path.UTF8String);
    return self;
}

- (void)dealloc {
    [self destroyConsole];
    delete _state;
}

#pragma mark - Console lifecycle

- (void)destroyConsole {
    if (_nds) {
        delete _nds;
        _nds = nullptr;
    }
}

/// Builds a fresh console: FreeBIOS, generated firmware, interpreter CPU,
/// threaded software rasteriser, 48 kHz resampled audio.
- (void)createConsole {
    [self destroyConsole];
    NDSArgs args {};
    args.JIT = std::nullopt;                     // no executable memory on iOS
    args.Interpolation = AudioInterpolation::Linear;
    args.OutputSampleRate = kOutputSampleRate;
    args.GDB = std::nullopt;
    _nds = new NDS(std::move(args), _state);
    auto& renderer = static_cast<SoftRenderer&>(_nds->GetRenderer3D());
    renderer.SetThreaded(true, _nds->GPU);
}

/// Reset + direct boot + start, shared by loadROM and reset.
- (void)bootLoadedCart {
    _nds->Reset();
    _nds->SetupDirectBoot(_romFileName);
    _nds->SPI.GetPowerMan()->SetBatteryLevelOkay(true);

    NSDateComponents* now = [NSCalendar.currentCalendar
        components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay |
                    NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond)
          fromDate:NSDate.date];
    _nds->RTC.SetDateTime((int)now.year, (int)now.month, (int)now.day,
                          (int)now.hour, (int)now.minute, (int)now.second);

    _state->stopReason.store(-1);
    _reportedStop = NO;
    _frameCounter = 0;
    _nds->Start();
}

#pragma mark - ROM

- (BOOL)isROMLoaded {
    return _nds != nullptr;
}

- (NSString *)gameTitle { return _gameTitle; }
- (NSString *)gameCode { return _gameCode; }
- (NSString *)bannerTitle { return _bannerTitle; }
- (NSData *)bannerIconRGBA { return _bannerIcon; }

- (BOOL)loadROMAtURL:(NSURL *)romURL error:(NSError **)error {
    NSError* readError = nil;
    NSData* romData = [NSData dataWithContentsOfURL:romURL options:NSDataReadingMappedIfSafe error:&readError];
    if (!romData || romData.length < 0x200) {
        if (error) {
            *error = [NSError errorWithDomain:BifoldErrorDomain code:1 userInfo:@{
                NSLocalizedDescriptionKey: @"Couldn't read that file",
                NSUnderlyingErrorKey: readError ?: [NSError errorWithDomain:BifoldErrorDomain code:0 userInfo:nil]
            }];
        }
        return NO;
    }

    [self unloadROM];

    auto romCopy = std::make_unique<u8[]>(romData.length);
    memcpy(romCopy.get(), romData.bytes, romData.length);

    // Battery save lives next to the other saves as "<rom base>.sav".
    NSString* base = romURL.lastPathComponent.stringByDeletingPathExtension;
    NSURL* saveURL = [_saveDirectory URLByAppendingPathComponent:[base stringByAppendingPathExtension:@"sav"]];
    std::unique_ptr<u8[]> sram;
    u32 sramLength = 0;
    NSData* savData = [NSData dataWithContentsOfURL:saveURL];
    if (savData.length > 0) {
        sram = std::make_unique<u8[]>(savData.length);
        memcpy(sram.get(), savData.bytes, savData.length);
        sramLength = (u32)savData.length;
    }

    NDSCart::NDSCartArgs cartArgs {};
    cartArgs.SDCard = std::nullopt;
    cartArgs.SRAM = std::move(sram);
    cartArgs.SRAMLength = sramLength;
    auto cart = NDSCart::ParseROM(std::move(romCopy), (u32)romData.length, _state, std::move(cartArgs));
    if (!cart) {
        if (error) {
            *error = [NSError errorWithDomain:BifoldErrorDomain code:2 userInfo:@{
                NSLocalizedDescriptionKey: @"That file doesn't look like a DS ROM"
            }];
        }
        return NO;
    }

    [self captureMetadataFromCart:cart.get()];
    _romFileName = std::string(romURL.lastPathComponent.UTF8String);
    _state->savePath = std::string(saveURL.path.UTF8String);
    _state->saveWrites.store(0);
    _lastSaveWrites = 0;

    [self createConsole];
    _nds->SetNDSCart(std::move(cart));
    if (self.insertRumblePak) {
        _nds->SetGBACart(GBACart::LoadAddon(GBAAddon_RumblePak, _state));
    }
    [self bootLoadedCart];
    return YES;
}

- (void)captureMetadataFromCart:(NDSCart::CartCommon *)cart {
    const NDSHeader& header = cart->GetHeader();

    char title[13] = {0};
    memcpy(title, header.GameTitle, 12);
    _gameTitle = [[[NSString alloc] initWithBytes:title length:strlen(title) encoding:NSASCIIStringEncoding]
                     stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] ?: @"";

    char code[5] = {0};
    memcpy(code, header.GameCode, 4);
    _gameCode = [[NSString alloc] initWithBytes:code length:strlen(code) encoding:NSASCIIStringEncoding] ?: @"";

    _bannerTitle = nil;
    _bannerIcon = nil;
    const NDSBanner* banner = cart->Banner();
    if (!banner) return;

    // 32×32 icon: 4bpp 8×8 tiles + an RGB555 palette, index 0 transparent.
    uint32_t palette[16];
    for (int i = 0; i < 16; i++) {
        uint32_t r = ((banner->Palette[i] >> 0)  & 0x1F) * 255 / 31;
        uint32_t g = ((banner->Palette[i] >> 5)  & 0x1F) * 255 / 31;
        uint32_t b = ((banner->Palette[i] >> 10) & 0x1F) * 255 / 31;
        uint32_t a = i ? 255 : 0;
        palette[i] = r | (g << 8) | (b << 16) | (a << 24);
    }
    uint32_t pixels[32 * 32];
    int count = 0;
    for (int ytile = 0; ytile < 4; ytile++) {
        for (int xtile = 0; xtile < 4; xtile++) {
            for (int ypixel = 0; ypixel < 8; ypixel++) {
                for (int xpixel = 0; xpixel < 8; xpixel++) {
                    uint8_t index = (count & 1) ? (banner->Icon[count / 2] >> 4)
                                                : (banner->Icon[count / 2] & 0x0F);
                    pixels[ytile * 256 + ypixel * 32 + xtile * 8 + xpixel] = palette[index];
                    count++;
                }
            }
        }
    }
    _bannerIcon = [NSData dataWithBytes:pixels length:sizeof(pixels)];

    NSUInteger titleLength = 0;
    while (titleLength < 128 && banner->EnglishTitle[titleLength] != 0) titleLength++;
    if (titleLength > 0) {
        _bannerTitle = [[NSString alloc] initWithCharacters:(const unichar *)banner->EnglishTitle
                                                     length:titleLength];
    }
}

- (void)unloadROM {
    if (!_nds) return;
    [self flushSaveData];
    [self destroyConsole];
    _state->savePath.clear();
    _romFileName.clear();
    _gameTitle = @"";
    _gameCode = @"";
    _bannerTitle = nil;
    _bannerIcon = nil;
}

- (void)reset {
    if (!_nds) return;
    [self bootLoadedCart];
}

#pragma mark - Execution

- (void)runFrame {
    if (!_nds) return;
    _nds->RunFrame();
    _frameCounter++;

    int writes = _state->saveWrites.load();
    if (writes != _lastSaveWrites) {
        _lastSaveWrites = writes;
        id<DSEmulatorCoreDelegate> delegate = self.delegate;
        if ([delegate respondsToSelector:@selector(emulatorCoreDidWriteSaveData:)]) {
            [delegate emulatorCoreDidWriteSaveData:self];
        }
    }

    int stop = _state->stopReason.load();
    if (stop >= 0 && !_reportedStop) {
        _reportedStop = YES;
        id<DSEmulatorCoreDelegate> delegate = self.delegate;
        if ([delegate respondsToSelector:@selector(emulatorCore:didStopWithReason:)]) {
            [delegate emulatorCore:self didStopWithReason:(DSStopReason)stop];
        }
    }
}

- (uint32_t)frameCounter { return _frameCounter; }

- (BOOL)consoleRunning {
    return _nds != nullptr && _nds->IsRunning();
}

- (void)setKeys:(DSKeyMask)keys {
    if (!_nds) return;
    _nds->SetKeyMask(~(u32)keys & 0xFFF);
}

- (void)touchScreenAtX:(NSInteger)x y:(NSInteger)y {
    if (!_nds) return;
    x = MAX(0, MIN(255, x));
    y = MAX(0, MIN(191, y));
    _nds->TouchScreen((u16)x, (u16)y);
}

- (void)releaseScreen {
    if (!_nds) return;
    _nds->ReleaseScreen();
}

- (void)setLidClosed:(BOOL)closed {
    if (!_nds) return;
    _nds->SetLidClosed(closed);
}

#pragma mark - Microphone

- (DSMicMode)micMode {
    return (DSMicMode)_state->micMode.load();
}

- (void)setMicMode:(DSMicMode)micMode {
    _state->micMode.store((int)micMode);
}

- (void)setMicActive:(BOOL)active {
    _state->micActive.store(active);
}

- (void)submitMicSamples:(const int16_t *)samples count:(NSUInteger)count {
    uint32_t write = _state->micRingWrite.load(std::memory_order_relaxed);
    for (NSUInteger i = 0; i < count; i++) {
        _state->micRing[write % BifoldCoreState::MicRingSize] = samples[i];
        write++;
    }
    _state->micRingWrite.store(write, std::memory_order_release);
}

#pragma mark - Rumble Pak

- (BOOL)rumbleActive {
    uint64_t until = _state->rumbleUntilUS.load();
    return until != 0 && Platform::GetUSCount() < until;
}

#pragma mark - Video

- (NSUInteger)videoWidth { return kScreenWidth; }
- (NSUInteger)videoHeight { return kScreenHeight; }

- (BOOL)copyTopScreen:(uint32_t *)top bottomScreen:(uint32_t *)bottom {
    if (!_nds) return NO;
    int front = _nds->GPU.FrontBuffer;
    auto& topBuffer = _nds->GPU.Framebuffer[front][0];
    auto& bottomBuffer = _nds->GPU.Framebuffer[front][1];
    if (!topBuffer || !bottomBuffer) return NO;
    memcpy(top, topBuffer.get(), kScreenWidth * kScreenHeight * 4);
    memcpy(bottom, bottomBuffer.get(), kScreenWidth * kScreenHeight * 4);
    return YES;
}

- (NSData *)copyTopScreenData {
    NSMutableData* data = [NSMutableData dataWithLength:kScreenWidth * kScreenHeight * 4];
    if (_nds) {
        int front = _nds->GPU.FrontBuffer;
        auto& topBuffer = _nds->GPU.Framebuffer[front][0];
        if (topBuffer) {
            memcpy(data.mutableBytes, topBuffer.get(), kScreenWidth * kScreenHeight * 4);
        }
    }
    return data;
}

#pragma mark - Audio

- (NSUInteger)audioSampleRate { return (NSUInteger)kOutputSampleRate; }

- (NSUInteger)availableAudioFrames {
    if (!_nds) return 0;
    int frames = _nds->SPU.GetOutputSize();
    return frames > 0 ? (NSUInteger)frames : 0;
}

- (NSUInteger)readAudioFrames:(int16_t *)out count:(NSUInteger)frames {
    if (!_nds || frames == 0) return 0;
    int read = _nds->SPU.ReadOutput(out, (int)frames);
    return read > 0 ? (NSUInteger)read : 0;
}

- (void)clearAudio {
    if (!_nds) return;
    _nds->SPU.DrainOutput();
}

#pragma mark - Save states

- (nullable NSData *)serializeState {
    if (!_nds) return nil;
    Savestate state;
    if (state.Error) return nil;
    if (!_nds->DoSavestate(&state) || state.Error) return nil;
    return [NSData dataWithBytes:state.Buffer() length:state.Length()];
}

- (BOOL)deserializeState:(NSData *)data {
    if (!_nds || data.length == 0) return NO;
    Savestate state((void *)data.bytes, (u32)data.length, false);
    if (state.Error) return NO;
    return _nds->DoSavestate(&state) && !state.Error;
}

- (BOOL)saveStateToURL:(NSURL *)url {
    NSData* data = [self serializeState];
    if (!data) return NO;
    return [data writeToURL:url atomically:YES];
}

- (BOOL)loadStateFromURL:(NSURL *)url {
    NSData* data = [NSData dataWithContentsOfURL:url];
    if (!data) return NO;
    return [self deserializeState:data];
}

#pragma mark - Battery save

- (void)flushSaveData {
    if (!_nds || _state->savePath.empty()) return;
    const u8* sram = _nds->GetNDSSave();
    u32 length = _nds->GetNDSSaveLength();
    if (!sram || length == 0) return;
    NSData* data = [NSData dataWithBytes:sram length:length];
    [data writeToFile:[NSString stringWithUTF8String:_state->savePath.c_str()] atomically:YES];
}

#pragma mark - Misc

+ (NSString *)coreVersion {
    return [NSString stringWithFormat:@"melonDS %s", MELONDS_VERSION];
}

@end
