//
//  MelonPlatform.mm
//  Bifold
//
//  melonDS Platform:: implementation for iOS. File IO is stdio, threading is
//  std::thread / std::condition_variable, and everything network-, camera-
//  or DSi-shaped is a stub (Bifold v1 emulates a plain DS, offline).
//
//  Callbacks that matter route through the BifoldCoreState pointer that the
//  bridge passes to melonDS as `userdata` — no Objective-C in here.
//

#include "Platform.h"
#include "BifoldCoreState.h"
#include "net/MPInterface.h"

#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <chrono>
#include <condition_variable>
#include <mutex>
#include <sys/stat.h>
#include <thread>
#include <unistd.h>

#include "frontend/mic_blow.h"

namespace BifoldPlatform {
std::string SystemDirectory;
}

namespace melonDS::Platform
{

// ---------------------------------------------------------------- stop

void SignalStop(StopReason reason, void* userdata)
{
    if (auto* state = static_cast<BifoldCoreState*>(userdata))
        state->stopReason.store(static_cast<int>(reason));
}

// ---------------------------------------------------------------- files

static bool PathExists(const std::string& path)
{
    struct stat st {};
    return stat(path.c_str(), &st) == 0;
}

std::string GetLocalFilePath(const std::string& filename)
{
    if (!filename.empty() && filename.front() == '/')
        return filename;
    return BifoldPlatform::SystemDirectory + "/" + filename;
}

FileHandle* OpenFile(const std::string& path, FileMode mode)
{
    if ((mode & (FileMode::ReadWrite | FileMode::Append)) == FileMode::None)
        return nullptr;

    const bool exists = PathExists(path);
    if (!exists && (mode & FileMode::NoCreate))
        return nullptr;

    // fopen access letter, following melonDS's reference frontend:
    // append wins; no write = read; write over an existing file that must be
    // preserved = read-update; otherwise create/truncate.
    char access;
    if (mode & FileMode::Append)
        access = 'a';
    else if (!(mode & FileMode::Write))
        access = 'r';
    else if (exists && (mode & FileMode::Preserve))
        access = 'r';
    else
        access = 'w';

    std::string modeString(1, access);
    if ((mode & FileMode::ReadWrite) == FileMode::ReadWrite)
        modeString += '+';
    if (!(mode & FileMode::Text))
        modeString += 'b';

    FILE* file = fopen(path.c_str(), modeString.c_str());
    return reinterpret_cast<FileHandle*>(file);
}

FileHandle* OpenLocalFile(const std::string& path, FileMode mode)
{
    return OpenFile(GetLocalFilePath(path), mode);
}

bool FileExists(const std::string& name)
{
    return PathExists(name);
}

bool LocalFileExists(const std::string& name)
{
    return PathExists(GetLocalFilePath(name));
}

bool CheckFileWritable(const std::string& filepath)
{
    if (FILE* f = fopen(filepath.c_str(), "ab"))
    {
        fclose(f);
        return true;
    }
    return false;
}

bool CheckLocalFileWritable(const std::string& filepath)
{
    return CheckFileWritable(GetLocalFilePath(filepath));
}

bool CloseFile(FileHandle* file)
{
    return fclose(reinterpret_cast<FILE*>(file)) == 0;
}

bool IsEndOfFile(FileHandle* file)
{
    return feof(reinterpret_cast<FILE*>(file)) != 0;
}

bool FileReadLine(char* str, int count, FileHandle* file)
{
    return fgets(str, count, reinterpret_cast<FILE*>(file)) != nullptr;
}

u64 FilePosition(FileHandle* file)
{
    long pos = ftell(reinterpret_cast<FILE*>(file));
    return pos < 0 ? 0 : (u64)pos;
}

bool FileSeek(FileHandle* file, s64 offset, FileSeekOrigin origin)
{
    int whence = SEEK_SET;
    switch (origin)
    {
    case FileSeekOrigin::Start: whence = SEEK_SET; break;
    case FileSeekOrigin::Current: whence = SEEK_CUR; break;
    case FileSeekOrigin::End: whence = SEEK_END; break;
    }
    return fseeko(reinterpret_cast<FILE*>(file), (off_t)offset, whence) == 0;
}

void FileRewind(FileHandle* file)
{
    rewind(reinterpret_cast<FILE*>(file));
}

u64 FileRead(void* data, u64 size, u64 count, FileHandle* file)
{
    return fread(data, (size_t)size, (size_t)count, reinterpret_cast<FILE*>(file));
}

bool FileFlush(FileHandle* file)
{
    return fflush(reinterpret_cast<FILE*>(file)) == 0;
}

u64 FileWrite(const void* data, u64 size, u64 count, FileHandle* file)
{
    return fwrite(data, (size_t)size, (size_t)count, reinterpret_cast<FILE*>(file));
}

u64 FileWriteFormatted(FileHandle* file, const char* fmt, ...)
{
    va_list args;
    va_start(args, fmt);
    int written = vfprintf(reinterpret_cast<FILE*>(file), fmt, args);
    va_end(args);
    return written < 0 ? 0 : (u64)written;
}

u64 FileLength(FileHandle* file)
{
    FILE* f = reinterpret_cast<FILE*>(file);
    long pos = ftell(f);
    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    fseek(f, pos, SEEK_SET);
    return len < 0 ? 0 : (u64)len;
}

void Log(LogLevel level, const char* fmt, ...)
{
#ifdef DEBUG
    const bool wanted = true;
#else
    const bool wanted = level >= LogLevel::Info;
#endif
    if (!wanted) return;
    va_list args;
    va_start(args, fmt);
    vfprintf(stderr, fmt, args);
    va_end(args);
}

// ---------------------------------------------------------------- threads

struct Thread
{
    std::thread t;
};

Thread* Thread_Create(std::function<void()> func)
{
    auto* thread = new Thread { std::thread(std::move(func)) };
    return thread;
}

void Thread_Wait(Thread* thread)
{
    if (thread->t.joinable())
        thread->t.join();
}

void Thread_Free(Thread* thread)
{
    if (thread->t.joinable())
        thread->t.join();
    delete thread;
}

struct Semaphore
{
    std::mutex m;
    std::condition_variable cv;
    int count = 0;
};

Semaphore* Semaphore_Create()
{
    return new Semaphore();
}

void Semaphore_Free(Semaphore* sema)
{
    delete sema;
}

void Semaphore_Reset(Semaphore* sema)
{
    std::lock_guard<std::mutex> lock(sema->m);
    sema->count = 0;
}

void Semaphore_Wait(Semaphore* sema)
{
    std::unique_lock<std::mutex> lock(sema->m);
    sema->cv.wait(lock, [&] { return sema->count > 0; });
    sema->count--;
}

bool Semaphore_TryWait(Semaphore* sema, int timeout_ms)
{
    std::unique_lock<std::mutex> lock(sema->m);
    if (timeout_ms == 0)
    {
        if (sema->count <= 0) return false;
    }
    else if (!sema->cv.wait_for(lock, std::chrono::milliseconds(timeout_ms), [&] { return sema->count > 0; }))
    {
        return false;
    }
    sema->count--;
    return true;
}

void Semaphore_Post(Semaphore* sema, int count)
{
    {
        std::lock_guard<std::mutex> lock(sema->m);
        sema->count += count;
    }
    sema->cv.notify_all();
}

struct Mutex
{
    std::mutex m;
};

Mutex* Mutex_Create()
{
    return new Mutex();
}

void Mutex_Free(Mutex* mutex)
{
    delete mutex;
}

void Mutex_Lock(Mutex* mutex)
{
    mutex->m.lock();
}

void Mutex_Unlock(Mutex* mutex)
{
    mutex->m.unlock();
}

bool Mutex_TryLock(Mutex* mutex)
{
    return mutex->m.try_lock();
}

void Sleep(u64 usecs)
{
    usleep((useconds_t)usecs);
}

static const std::chrono::steady_clock::time_point gEpoch = std::chrono::steady_clock::now();

u64 GetMSCount()
{
    return (u64)std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - gEpoch).count();
}

