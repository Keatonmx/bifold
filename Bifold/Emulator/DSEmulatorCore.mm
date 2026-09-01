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
#include "DSi.h"
#include "DSi_NAND.h"
#include "GPU.h"
#include "GPU3D_Soft.h"
#include "SPU.h"
#include "SPI.h"
#include "SPI_Firmware.h"
#include "RTC.h"
#include "Savestate.h"
#include "Platform.h"
#include "net/MPInterface.h"
#include "net/LAN.h"
#include "version.h"

#include <arpa/inet.h>

#include <algorithm>
#include <memory>
#include <string>

using namespace melonDS;

static NSString* const BifoldErrorDomain = @"com.redfernsoutpost.bifold.emulator";

static const NSUInteger kScreenWidth = 256;
static const NSUInteger kScreenHeight = 192;
static const double kOutputSampleRate = 48000.0;

static NSArray<NSString *>* const kDSiFileNames = @[
    @"bios7.bin", @"bios9.bin", @"firmware.bin",
    @"bios7i.bin", @"bios9i.bin", @"nand.bin"
];

/// Reads an exact-size system file (BIOS image) into a fixed array.
template <size_t N>
static bool LoadSystemImage(const char* name, std::array<u8, N>& out)
{
    std::string path = BifoldPlatform::SystemDirectory + "/" + name;
    FILE* f = fopen(path.c_str(), "rb");
    if (!f) return false;
    size_t got = fread(out.data(), 1, N, f);
    fclose(f);
    return got == N;
}

/// Base NDSArgs shared by both console types (interpreter, 48 kHz audio).
static NDSArgs MakeBaseArgs()
{
    NDSArgs args {};
    args.JIT = std::nullopt;                     // no executable memory on iOS
    args.Interpolation = AudioInterpolation::Linear;
    args.OutputSampleRate = kOutputSampleRate;
    args.GDB = std::nullopt;
    return args;
}

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
    BOOL _consoleIsDSi;
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

/// Builds a fresh console. DSi when enabled and all six system files parse;
/// otherwise a DS — with the user's real BIOS/firmware if they dropped them
/// into the system folder, FreeBIOS + generated firmware if not. Both get
/// the interpreter CPU, threaded software rasteriser and 48 kHz audio.
- (void)createConsole {
    [self destroyConsole];
    _consoleIsDSi = NO;
    _state->camActiveMask.store(0);
    _state->camHasFrame.store(false);

    if (self.dsiModeEnabled && DSEmulatorCore.missingDSiFiles.count == 0 && [self createDSiConsole]) {
        _consoleIsDSi = YES;
    } else {
        NDSArgs args = MakeBaseArgs();
        auto arm9 = std::make_unique<ARM9BIOSImage>();
        auto arm7 = std::make_unique<ARM7BIOSImage>();
        if (LoadSystemImage("bios9.bin", *arm9) && LoadSystemImage("bios7.bin", *arm7)) {
            args.ARM9BIOS = std::move(arm9);
            args.ARM7BIOS = std::move(arm7);
            if (Platform::FileHandle* f = Platform::OpenLocalFile("firmware.bin", Platform::FileMode::Read)) {
                Firmware firmware(f);
                Platform::CloseFile(f);
                if (firmware.Buffer()) {
                    args.Firmware = std::move(firmware);
                }
            }
        }
        _nds = new NDS(std::move(args), _state);
    }

    auto& renderer = static_cast<SoftRenderer&>(_nds->GetRenderer3D());
    renderer.SetThreaded(true, _nds->GPU);
}

