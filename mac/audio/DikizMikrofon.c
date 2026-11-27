// Dikiz Mikrofon — sanal mikrofon (Core Audio AudioServerPlugIn, HAL eklentisi)
//
// Tek bir "geri döngü" (loopback) aygıtı: Dikiz uygulaması telefondan gelen sesi bu aygıtın
// ÇIKIŞINA çalar, toplantı uygulamaları (Zoom, Meet, Teams, FaceTime) aynı sesi aygıtın
// GİRİŞİNDEN mikrofon olarak okur. Aradaki köprü, aygıtın içindeki halka tampondur.
//
// Biçim sabit: 48 kHz, tek kanal (mono), 32 bit kayan nokta.
// Yazım Apple'ın AudioServerPlugIn.h belgesine göre sıfırdan yapıldı.
//
// Nesneler:  1 = eklenti, 2 = aygıt, 3 = giriş akışı, 4 = çıkış akışı

#include <CoreAudio/AudioServerPlugIn.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>

// ---- sabitler ----
enum {
    kObjPlugIn = kAudioObjectPlugInObject,   // 1
    kObjDevice = 2,
    kObjInputStream = 3,
    kObjOutputStream = 4,
};

#define kSampleRate        48000.0
#define kChannels          1
#define kRingFrames        16384          // ~341 ms; aynı zamanda sıfır zaman damgası periyodu
#define kDeviceName        "Dikiz Mikrofon"
#define kManufacturer      "Dikiz"
#define kDeviceUID         "DikizMikrofon_UID"
#define kDeviceModelUID    "DikizMikrofon_ModelUID"

// ---- durum ----
static AudioServerPlugInHostRef gHost = NULL;
static pthread_mutex_t gStateLock = PTHREAD_MUTEX_INITIALIZER;
static UInt32 gRefCount = 0;

static UInt32 gIOCount = 0;            // StartIO sayacı (birden fazla istemci)
static UInt64 gAnchorHostTime = 0;     // IO başladığı andaki mach_absolute_time
static Float64 gHostTicksPerFrame = 0; // bir örnek kaç host tıkı
static UInt64 gTimestampCount = 0;     // GetZeroTimeStamp için geçen periyot sayısı

static Float32 gRing[kRingFrames * kChannels];
static Float64 gLastWriteEnd = -1;     // en son yazılan bölümün bittiği örnek zamanı
static Float64 gRunStart = -1;         // kesintisiz yazımın başladığı örnek zamanı

// ---- yardımcılar ----
static AudioStreamBasicDescription StreamFormat(void) {
    AudioStreamBasicDescription f;
    memset(&f, 0, sizeof f);
    f.mSampleRate = kSampleRate;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    f.mBytesPerPacket = sizeof(Float32) * kChannels;
    f.mFramesPerPacket = 1;
    f.mBytesPerFrame = sizeof(Float32) * kChannels;
    f.mChannelsPerFrame = kChannels;
    f.mBitsPerChannel = 32;
    return f;
}

static OSStatus WriteData(UInt32 inSize, UInt32 *outSize, void *outData, const void *src, UInt32 srcSize) {
    if (inSize < srcSize) return kAudioHardwareBadPropertySizeError;
    memcpy(outData, src, srcSize);
    *outSize = srcSize;
    return kAudioHardwareNoError;
}

#define RETURN_VALUE(T, v) do { T _v = (v); return WriteData(inDataSize, outDataSize, outData, &_v, sizeof(T)); } while (0)
#define RETURN_CFSTR(s) do { \
    if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError; \
    *(CFStringRef *)outData = CFStringCreateWithCString(NULL, (s), kCFStringEncodingUTF8); \
    *outDataSize = sizeof(CFStringRef); return kAudioHardwareNoError; } while (0)

static Boolean StreamIsInput(AudioObjectID obj) { return obj == kObjInputStream; }