u64 GetUSCount()
{
    return (u64)std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - gEpoch).count();
}

// ---------------------------------------------------------------- saves

void WriteNDSSave(const u8* savedata, u32 savelen, u32 writeoffset, u32 writelen, void* userdata)
{
    auto* state = static_cast<BifoldCoreState*>(userdata);
    if (!state || state->savePath.empty() || !savedata || savelen == 0)
        return;
    if (FILE* f = fopen(state->savePath.c_str(), "wb"))
    {
        fwrite(savedata, 1, savelen, f);
        fclose(f);
        state->saveWrites.fetch_add(1);
    }
}

void WriteGBASave(const u8*, u32, u32, u32, void*) {}
void WriteFirmware(const Firmware&, u32, u32, void*) {}
void WriteDateTime(int, int, int, int, int, int, void*) {}

// ---------------------------------------------------------------- multiplayer
// Forwarded to melonDS's MPInterface: a Dummy until the user hosts or joins
// a local-wireless session, then the LAN implementation over ENet.

void MP_Begin(void*) { MPInterface::Get().Begin(0); }
void MP_End(void*) { MPInterface::Get().End(0); }
int MP_SendPacket(u8* data, int len, u64 timestamp, void*) { return MPInterface::Get().SendPacket(0, data, len, timestamp); }
int MP_RecvPacket(u8* data, u64* timestamp, void*) { return MPInterface::Get().RecvPacket(0, data, timestamp); }
int MP_SendCmd(u8* data, int len, u64 timestamp, void*) { return MPInterface::Get().SendCmd(0, data, len, timestamp); }
int MP_SendReply(u8* data, int len, u64 timestamp, u16 aid, void*) { return MPInterface::Get().SendReply(0, data, len, timestamp, aid); }
int MP_SendAck(u8* data, int len, u64 timestamp, void*) { return MPInterface::Get().SendAck(0, data, len, timestamp); }
int MP_RecvHostPacket(u8* data, u64* timestamp, void*) { return MPInterface::Get().RecvHostPacket(0, data, timestamp); }
u16 MP_RecvReplies(u8* data, u64 timestamp, u16 aidmask, void*) { return MPInterface::Get().RecvReplies(0, data, timestamp, aidmask); }