/// DSi: real DS BIOS + DSi firmware + the i-BIOSes + NAND, all user-supplied.
/// Returns NO (leaving `_nds` null) if anything fails to load or parse.
- (BOOL)createDSiConsole {
    NDSArgs args = MakeBaseArgs();

    auto arm9 = std::make_unique<ARM9BIOSImage>();
    auto arm7 = std::make_unique<ARM7BIOSImage>();
    if (!LoadSystemImage("bios9.bin", *arm9) || !LoadSystemImage("bios7.bin", *arm7)) return NO;
    args.ARM9BIOS = std::move(arm9);
    args.ARM7BIOS = std::move(arm7);

    Platform::FileHandle* firmwareFile = Platform::OpenLocalFile("firmware.bin", Platform::FileMode::Read);
    if (!firmwareFile) return NO;
    Firmware firmware(firmwareFile);
    Platform::CloseFile(firmwareFile);
    if (!firmware.Buffer()) return NO;
    args.Firmware = std::move(firmware);

    auto arm9i = std::make_unique<DSiBIOSImage>();
    auto arm7i = std::make_unique<DSiBIOSImage>();
    if (!LoadSystemImage("bios9i.bin", *arm9i) || !LoadSystemImage("bios7i.bin", *arm7i)) return NO;
    // Not doing the full BIOS boot: patch the reset vectors, as the
    // reference frontend does.
    *(u32*)arm9i->data() = 0xEAFFFFFE;
    *(u32*)arm7i->data() = 0xEAFFFFFE;

    Platform::FileHandle* nandFile = Platform::OpenLocalFile("nand.bin", Platform::FileMode::ReadWriteExisting);
    if (!nandFile) return NO;
    DSi_NAND::NANDImage nand(nandFile, &(*arm7i)[0x8308]);
    if (!nand) return NO;   // the NANDImage owns the file handle

    DSiArgs dsiArgs {
        std::move(args),
        std::move(arm9i),
        std::move(arm7i),
        std::move(nand),
        std::nullopt,        // no emulated SD card in v1
        false,               // FullBIOSBoot
        false,               // DSPHLE off: teakra, the accurate DSP
    };
    _nds = new DSi(std::move(dsiArgs), _state);
    return YES;
}

