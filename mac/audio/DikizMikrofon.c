// Dikiz Mikrofon + Dikiz Hoparlör — sanal ses aygıtları (Core Audio AudioServerPlugIn, HAL eklentisi)
//
// İki "geri döngü" (loopback) aygıtı; her birinde çıkışa çalınan ses, aygıtın içindeki halka
// tampondan girişten okunur:
//
//  • Dikiz Mikrofon (mono): Dikiz telefondan gelen sesi ÇIKIŞINA çalar, toplantı uygulamaları
//    (Zoom, Meet, Teams, FaceTime) aynı sesi GİRİŞİNDEN mikrofon olarak okur.
//  • Dikiz Hoparlör (stereo): Mac'in sesi bu aygıta çıkar (varsayılan çıkış seçilebilir),
//    Dikiz aynı sesi GİRİŞİNDEN okuyup telefona gönderir; telefon hoparlör olur.
//
// Biçim sabit: 48 kHz, 32 bit kayan nokta; Mikrofon 1 kanal, Hoparlör 2 kanal.
// Yazım Apple'ın AudioServerPlugIn.h belgesine göre sıfırdan yapıldı.
//
// Nesneler:  1 = eklenti
//            2 = Mikrofon aygıtı, 3 = giriş akışı, 4 = çıkış akışı
//            5 = Hoparlör aygıtı, 6 = giriş akışı, 7 = çıkış akışı

#include <CoreAudio/AudioServerPlugIn.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>

// ---- sabitler ----
enum {
    kObjPlugIn = kAudioObjectPlugInObject,   // 1
    kObjDevice = 2,          // Dikiz Mikrofon
    kObjInputStream = 3,
    kObjOutputStream = 4,
    kObjSpkDevice = 5,       // Dikiz Hoparlör
    kObjSpkInputStream = 6,
    kObjSpkOutputStream = 7,
};

#define kSampleRate        48000.0
#define kMaxChannels       2
#define kRingFrames        16384          // ~341 ms; aynı zamanda sıfır zaman damgası periyodu
#define kManufacturer      "Dikiz"

// ---- aygıt tanımı ve durumu ----
typedef struct {
    AudioObjectID device, inStream, outStream;
    const char *name, *uid, *modelUID, *inName, *outName;
    UInt32 channels;
    Boolean outputCanBeDefault;   // hoparlör olarak varsayılan seçilebilir mi
    Boolean inputCanBeDefault;    // mikrofon olarak varsayılan seçilebilir mi
    // IO durumu
    UInt32 ioCount;               // StartIO sayacı (birden fazla istemci)
    UInt64 anchorHostTime;        // IO başladığı andaki mach_absolute_time
    UInt64 timestampCount;        // GetZeroTimeStamp için geçen periyot sayısı
    Float32 ring[kRingFrames * kMaxChannels];
    Float64 lastWriteEnd;         // en son yazılan bölümün bittiği örnek zamanı
    Float64 runStart;             // kesintisiz yazımın başladığı örnek zamanı
} Dev;

static Dev gDevs[2] = {
    { kObjDevice, kObjInputStream, kObjOutputStream,
      "Dikiz Mikrofon", "DikizMikrofon_UID", "DikizMikrofon_ModelUID",
      "Dikiz Mikrofon Girişi", "Dikiz Mikrofon Beslemesi",
      1, false, true, 0, 0, 0, {0}, -1, -1 },
    { kObjSpkDevice, kObjSpkInputStream, kObjSpkOutputStream,
      "Dikiz Hoparlör", "DikizHoparlor_UID", "DikizHoparlor_ModelUID",
      "Dikiz Hoparlör Kaydı", "Dikiz Hoparlör",
      2, true, false, 0, 0, 0, {0}, -1, -1 },
};
#define kDevCount 2

static Dev *DevForObject(AudioObjectID obj) {
    for (int i = 0; i < kDevCount; i++)
        if (gDevs[i].device == obj || gDevs[i].inStream == obj || gDevs[i].outStream == obj) return &gDevs[i];
    return NULL;
}

// ---- durum ----
static AudioServerPlugInHostRef gHost = NULL;
static pthread_mutex_t gStateLock = PTHREAD_MUTEX_INITIALIZER;
static UInt32 gRefCount = 0;
static Float64 gHostTicksPerFrame = 0; // bir örnek kaç host tıkı