int Net_SendPacket(u8*, int, void*) { return 0; }
int Net_RecvPacket(u8*, void*) { return 0; }

// ---------------------------------------------------------------- camera (DSi)

void Camera_Start(int num, void* userdata)
{
    if (auto* state = static_cast<BifoldCoreState*>(userdata))
        state->camActiveMask.fetch_or(1 << num);
}

void Camera_Stop(int num, void* userdata)
{
    if (auto* state = static_cast<BifoldCoreState*>(userdata))
        state->camActiveMask.fetch_and(~(1 << num));
}

void Camera_CaptureFrame(int num, u32* frame, int width, int height, bool yuv, void* userdata)
{
    auto* state = static_cast<BifoldCoreState*>(userdata);
    const int camW = BifoldCoreState::CamWidth;
    const int camH = BifoldCoreState::CamHeight;
    if (!state || !yuv || width <= 0 || height <= 0)
    {
        // The DSi camera module always transfers YUV; anything else gets black.
        if (frame && width > 0 && height > 0)
            memset(frame, 0, (size_t)(width * height) * (yuv ? 2 : 4));
        return;
    }
    std::lock_guard<std::mutex> lock(state->camLock);
    if (!state->camHasFrame.load())
    {
        memset(frame, 0, (size_t)(width * height) * 2);
        return;
    }
    if (width == camW && height == camH)
    {
        memcpy(frame, state->camFrame, (size_t)(camW * camH / 2) * sizeof(u32));
        return;
    }
    // Nearest-neighbour scale in YUY2 pairs (after the reference frontend).
    const int sw = camW / 2, dw = width / 2;
    for (int dy = 0; dy < height; dy++)
    {
        int sy = (dy * camH) / height;
        for (int dx = 0; dx < dw; dx++)
        {
            int sx = (dx * sw) / dw;
            frame[dy * dw + dx] = state->camFrame[sy * sw + sx];
        }
    }
}

// ---------------------------------------------------------------- microphone

void Mic_Start(void*) {}
void Mic_Stop(void*) {}

int Mic_ReadInput(s16* data, int maxlength, void* userdata)
{
    auto* state = static_cast<BifoldCoreState*>(userdata);
    if (maxlength <= 0)
        return 0;
    if (state && state->micActive.load())
    {
        // The MIC button always wins: canned blow noise (mic_blow.h).
        const int blowLength = (int)(sizeof(mic_blow) / sizeof(s16));
        int pos = state->micPos;
        for (int i = 0; i < maxlength; i++)
        {
            data[i] = mic_blow[pos];
            pos = (pos + 1) % blowLength;
        }
        state->micPos = pos;
        return maxlength;
    }
    if (state && state->micMode.load() == 2)
    {
        // Real microphone: drain the tap's ring, zero-fill any shortfall.
        uint32_t write = state->micRingWrite.load(std::memory_order_acquire);
        uint32_t read = state->micRingRead;
        int i = 0;
        while (i < maxlength && read != write)
        {
            data[i++] = state->micRing[read % BifoldCoreState::MicRingSize];
            read++;
        }
        state->micRingRead = read;
        if (i < maxlength)
            memset(data + i, 0, (size_t)(maxlength - i) * sizeof(s16));
        return maxlength;
    }
    // Silence: the DS hears a perfectly quiet room.
    memset(data, 0, (size_t)maxlength * sizeof(s16));
    return maxlength;
}

// ---------------------------------------------------------------- DSi AAC (stub)

AACDecoder* AAC_Init() { return nullptr; }
void AAC_DeInit(AACDecoder*) {}
bool AAC_Configure(AACDecoder*, int, int) { return false; }
bool AAC_DecodeFrame(AACDecoder*, const void*, int, void*, int) { return false; }

// ---------------------------------------------------------------- slot-2 addons (stubs)

bool Addon_KeyDown(KeyType, void*) { return false; }

void Addon_RumbleStart(u32 len, void* userdata)
{
    if (auto* state = static_cast<BifoldCoreState*>(userdata))
        state->rumbleUntilUS.store(GetUSCount() + (uint64_t)len * 1000);
}

void Addon_RumbleStop(void* userdata)
{
    if (auto* state = static_cast<BifoldCoreState*>(userdata))
        state->rumbleUntilUS.store(0);
}
float Addon_MotionQuery(MotionQueryType, void*) { return 0.0f; }

// ---------------------------------------------------------------- dynamic libraries (stub)

DynamicLibrary* DynamicLibrary_Load(const char*) { return nullptr; }
void DynamicLibrary_Unload(DynamicLibrary*) {}
void* DynamicLibrary_LoadFunction(DynamicLibrary*, const char*) { return nullptr; }

}