// ---- arayüz bildirimleri ----
static HRESULT  Dikiz_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface);
static ULONG    Dikiz_AddRef(void *inDriver);
static ULONG    Dikiz_Release(void *inDriver);
static OSStatus Dikiz_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus Dikiz_CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc, const AudioServerPlugInClientInfo *ci, AudioObjectID *outID);
static OSStatus Dikiz_DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID id);
static OSStatus Dikiz_AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID id, const AudioServerPlugInClientInfo *ci);
static OSStatus Dikiz_RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID id, const AudioServerPlugInClientInfo *ci);
static OSStatus Dikiz_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID id, UInt64 action, void *info);
static OSStatus Dikiz_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID id, UInt64 action, void *info);
static Boolean  Dikiz_HasProperty(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *addr);
static OSStatus Dikiz_IsPropertySettable(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *addr, Boolean *outSettable);
static OSStatus Dikiz_GetPropertyDataSize(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *addr, UInt32 qSize, const void *q, UInt32 *outSize);
static OSStatus Dikiz_GetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *addr, UInt32 qSize, const void *q, UInt32 inDataSize, UInt32 *outDataSize, void *outData);
static OSStatus Dikiz_SetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *addr, UInt32 qSize, const void *q, UInt32 inDataSize, const void *inData);
static OSStatus Dikiz_StartIO(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client);
static OSStatus Dikiz_StopIO(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client);
static OSStatus Dikiz_GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed);
static OSStatus Dikiz_WillDoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client, UInt32 op, Boolean *outWillDo, Boolean *outWillDoInPlace);
static OSStatus Dikiz_BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo *cycle);
static OSStatus Dikiz_DoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, AudioObjectID stream, UInt32 client, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo *cycle, void *mainBuf, void *secBuf);
static OSStatus Dikiz_EndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo *cycle);

static AudioServerPlugInDriverInterface gInterface = {
    NULL,
    Dikiz_QueryInterface, Dikiz_AddRef, Dikiz_Release,
    Dikiz_Initialize, Dikiz_CreateDevice, Dikiz_DestroyDevice,
    Dikiz_AddDeviceClient, Dikiz_RemoveDeviceClient,
    Dikiz_PerformDeviceConfigurationChange, Dikiz_AbortDeviceConfigurationChange,
    Dikiz_HasProperty, Dikiz_IsPropertySettable, Dikiz_GetPropertyDataSize, Dikiz_GetPropertyData, Dikiz_SetPropertyData,
    Dikiz_StartIO, Dikiz_StopIO, Dikiz_GetZeroTimeStamp,
    Dikiz_WillDoIOOperation, Dikiz_BeginIOOperation, Dikiz_DoIOOperation, Dikiz_EndIOOperation,
};
static AudioServerPlugInDriverInterface *gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriverRef = &gInterfacePtr;

// ---- fabrika (Info.plist → CFPlugInFactories) ----
void *DikizMikrofon_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID);
void *DikizMikrofon_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID) {
    (void)allocator;
    if (CFEqual(requestedTypeUUID, kAudioServerPlugInTypeUUID)) return gDriverRef;
    return NULL;
}

// ---- IUnknown ----
static HRESULT Dikiz_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface) {
    if (inDriver != gDriverRef || outInterface == NULL) return kAudioHardwareIllegalOperationError;
    CFUUIDRef req = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    HRESULT r = E_NOINTERFACE;
    if (CFEqual(req, IUnknownUUID) || CFEqual(req, kAudioServerPlugInDriverInterfaceUUID)) {
        pthread_mutex_lock(&gStateLock); gRefCount++; pthread_mutex_unlock(&gStateLock);
        *outInterface = gDriverRef;
        r = S_OK;
    }
    CFRelease(req);
    return r;
}

static ULONG Dikiz_AddRef(void *inDriver) {
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateLock); ULONG r = ++gRefCount; pthread_mutex_unlock(&gStateLock);
    return r;
}

static ULONG Dikiz_Release(void *inDriver) {
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateLock); ULONG r = gRefCount > 0 ? --gRefCount : 0; pthread_mutex_unlock(&gStateLock);
    return r;
}

// ---- yaşam döngüsü ----
static OSStatus Dikiz_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    gHost = inHost;
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    Float64 hostClockFrequency = (Float64)tb.denom / (Float64)tb.numer * 1000000000.0;
    gHostTicksPerFrame = hostClockFrequency / kSampleRate;
    return kAudioHardwareNoError;
}

