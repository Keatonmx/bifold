//
//  BifoldCoreState.h
//  Bifold
//
//  Plain C++ state shared between the ObjC++ bridge (DSEmulatorCore.mm) and
//  the Platform implementation (MelonPlatform.mm). A pointer to this struct
//  is the `userdata` handed to melonDS, so Platform callbacks never touch
//  Objective-C objects.
//
//  NOT imported by Swift (it is not in the bridging header).
//

#pragma once

#include <atomic>
#include <mutex>
#include <string>

struct BifoldCoreState {
    /// Battery save destination for the loaded ROM ("" = no ROM).
    /// Written by the bridge under the session lock; read by WriteNDSSave,
    /// which only ever runs inside NDS::RunFrame (same lock).
    std::string savePath;

    /// Bumped after every battery-save write (bridge polls it after runFrame).
    std::atomic<int> saveWrites { 0 };

    /// Set by Platform::SignalStop; -1 while running.
    std::atomic<int> stopReason { -1 };

    /// Microphone. `micActive` (the MIC button) always feeds the blow-noise
    /// loop; otherwise `micMode` 2 feeds the real microphone's ring buffer and
    /// anything else is silence. `micPos` is emulation-thread only.
    std::atomic<int> micMode { 1 };
    std::atomic<bool> micActive { false };
    int micPos = 0;

    /// Real-microphone ring: single producer (the audio input tap), single
    /// consumer (Mic_ReadInput on the emulation thread). Indices are frame
    /// counts that only ever grow; readers mask by the capacity.
    static constexpr int MicRingSize = 16384;
    int16_t micRing[MicRingSize] = {};
    std::atomic<uint32_t> micRingWrite { 0 };
    uint32_t micRingRead = 0;   // emulation thread only

    /// Slot-2 Rumble Pak: microsecond deadline (Platform::GetUSCount clock)
    /// until which the motor spins; 0 = off.
    std::atomic<uint64_t> rumbleUntilUS { 0 };

    /// DSi cameras. The bridge stores the latest phone frame as 640×480 YUY2
    /// (w*h/2 words, y1|u<<8|y2<<16|v<<24); Camera_CaptureFrame copies it out
    /// under the lock. Bit 0 of `camActiveMask` = outer camera (0), bit 1 =
    /// inner (1); the session polls it to run the phone camera.
    static constexpr int CamWidth = 640;
    static constexpr int CamHeight = 480;
    std::atomic<int> camActiveMask { 0 };
    std::mutex camLock;
    uint32_t camFrame[CamWidth * CamHeight / 2] = {};
    std::atomic<bool> camHasFrame { false };
};

namespace BifoldPlatform {
    /// Folder for melonDS's own local files (Platform::OpenLocalFile).
    /// Set once by the bridge before the first console is created.
    extern std::string SystemDirectory;
}