// ---- yardımcılar ----
static AudioStreamBasicDescription StreamFormat(UInt32 channels) {
    AudioStreamBasicDescription f;
    memset(&f, 0, sizeof f);
    f.mSampleRate = kSampleRate;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    f.mBytesPerPacket = sizeof(Float32) * channels;
    f.mFramesPerPacket = 1;
    f.mBytesPerFrame = sizeof(Float32) * channels;
    f.mChannelsPerFrame = channels;
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

static Boolean StreamIsInput(AudioObjectID obj) { return obj == kObjInputStream || obj == kObjSpkInputStream; }

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
static Boolean IsDevice(AudioObjectID id) { Dev *v = DevForObject(id); return v && v->device == id; }

static OSStatus Dikiz_AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID id, const AudioServerPlugInClientInfo *ci) {
    (void)d; (void)ci; return IsDevice(id) ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}
static OSStatus Dikiz_RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID id, const AudioServerPlugInClientInfo *ci) {
    (void)d; (void)ci; return IsDevice(id) ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
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
    if (obj != kObjPlugIn) {
        Dev *v = DevForObject(obj);
        if (!v) return false;
        if (obj != v->device) obj = StreamIsInput(obj) ? kObjInputStream : kObjOutputStream;   // akış: aynı özellikler
        else obj = kObjDevice;
    }
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
    Dev *v = DevForObject(obj);
    *outSettable = v && obj != v->device &&
                   (a->mSelector == kAudioStreamPropertyVirtualFormat || a->mSelector == kAudioStreamPropertyPhysicalFormat);
    return kAudioHardwareNoError;
}