static OSStatus Dikiz_CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc, const AudioServerPlugInClientInfo *ci, AudioObjectID *outID) {
    (void)d; (void)desc; (void)ci; (void)outID;
    return kAudioHardwareUnsupportedOperationError;
}
static OSStatus Dikiz_DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID id) {
    (void)d; (void)id; return kAudioHardwareUnsupportedOperationError;
}
static OSStatus Dikiz_AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID id, const AudioServerPlugInClientInfo *ci) {
    (void)d; (void)ci; return id == kObjDevice ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}
static OSStatus Dikiz_RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID id, const AudioServerPlugInClientInfo *ci) {
    (void)d; (void)ci; return id == kObjDevice ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}
static OSStatus Dikiz_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID id, UInt64 action, void *info) {
    (void)d; (void)id; (void)action; (void)info; return kAudioHardwareNoError;
}
static OSStatus Dikiz_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID id, UInt64 action, void *info) {
    (void)d; (void)id; (void)action; (void)info; return kAudioHardwareNoError;
}

// ---- özellikler ----
static Boolean Dikiz_HasProperty(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a) {
    (void)d; (void)pid;
    switch (obj) {
    case kObjPlugIn:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyManufacturer: case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyBoxList: case kAudioPlugInPropertyTranslateUIDToBox:
        case kAudioPlugInPropertyDeviceList: case kAudioPlugInPropertyTranslateUIDToDevice:
        case kAudioPlugInPropertyResourceBundle:
            return true;
        }
        return false;
    case kObjDevice:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName: case kAudioObjectPropertyManufacturer: case kAudioObjectPropertyOwnedObjects:
        case kAudioObjectPropertyControlList:
        case kAudioDevicePropertyDeviceUID: case kAudioDevicePropertyModelUID: case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyRelatedDevices: case kAudioDevicePropertyClockDomain: case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning: case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: case kAudioDevicePropertyLatency:
        case kAudioDevicePropertyStreams: case kAudioDevicePropertySafetyOffset: case kAudioDevicePropertyNominalSampleRate:
        case kAudioDevicePropertyAvailableNominalSampleRates: case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyZeroTimeStampPeriod: case kAudioDevicePropertyPreferredChannelsForStereo:
        case kAudioDevicePropertyPreferredChannelLayout:
            return true;
        }
        return false;
    case kObjInputStream:
    case kObjOutputStream:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioStreamPropertyIsActive: case kAudioStreamPropertyDirection: case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel: case kAudioStreamPropertyLatency:
        case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat:
        case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats:
            return true;
        }
        return false;
    }
    return false;
}

static OSStatus Dikiz_IsPropertySettable(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a, Boolean *outSettable) {
    if (!Dikiz_HasProperty(d, obj, pid, a)) return kAudioHardwareUnknownPropertyError;
    // Biçim sabit: akış biçimi "ayarlanabilir" görünür ama yalnızca aynı biçim kabul edilir.
    *outSettable = (obj == kObjInputStream || obj == kObjOutputStream) &&
                   (a->mSelector == kAudioStreamPropertyVirtualFormat || a->mSelector == kAudioStreamPropertyPhysicalFormat);
    return kAudioHardwareNoError;
}

// Aygıtın sahip olduğu akışlar (kapsama göre)
static UInt32 DeviceStreams(AudioObjectPropertyScope scope, AudioObjectID out[2]) {
    UInt32 n = 0;
    if (scope == kAudioObjectPropertyScopeGlobal || scope == kAudioObjectPropertyScopeInput) out[n++] = kObjInputStream;
    if (scope == kAudioObjectPropertyScopeGlobal || scope == kAudioObjectPropertyScopeOutput) out[n++] = kObjOutputStream;
    return n;
}

