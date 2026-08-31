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

    /// Microphone: what the mic feeds while `micActive`.
    /// 0 = silence, 1 = blow-noise loop. `micPos` is emulation-thread only.
    std::atomic<int> micMode { 1 };
    std::atomic<bool> micActive { false };
    int micPos = 0;
};

namespace BifoldPlatform {
    /// Folder for melonDS's own local files (Platform::OpenLocalFile).
    /// Set once by the bridge before the first console is created.
    extern std::string SystemDirectory;
}