// Aygıtın sahip olduğu akışlar (kapsama göre)
static UInt32 DeviceStreams(const Dev *v, AudioObjectPropertyScope scope, AudioObjectID out[2]) {
    UInt32 n = 0;
    if (scope == kAudioObjectPropertyScopeGlobal || scope == kAudioObjectPropertyScopeInput) out[n++] = v->inStream;
    if (scope == kAudioObjectPropertyScopeGlobal || scope == kAudioObjectPropertyScopeOutput) out[n++] = v->outStream;
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
            UInt32 n = inDataSize / sizeof(AudioObjectID);
            if (n > kDevCount) n = kDevCount;
            for (UInt32 i = 0; i < n; i++) ((AudioObjectID *)outData)[i] = gDevs[i].device;
            *outDataSize = n * sizeof(AudioObjectID);
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
                for (int i = 0; uid && i < kDevCount; i++) {
                    CFStringRef mine = CFStringCreateWithCString(NULL, gDevs[i].uid, kCFStringEncodingUTF8);
                    if (CFStringCompare(uid, mine, 0) == kCFCompareEqualTo) found = gDevs[i].device;
                    CFRelease(mine);
                }
            }
            RETURN_VALUE(AudioObjectID, found);
        }
        case kAudioPlugInPropertyResourceBundle: RETURN_CFSTR("");
        }
        return kAudioHardwareUnknownPropertyError;

    }

    Dev *v = DevForObject(obj);
    if (!v) return kAudioHardwareBadObjectError;

    // ---------- aygıt ----------
    if (obj == v->device) {
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: RETURN_VALUE(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: RETURN_VALUE(AudioClassID, kAudioDeviceClassID);
        case kAudioObjectPropertyOwner: RETURN_VALUE(AudioObjectID, kObjPlugIn);
        case kAudioObjectPropertyName: RETURN_CFSTR(v->name);
        case kAudioObjectPropertyManufacturer: RETURN_CFSTR(kManufacturer);
        case kAudioDevicePropertyDeviceUID: RETURN_CFSTR(v->uid);
        case kAudioDevicePropertyModelUID: RETURN_CFSTR(v->modelUID);
        case kAudioDevicePropertyTransportType: RETURN_VALUE(UInt32, kAudioDeviceTransportTypeVirtual);
        case kAudioDevicePropertyRelatedDevices: RETURN_VALUE(AudioObjectID, v->device);
        case kAudioDevicePropertyClockDomain: RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertyDeviceIsAlive: RETURN_VALUE(UInt32, 1);
        case kAudioDevicePropertyDeviceIsRunning: {
            pthread_mutex_lock(&gStateLock); UInt32 running = v->ioCount > 0; pthread_mutex_unlock(&gStateLock);
            RETURN_VALUE(UInt32, running);
        }
        // Mikrofon: yalnızca giriş olarak varsayılan seçilebilir.
        // Hoparlör: yalnızca çıkış olarak (sistem sesleri dahil) varsayılan seçilebilir.
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            RETURN_VALUE(UInt32, a->mScope == kAudioObjectPropertyScopeInput ? v->inputCanBeDefault
                               : a->mScope == kAudioObjectPropertyScopeOutput ? v->outputCanBeDefault : 0);
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            RETURN_VALUE(UInt32, a->mScope == kAudioObjectPropertyScopeOutput ? v->outputCanBeDefault : 0);
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
            UInt32 ch[2] = { 1, v->channels == 2 ? 2 : 1 };
            return WriteData(inDataSize, outDataSize, outData, ch, sizeof ch);
        }
        case kAudioDevicePropertyPreferredChannelLayout: {
            AudioChannelLayout l;
            memset(&l, 0, sizeof l);
            l.mChannelLayoutTag = v->channels == 2 ? kAudioChannelLayoutTag_Stereo : kAudioChannelLayoutTag_Mono;
            return WriteData(inDataSize, outDataSize, outData, &l, offsetof(AudioChannelLayout, mChannelDescriptions));
        }
        case kAudioObjectPropertyControlList:
            *outDataSize = 0;
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyStreams: {
            AudioObjectID ids[2];
            UInt32 n = DeviceStreams(v, a->mScope, ids);
            UInt32 fit = inDataSize / sizeof(AudioObjectID);
            if (n > fit) n = fit;
            memcpy(outData, ids, n * sizeof(AudioObjectID));
            *outDataSize = n * sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        }
        }
        return kAudioHardwareUnknownPropertyError;
    }

    // ---------- akışlar ----------
    {
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: RETURN_VALUE(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: RETURN_VALUE(AudioClassID, kAudioStreamClassID);
        case kAudioObjectPropertyOwner: RETURN_VALUE(AudioObjectID, v->device);
        case kAudioObjectPropertyName: RETURN_CFSTR(StreamIsInput(obj) ? v->inName : v->outName);
        case kAudioStreamPropertyIsActive: RETURN_VALUE(UInt32, 1);
        case kAudioStreamPropertyDirection: RETURN_VALUE(UInt32, StreamIsInput(obj) ? 1 : 0);
        case kAudioStreamPropertyTerminalType:
            if (v->device == kObjSpkDevice)
                RETURN_VALUE(UInt32, StreamIsInput(obj) ? kAudioStreamTerminalTypeLine : kAudioStreamTerminalTypeSpeaker);
            RETURN_VALUE(UInt32, StreamIsInput(obj) ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeLine);
        case kAudioStreamPropertyStartingChannel: RETURN_VALUE(UInt32, 1);
        case kAudioStreamPropertyLatency: RETURN_VALUE(UInt32, 0);
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: {
            AudioStreamBasicDescription f = StreamFormat(v->channels);
            return WriteData(inDataSize, outDataSize, outData, &f, sizeof f);
        }
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            AudioStreamRangedDescription r;
            r.mFormat = StreamFormat(v->channels);
            r.mSampleRateRange.mMinimum = kSampleRate;
            r.mSampleRateRange.mMaximum = kSampleRate;
            return WriteData(inDataSize, outDataSize, outData, &r, sizeof r);
        }
        }
        return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus Dikiz_SetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a, UInt32 qSize, const void *q, UInt32 inDataSize, const void *inData) {
    (void)d; (void)pid; (void)qSize; (void)q;
    Dev *v = DevForObject(obj);
    if (v && obj != v->device &&
        (a->mSelector == kAudioStreamPropertyVirtualFormat || a->mSelector == kAudioStreamPropertyPhysicalFormat)) {
        if (inDataSize != sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
        const AudioStreamBasicDescription *f = inData;
        AudioStreamBasicDescription mine = StreamFormat(v->channels);
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
    if (!IsDevice(id)) return kAudioHardwareBadObjectError;
    Dev *v = DevForObject(id);
    pthread_mutex_lock(&gStateLock);
    if (v->ioCount == 0) {
        v->anchorHostTime = mach_absolute_time();
        v->timestampCount = 0;
        memset(v->ring, 0, sizeof v->ring);
        v->lastWriteEnd = -1;
        v->runStart = -1;
    }
    v->ioCount++;
    pthread_mutex_unlock(&gStateLock);
    return kAudioHardwareNoError;
}

static OSStatus Dikiz_StopIO(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client) {
    (void)d; (void)client;
    if (!IsDevice(id)) return kAudioHardwareBadObjectError;
    Dev *v = DevForObject(id);
    pthread_mutex_lock(&gStateLock);
    if (v->ioCount > 0) v->ioCount--;
    pthread_mutex_unlock(&gStateLock);
    return kAudioHardwareNoError;
}

// Saat: IO başladığı andan itibaren her kRingFrames örnekte bir "sıfır" zaman damgası.
static OSStatus Dikiz_GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed) {
    (void)d; (void)client;
    if (!IsDevice(id)) return kAudioHardwareBadObjectError;
    Dev *v = DevForObject(id);
    pthread_mutex_lock(&gStateLock);
    UInt64 now = mach_absolute_time();
    Float64 ticksPerPeriod = gHostTicksPerFrame * kRingFrames;
    UInt64 nextZero = v->anchorHostTime + (UInt64)((Float64)(v->timestampCount + 1) * ticksPerPeriod);
    if (nextZero <= now) v->timestampCount++;
    *outSampleTime = (Float64)(v->timestampCount * kRingFrames);
    *outHostTime = v->anchorHostTime + (UInt64)((Float64)v->timestampCount * ticksPerPeriod);
    *outSeed = 1;
    pthread_mutex_unlock(&gStateLock);
    return kAudioHardwareNoError;
}

static OSStatus Dikiz_WillDoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client, UInt32 op, Boolean *outWillDo, Boolean *outWillDoInPlace) {
    (void)d; (void)client;
    if (!IsDevice(id)) return kAudioHardwareBadObjectError;
    *outWillDo = (op == kAudioServerPlugInIOOperationReadInput || op == kAudioServerPlugInIOOperationWriteMix);
    *outWillDoInPlace = true;
    return kAudioHardwareNoError;
}