static OSStatus Dikiz_GetPropertyDataSize(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a, UInt32 qSize, const void *q, UInt32 *outSize) {
    // En kolay yol: veriyi büyük bir tampona üretip boyutunu ölç.
    UInt8 scratch[512];
    UInt32 sz = 0;
    OSStatus r = Dikiz_GetPropertyData(d, obj, pid, a, qSize, q, sizeof scratch, &sz, scratch);
    if (r == kAudioHardwareNoError) {
        // CFString döndürenler sahiplik verir; ölçüm için ürettiğimizi bırak.
        if (sz == sizeof(CFStringRef)) {
            UInt32 sel = a->mSelector;
            if (sel == kAudioObjectPropertyName || sel == kAudioObjectPropertyManufacturer ||
                sel == kAudioDevicePropertyDeviceUID || sel == kAudioDevicePropertyModelUID ||
                sel == kAudioPlugInPropertyResourceBundle) {
                CFStringRef s = *(CFStringRef *)scratch;
                if (s) CFRelease(s);
            }
        }
        *outSize = sz;
    }
    return r;
}

static OSStatus Dikiz_GetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a, UInt32 qSize, const void *q, UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    (void)d; (void)pid;
    switch (obj) {
    // ---------- eklenti ----------
    case kObjPlugIn:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: RETURN_VALUE(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: RETURN_VALUE(AudioClassID, kAudioPlugInClassID);
        case kAudioObjectPropertyOwner: RETURN_VALUE(AudioObjectID, kAudioObjectUnknown);
        case kAudioObjectPropertyManufacturer: RETURN_CFSTR(kManufacturer);
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList: {
            if (inDataSize < sizeof(AudioObjectID)) { *outDataSize = 0; return kAudioHardwareNoError; }
            *(AudioObjectID *)outData = kObjDevice;
            *outDataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        }
        case kAudioPlugInPropertyBoxList:
            *outDataSize = 0;
            return kAudioHardwareNoError;
        case kAudioPlugInPropertyTranslateUIDToBox:
            RETURN_VALUE(AudioObjectID, kAudioObjectUnknown);
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            AudioObjectID found = kAudioObjectUnknown;
            if (qSize == sizeof(CFStringRef) && q) {
                CFStringRef uid = *(const CFStringRef *)q;
                CFStringRef mine = CFSTR(kDeviceUID);
                if (uid && CFStringCompare(uid, mine, 0) == kCFCompareEqualTo) found = kObjDevice;
            }
            RETURN_VALUE(AudioObjectID, found);
        }
        case kAudioPlugInPropertyResourceBundle: RETURN_CFSTR("");
        }
        return kAudioHardwareUnknownPropertyError;

    // ---------- aygıt ----------
    case kObjDevice:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: RETURN_VALUE(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: RETURN_VALUE(AudioClassID, kAudioDeviceClassID);
        case kAudioObjectPropertyOwner: RETURN_VALUE(AudioObjectID, kObjPlugIn);
        case kAudioObjectPropertyName: RETURN_CFSTR(kDeviceName);
        case kAudioObjectPropertyManufacturer: RETURN_CFSTR(kManufacturer);
        case kAudioDevicePropertyDeviceUID: RETURN_CFSTR(kDeviceUID);
        case kAudioDevicePropertyModelUID: RETURN_CFSTR(kDeviceModelUID);
        case kAudioDevicePropertyTransportType: RETURN_VALUE(UInt32, kAudioDeviceTransportTypeVirtual);
        case kAudioDevicePropertyRelatedDevices: RETURN_VALUE(AudioObjectID, kObjDevice);
        case kAudioDevicePropertyClockDomain: RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertyDeviceIsAlive: RETURN_VALUE(UInt32, 1);
        case kAudioDevicePropertyDeviceIsRunning: {
            pthread_mutex_lock(&gStateLock); UInt32 running = gIOCount > 0; pthread_mutex_unlock(&gStateLock);
            RETURN_VALUE(UInt32, running);
        }
        // Mikrofon olarak varsayılan seçilebilir; hoparlör olarak asla varsayılan olmaz.
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            RETURN_VALUE(UInt32, a->mScope == kAudioObjectPropertyScopeInput ? 1 : 0);
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertyLatency: RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertySafetyOffset: RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertyNominalSampleRate: RETURN_VALUE(Float64, kSampleRate);
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            AudioValueRange r = { kSampleRate, kSampleRate };
            return WriteData(inDataSize, outDataSize, outData, &r, sizeof r);
        }
        case kAudioDevicePropertyIsHidden: RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertyZeroTimeStampPeriod: RETURN_VALUE(UInt32, kRingFrames);
        case kAudioDevicePropertyPreferredChannelsForStereo: {
            UInt32 ch[2] = { 1, 1 };
            return WriteData(inDataSize, outDataSize, outData, ch, sizeof ch);
        }
        case kAudioDevicePropertyPreferredChannelLayout: {
            AudioChannelLayout l;
            memset(&l, 0, sizeof l);
            l.mChannelLayoutTag = kAudioChannelLayoutTag_Mono;
            return WriteData(inDataSize, outDataSize, outData, &l, offsetof(AudioChannelLayout, mChannelDescriptions));
        }
        case kAudioObjectPropertyControlList:
            *outDataSize = 0;
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyStreams: {
            AudioObjectID ids[2];
            UInt32 n = DeviceStreams(a->mScope, ids);
            UInt32 fit = inDataSize / sizeof(AudioObjectID);
            if (n > fit) n = fit;
            memcpy(outData, ids, n * sizeof(AudioObjectID));
            *outDataSize = n * sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        }
        }
        return kAudioHardwareUnknownPropertyError;

    // ---------- akışlar ----------
    case kObjInputStream:
    case kObjOutputStream:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: RETURN_VALUE(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: RETURN_VALUE(AudioClassID, kAudioStreamClassID);
        case kAudioObjectPropertyOwner: RETURN_VALUE(AudioObjectID, kObjDevice);
        case kAudioObjectPropertyName: RETURN_CFSTR(StreamIsInput(obj) ? "Dikiz Mikrofon Girişi" : "Dikiz Mikrofon Beslemesi");
        case kAudioStreamPropertyIsActive: RETURN_VALUE(UInt32, 1);
        case kAudioStreamPropertyDirection: RETURN_VALUE(UInt32, StreamIsInput(obj) ? 1 : 0);
        case kAudioStreamPropertyTerminalType:
            RETURN_VALUE(UInt32, StreamIsInput(obj) ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeLine);
        case kAudioStreamPropertyStartingChannel: RETURN_VALUE(UInt32, 1);
        case kAudioStreamPropertyLatency: RETURN_VALUE(UInt32, 0);
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: {
            AudioStreamBasicDescription f = StreamFormat();
            return WriteData(inDataSize, outDataSize, outData, &f, sizeof f);
        }
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            AudioStreamRangedDescription r;
            r.mFormat = StreamFormat();
            r.mSampleRateRange.mMinimum = kSampleRate;
            r.mSampleRateRange.mMaximum = kSampleRate;
            return WriteData(inDataSize, outDataSize, outData, &r, sizeof r);
        }
        }
        return kAudioHardwareUnknownPropertyError;
    }
    return kAudioHardwareBadObjectError;
}

