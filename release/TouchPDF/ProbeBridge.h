#ifndef TRACKPAD_PROBE_BRIDGE_H
#define TRACKPAD_PROBE_BRIDGE_H
#include <stdbool.h>
#include <stdint.h>

// Layout adapted from OpenMultitouchSupport's MIT-licensed OpenMTInternal.h.
// These private fields have no Apple ABI or physical-unit guarantee.
typedef struct { float x, y; } ProbePoint;
typedef struct { ProbePoint position, velocity; } ProbeVector;
typedef struct {
    int32_t frame;
    double timestamp;
    int32_t identifier, state, fingerId, handId;
    ProbeVector normalized;
    float total, pressure, angle, majorAxis, minorAxis;
    ProbeVector absolute;
    int32_t field14, field15;
    float density;
} ProbeTouch;

typedef struct {
    double frameworkTime;
    uint64_t sampledNanoseconds;
    int32_t frame, count;
    bool hidMouseDown, combinedMouseDown;
    ProbeTouch touches[16];
} ProbeFrame;

bool probe_start(void);
void probe_stop(void);
bool probe_read(ProbeFrame *frame);
const char *probe_status(void);
uint64_t probe_dropped(void);
uint64_t probe_invalid(void);
int probe_builtin(void);
int probe_family(void);
uint64_t probe_now(void);
#endif
