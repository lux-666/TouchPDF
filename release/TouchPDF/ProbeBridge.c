#include "ProbeBridge.h"
#include <CoreGraphics/CoreGraphics.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

_Static_assert(sizeof(ProbeTouch) == 96, "Unexpected private touch ABI");
_Static_assert(offsetof(ProbeTouch, total) == 48, "Unexpected total offset");
_Static_assert(offsetof(ProbeTouch, pressure) == 52, "Unexpected pressure offset");
_Static_assert(offsetof(ProbeTouch, density) == 92, "Unexpected density offset");

typedef void (*ContactCallback)(void *, ProbeTouch *, int, double, int);
static void *library, *device;
static void *(*createDevice)(void);
static void (*registerContact)(void *, ContactCallback);
static void (*unregisterContact)(void *, ContactCallback);
static int32_t (*startDevice)(void *, int);
static int32_t (*stopDevice)(void *);
static void (*releaseDevice)(void *);
static bool (*isRunning)(void *);
static bool (*isBuiltIn)(void *);
static int32_t (*getFamily)(void *, int *);
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static ProbeFrame queue[512];
static unsigned readIndex, writeIndex, queued;
static uint64_t dropped, invalid;
static bool accepting;
static char status[256] = "Not started";
static int builtIn = -1, family = -1;

uint64_t probe_now(void) {
    struct timespec time;
    clock_gettime(CLOCK_MONOTONIC, &time);
    return (uint64_t)time.tv_sec * 1000000000ULL + time.tv_nsec;
}

static void contact(void *sender, ProbeTouch *touches, int count, double timestamp, int frame) {
    (void)sender;
    ProbeFrame value = {0};
    value.sampledNanoseconds = probe_now();
    value.hidMouseDown = CGEventSourceButtonState(kCGEventSourceStateHIDSystemState, kCGMouseButtonLeft);
    value.combinedMouseDown = CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, kCGMouseButtonLeft);
    value.frameworkTime = timestamp;
    value.frame = frame;
    pthread_mutex_lock(&lock);
    if (!accepting) { pthread_mutex_unlock(&lock); return; }
    if (count < 0 || count > 16 || (count && !touches)) {
        invalid++;
        pthread_mutex_unlock(&lock);
        return;
    }
    value.count = count;
    if (count) memcpy(value.touches, touches, (size_t)count * sizeof(ProbeTouch));
    if (queued == 512) { dropped++; readIndex = (readIndex + 1) % 512; queued--; }
    queue[writeIndex] = value;
    writeIndex = (writeIndex + 1) % 512;
    queued++;
    pthread_mutex_unlock(&lock);
}

bool probe_start(void) {
    if (device) return true;
    if (!library) library = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW | RTLD_LOCAL);
    if (!library) { snprintf(status, sizeof(status), "dlopen failed: %.180s", dlerror()); return false; }
#define LOAD(function, symbol) *(void **)(&function) = dlsym(library, symbol)
    LOAD(createDevice, "MTDeviceCreateDefault");
    LOAD(registerContact, "MTRegisterContactFrameCallback");
    LOAD(unregisterContact, "MTUnregisterContactFrameCallback");
    LOAD(startDevice, "MTDeviceStart");
    LOAD(stopDevice, "MTDeviceStop");
    LOAD(releaseDevice, "MTDeviceRelease");
    LOAD(isRunning, "MTDeviceIsRunning");
    LOAD(isBuiltIn, "MTDeviceIsBuiltIn");
    LOAD(getFamily, "MTDeviceGetFamilyID");
#undef LOAD
    if (!createDevice || !registerContact || !unregisterContact || !startDevice || !stopDevice || !releaseDevice || !isRunning) {
        snprintf(status, sizeof(status), "Required private symbol missing");
        return false;
    }
    device = createDevice();
    if (!device) { snprintf(status, sizeof(status), "No default multitouch device"); return false; }
    builtIn = isBuiltIn ? (isBuiltIn(device) ? 1 : 0) : -1;
    family = -1;
    if (getFamily && getFamily(device, &family)) family = -1;
    pthread_mutex_lock(&lock);
    queued = readIndex = writeIndex = 0;
    dropped = invalid = 0;
    accepting = true;
    pthread_mutex_unlock(&lock);
    registerContact(device, contact);
    int32_t result = startDevice(device, 0);
    bool running = isRunning(device);
    snprintf(status, sizeof(status), "MTDeviceStart return=%d; isRunning=%s; ABI=96 bytes", result, running ? "true" : "false");
    if (!running) { probe_stop(); return false; }
    return true;
}

void probe_stop(void) {
    pthread_mutex_lock(&lock);
    accepting = false;
    pthread_mutex_unlock(&lock);
    if (device) {
        unregisterContact(device, contact);
        stopDevice(device);
        releaseDevice(device);
        device = NULL;
    }
    // Keep the library loaded: a private driver may still have a callback in flight.
}

bool probe_read(ProbeFrame *frame) {
    pthread_mutex_lock(&lock);
    bool available = queued > 0;
    if (available) { *frame = queue[readIndex]; readIndex = (readIndex + 1) % 512; queued--; }
    pthread_mutex_unlock(&lock);
    return available;
}
const char *probe_status(void) { return status; }
int probe_builtin(void) { return builtIn; }
int probe_family(void) { return family; }
uint64_t probe_dropped(void) { pthread_mutex_lock(&lock); uint64_t value = dropped; pthread_mutex_unlock(&lock); return value; }
uint64_t probe_invalid(void) { pthread_mutex_lock(&lock); uint64_t value = invalid; pthread_mutex_unlock(&lock); return value; }