static OSStatus Dikiz_SetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a, UInt32 qSize, const void *q, UInt32 inDataSize, const void *inData) {
    (void)d; (void)pid; (void)qSize; (void)q;
    if ((obj == kObjInputStream || obj == kObjOutputStream) &&
        (a->mSelector == kAudioStreamPropertyVirtualFormat || a->mSelector == kAudioStreamPropertyPhysicalFormat)) {
        if (inDataSize != sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
        const AudioStreamBasicDescription *f = inData;
        AudioStreamBasicDescription mine = StreamFormat();
        if (f->mSampleRate != mine.mSampleRate || f->mFormatID != mine.mFormatID ||
            f->mChannelsPerFrame != mine.mChannelsPerFrame || f->mBitsPerChannel != mine.mBitsPerChannel)
            return kAudioDeviceUnsupportedFormatError;
        return kAudioHardwareNoError;
    }
    return kAudioHardwareUnknownPropertyError;
}

// ---- IO ----
static OSStatus Dikiz_StartIO(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client) {
    (void)d; (void)client;
    if (id != kObjDevice) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateLock);
    if (gIOCount == 0) {
        gAnchorHostTime = mach_absolute_time();
        gTimestampCount = 0;
        memset(gRing, 0, sizeof gRing);
        gLastWriteEnd = -1;
        gRunStart = -1;
    }
    gIOCount++;
    pthread_mutex_unlock(&gStateLock);
    return kAudioHardwareNoError;
}