+ (NSArray<NSString *> *)missingDSiFiles {
    if (BifoldPlatform::SystemDirectory.empty()) return kDSiFileNames;
    NSString* base = [NSString stringWithUTF8String:BifoldPlatform::SystemDirectory.c_str()];
    NSMutableArray<NSString *>* missing = [NSMutableArray array];
    for (NSString* name in kDSiFileNames) {
        if (![NSFileManager.defaultManager fileExistsAtPath:[base stringByAppendingPathComponent:name]]) {
            [missing addObject:name];
        }
    }
    return missing;
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
    MPInterface::Get().Process();
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

#pragma mark - DSi

- (BOOL)consoleIsDSi {
    return _consoleIsDSi;
}

- (NSInteger)cameraActiveMask {
    return _state->camActiveMask.load();
}

- (void)submitCameraFrameBGRA:(const uint32_t *)pixels width:(NSInteger)width height:(NSInteger)height {
    if (!pixels || width < 2 || height < 1) return;
    const int dw = BifoldCoreState::CamWidth;
    const int dh = BifoldCoreState::CamHeight;
    std::lock_guard<std::mutex> lock(_state->camLock);
    // Scale + RGB→YUY2, after the reference frontend's converter. BGRA bytes
    // little-endian are 0xAARRGGBB words, exactly the layout the maths wants.
    for (int dy = 0; dy < dh; dy++) {
        int sy = (int)((dy * height) / dh);
        for (int dx = 0; dx < dw; dx += 2) {
            uint32_t pixel1 = pixels[sy * width + (dx * width) / dw];
            uint32_t pixel2 = pixels[sy * width + ((dx + 1) * width) / dw];

            int r1 = (pixel1 >> 16) & 0xFF, g1 = (pixel1 >> 8) & 0xFF, b1 = pixel1 & 0xFF;
            int r2 = (pixel2 >> 16) & 0xFF, g2 = (pixel2 >> 8) & 0xFF, b2 = pixel2 & 0xFF;

            int y1 = ((r1 * 19595) + (g1 * 38470) + (b1 * 7471)) >> 16;
            int u1 = ((b1 - y1) * 32244) >> 16;
            int v1 = ((r1 - y1) * 57475) >> 16;
            int y2 = ((r2 * 19595) + (g2 * 38470) + (b2 * 7471)) >> 16;
            int u2 = ((b2 - y2) * 32244) >> 16;
            int v2 = ((r2 - y2) * 57475) >> 16;

            u1 += 128; v1 += 128;
            u2 += 128; v2 += 128;
            y1 = std::clamp(y1, 0, 255); u1 = std::clamp(u1, 0, 255); v1 = std::clamp(v1, 0, 255);
            y2 = std::clamp(y2, 0, 255); u2 = std::clamp(u2, 0, 255); v2 = std::clamp(v2, 0, 255);
            u1 = (u1 + u2) >> 1;
            v1 = (v1 + v2) >> 1;

            _state->camFrame[(dy * dw + dx) / 2] = (uint32_t)(y1 | (u1 << 8) | (y2 << 16) | (v1 << 24));
        }
    }
    _state->camHasFrame.store(true);
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

#pragma mark - Local wireless

NSString* const DSWirelessSessionName = @"name";
NSString* const DSWirelessSessionAddress = @"address";
NSString* const DSWirelessSessionPlayers = @"players";
NSString* const DSWirelessSessionMaxPlayers = @"maxPlayers";

/// The LAN backend, when it is the active MPInterface; null otherwise.
static LAN* ActiveLAN(void)
{
    if (MPInterface::GetType() != MPInterface_LAN) return nullptr;
    return static_cast<LAN*>(&MPInterface::Get());
}

+ (void)wirelessSetEnabled:(BOOL)enabled {
    if (enabled) {
        if (MPInterface::GetType() != MPInterface_LAN) {
            MPInterface::Set(MPInterface_LAN);
        }
    } else if (MPInterface::GetType() != MPInterface_Dummy) {
        if (LAN* lan = ActiveLAN()) lan->EndSession();
        MPInterface::Set(MPInterface_Dummy);
    }
}

+ (BOOL)wirelessEnabled {
    return MPInterface::GetType() == MPInterface_LAN;
}

+ (BOOL)wirelessStartDiscovery {
    LAN* lan = ActiveLAN();
    return lan ? lan->StartDiscovery() : NO;
}

+ (void)wirelessEndDiscovery {
    if (LAN* lan = ActiveLAN()) lan->EndDiscovery();
}

+ (NSArray<NSDictionary<NSString *, id> *> *)wirelessDiscoveryList {
    LAN* lan = ActiveLAN();
    if (!lan) return @[];
    NSMutableArray* sessions = [NSMutableArray array];
    for (const auto& [address, data] : lan->GetDiscoveryList()) {
        char name[65] = {0};
        memcpy(name, data.SessionName, 64);
        struct in_addr addr = { .s_addr = address };
        char dotted[INET_ADDRSTRLEN] = {0};
        inet_ntop(AF_INET, &addr, dotted, sizeof(dotted));
        [sessions addObject:@{
            DSWirelessSessionName: [NSString stringWithUTF8String:name] ?: @"Session",
            DSWirelessSessionAddress: [NSString stringWithUTF8String:dotted] ?: @"",
            DSWirelessSessionPlayers: @(data.NumPlayers),
            DSWirelessSessionMaxPlayers: @(data.MaxPlayers),
        }];
    }
    return sessions;
}

+ (BOOL)wirelessHostWithName:(NSString *)playerName maxPlayers:(NSInteger)maxPlayers {
    LAN* lan = ActiveLAN();
    if (!lan) return NO;
    return lan->StartHost(playerName.UTF8String, (int)MAX(2, MIN(16, maxPlayers)));
}

+ (BOOL)wirelessJoinWithName:(NSString *)playerName hostAddress:(NSString *)address {
    LAN* lan = ActiveLAN();
    if (!lan) return NO;
    return lan->StartClient(playerName.UTF8String, address.UTF8String);
}

+ (void)wirelessEndSession {
    if (LAN* lan = ActiveLAN()) lan->EndSession();
}

+ (NSInteger)wirelessNumPlayers {
    LAN* lan = ActiveLAN();
    return lan ? lan->GetNumPlayers() : 0;
}

#pragma mark - Misc

+ (NSString *)coreVersion {
    return [NSString stringWithFormat:@"melonDS %s", MELONDS_VERSION];
}

@end
