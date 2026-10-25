#ifndef CMultitouchSupport_h
#define CMultitouchSupport_h

/*
 Declarations matching the private MultitouchSupport.framework, as documented by MiddleClick
 (https://github.com/artginzburg/MiddleClick) and Kivy's `mactouch` provider, and verified against a Magic Trackpad on
 macOS 27. Nothing is linked: ``MultitouchSupport`` resolves the functions at runtime, so a macOS release dropping one of
 them leaves the dispatcher silent instead of keeping the process from launching.

 C keeps the struct layout exactly as the framework writes it, which Swift structs do not guarantee.
 */

#include <stdbool.h>
#include <stdint.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>

typedef struct {
    float x;
    float y;
} CMTPoint;

typedef struct {
    CMTPoint position;
    CMTPoint velocity;
} CMTVector;

/// One contact of a frame. 96 bytes.
typedef struct {
    int32_t frame;
    double timestamp;
    /// Stays the same for a finger from landing to lifting
    int32_t identifier;
    /// See `CMTTouchStage`
    int32_t stage;
    int32_t fingerID;
    int32_t handID;
    /// Position in 0...1 of the sensor's width and height, origin at the bottom left; velocity in those units per second
    CMTVector normalized;
    /// The contact's area
    float total;
    float pressure;
    /// The contact ellipse
    float angle;
    float majorAxis;
    float minorAxis;
    /// Position and velocity in millimetres, around the sensor's centre
    CMTVector absolute;
    int32_t unknown14;
    int32_t unknown15;
    float density;
} CMTTouch;

typedef enum {
    CMTTouchStageNotTracking = 0,
    CMTTouchStageStartInRange = 1,
    CMTTouchStageHoverInRange = 2,
    CMTTouchStageMakeTouch = 3,
    CMTTouchStageTouching = 4,
    CMTTouchStageBreakTouch = 5,
    CMTTouchStageLingerInRange = 6,
    CMTTouchStageOutOfRange = 7
} CMTTouchStage;

typedef void *CMTDeviceRef;

/// Receives every frame of a started device, on a thread of the framework's. `touches` holds `count` contacts, hovering
/// ones included.
typedef int32_t (*CMTContactCallback)(CMTDeviceRef device, CMTTouch *touches, int32_t count, double timestamp, int32_t frame);

typedef CFArrayRef (*CMTDeviceCreateListFunction)(void);
typedef CMTDeviceRef (*CMTDeviceCreateFromServiceFunction)(io_service_t service);
typedef bool (*CMTRegisterContactFrameCallbackFunction)(CMTDeviceRef device, CMTContactCallback callback);
typedef bool (*CMTUnregisterContactFrameCallbackFunction)(CMTDeviceRef device, CMTContactCallback callback);
typedef void (*CMTDeviceStartFunction)(CMTDeviceRef device, int32_t runMode);
typedef void (*CMTDeviceStopFunction)(CMTDeviceRef device);
typedef void (*CMTDeviceReleaseFunction)(CMTDeviceRef device);
typedef bool (*CMTDeviceIsBuiltInFunction)(CMTDeviceRef device);
typedef bool (*CMTDeviceIsRunningFunction)(CMTDeviceRef device);
typedef int32_t (*CMTDeviceGetSensorSurfaceDimensionsFunction)(CMTDeviceRef device, int32_t *width, int32_t *height);
typedef int32_t (*CMTDeviceGetDeviceIDFunction)(CMTDeviceRef device, uint64_t *deviceID);

#endif /* CMultitouchSupport_h */