static OSStatus Dikiz_BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo *cycle) {
    (void)d; (void)client; (void)op; (void)frames; (void)cycle;
    return IsDevice(id) ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}

static OSStatus Dikiz_EndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo *cycle) {
    (void)d; (void)client; (void)op; (void)frames; (void)cycle;
    return IsDevice(id) ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}

// Halka tampona yaz / halka tampondan oku (örnek zamanına göre konum; kanallar iç içe).
static void RingWrite(Dev *v, Float64 sampleTime, const Float32 *src, UInt32 frames) {
    UInt64 start = (UInt64)sampleTime;
    UInt32 ch = v->channels;
    for (UInt32 i = 0; i < frames; i++) {
        UInt64 slot = ((start + i) % kRingFrames) * ch;
        for (UInt32 c = 0; c < ch; c++) v->ring[slot + c] = src[i * ch + c];
    }
}

static void RingRead(Dev *v, Float64 sampleTime, Float32 *dst, UInt32 frames) {
    // Yalnızca son yazılan aralıkta kalan örnekler gerçek sestir; gerisi sessizlik.
    // Böylece besleme durunca eski ses tekrar tekrar çalmaz.
    Float64 validStart = v->lastWriteEnd - kRingFrames;
    if (validStart < v->runStart) validStart = v->runStart;
    if (validStart < 0) validStart = 0;
    UInt32 ch = v->channels;
    for (UInt32 i = 0; i < frames; i++) {
        Float64 t = sampleTime + i;
        Boolean ok = v->lastWriteEnd >= 0 && t < v->lastWriteEnd && t >= validStart;
        UInt64 slot = (((UInt64)t) % kRingFrames) * ch;
        for (UInt32 c = 0; c < ch; c++) dst[i * ch + c] = ok ? v->ring[slot + c] : 0;
    }
}

static OSStatus Dikiz_DoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, AudioObjectID stream, UInt32 client, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo *cycle, void *mainBuf, void *secBuf) {
    (void)d; (void)client; (void)secBuf;
    if (!IsDevice(id)) return kAudioHardwareBadObjectError;
    Dev *v = DevForObject(id);
    if (mainBuf == NULL || frames == 0) return kAudioHardwareNoError;
    if (op == kAudioServerPlugInIOOperationWriteMix && stream == v->outStream) {
        Float64 t = cycle->mOutputTime.mSampleTime;
        // Arada boşluk varsa (besleme durup yeniden başladıysa) yeni bir "kesintisiz yazım" başlar.
        if (v->lastWriteEnd < 0 || t > v->lastWriteEnd || t + frames < v->lastWriteEnd - kRingFrames) v->runStart = t;
        RingWrite(v, t, (const Float32 *)mainBuf, frames);
        if (t + frames > v->lastWriteEnd) v->lastWriteEnd = t + frames;
    } else if (op == kAudioServerPlugInIOOperationReadInput && stream == v->inStream) {
        RingRead(v, cycle->mInputTime.mSampleTime, (Float32 *)mainBuf, frames);
    }
    return kAudioHardwareNoError;
}