static OSStatus Dikiz_StopIO(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client) {
    (void)d; (void)client;
    if (id != kObjDevice) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateLock);
    if (gIOCount > 0) gIOCount--;
    pthread_mutex_unlock(&gStateLock);
    return kAudioHardwareNoError;
}

// Saat: IO başladığı andan itibaren her kRingFrames örnekte bir "sıfır" zaman damgası.
static OSStatus Dikiz_GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed) {
    (void)d; (void)client;
    if (id != kObjDevice) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateLock);
    UInt64 now = mach_absolute_time();
    Float64 ticksPerPeriod = gHostTicksPerFrame * kRingFrames;
    UInt64 nextZero = gAnchorHostTime + (UInt64)((Float64)(gTimestampCount + 1) * ticksPerPeriod);
    if (nextZero <= now) gTimestampCount++;
    *outSampleTime = (Float64)(gTimestampCount * kRingFrames);
    *outHostTime = gAnchorHostTime + (UInt64)((Float64)gTimestampCount * ticksPerPeriod);
    *outSeed = 1;
    pthread_mutex_unlock(&gStateLock);
    return kAudioHardwareNoError;
}

static OSStatus Dikiz_WillDoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client, UInt32 op, Boolean *outWillDo, Boolean *outWillDoInPlace) {
    (void)d; (void)client;
    if (id != kObjDevice) return kAudioHardwareBadObjectError;
    *outWillDo = (op == kAudioServerPlugInIOOperationReadInput || op == kAudioServerPlugInIOOperationWriteMix);
    *outWillDoInPlace = true;
    return kAudioHardwareNoError;
}

static OSStatus Dikiz_BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo *cycle) {
    (void)d; (void)client; (void)op; (void)frames; (void)cycle;
    return id == kObjDevice ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}

static OSStatus Dikiz_EndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo *cycle) {
    (void)d; (void)client; (void)op; (void)frames; (void)cycle;
    return id == kObjDevice ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}

// Halka tampona yaz / halka tampondan oku (örnek zamanına göre konum).
static void RingWrite(Float64 sampleTime, const Float32 *src, UInt32 frames) {
    UInt64 start = (UInt64)sampleTime;
    for (UInt32 i = 0; i < frames; i++) gRing[(start + i) % kRingFrames] = src[i];
}

static void RingRead(Float64 sampleTime, Float32 *dst, UInt32 frames) {
    // Yalnızca son yazılan aralıkta kalan örnekler gerçek sestir; gerisi sessizlik.
    // Böylece besleme durunca eski ses tekrar tekrar çalmaz.
    Float64 validStart = gLastWriteEnd - kRingFrames;
    if (validStart < gRunStart) validStart = gRunStart;
    if (validStart < 0) validStart = 0;
    for (UInt32 i = 0; i < frames; i++) {
        Float64 t = sampleTime + i;
        if (gLastWriteEnd >= 0 && t < gLastWriteEnd && t >= validStart)
            dst[i] = gRing[((UInt64)t) % kRingFrames];
        else
            dst[i] = 0;
    }
}

static OSStatus Dikiz_DoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, AudioObjectID stream, UInt32 client, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo *cycle, void *mainBuf, void *secBuf) {
    (void)d; (void)client; (void)secBuf;
    if (id != kObjDevice) return kAudioHardwareBadObjectError;
    if (mainBuf == NULL || frames == 0) return kAudioHardwareNoError;
    if (op == kAudioServerPlugInIOOperationWriteMix && stream == kObjOutputStream) {
        Float64 t = cycle->mOutputTime.mSampleTime;
        // Arada boşluk varsa (besleme durup yeniden başladıysa) yeni bir "kesintisiz yazım" başlar.
        if (gLastWriteEnd < 0 || t > gLastWriteEnd || t + frames < gLastWriteEnd - kRingFrames) gRunStart = t;
        RingWrite(t, (const Float32 *)mainBuf, frames);
        if (t + frames > gLastWriteEnd) gLastWriteEnd = t + frames;
    } else if (op == kAudioServerPlugInIOOperationReadInput && stream == kObjInputStream) {
        RingRead(cycle->mInputTime.mSampleTime, (Float32 *)mainBuf, frames);
    }
    return kAudioHardwareNoError;
}
