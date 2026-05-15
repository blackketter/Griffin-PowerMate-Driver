#include "VolumeKeys.h"
#include <IOKit/hidsystem/IOHIDUserDevice.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <stdio.h>

// HID report descriptor: Consumer Control with mute, volume up, volume down.
// 1-byte report: bit0=mute, bit1=vol-up, bit2=vol-down, bits3-7=padding.
static const uint8_t kDescriptor[] = {
    0x05, 0x0C,        // Usage Page (Consumer)
    0x09, 0x01,        // Usage (Consumer Control)
    0xA1, 0x01,        // Collection (Application)
    0x15, 0x00,        // Logical Minimum (0)
    0x25, 0x01,        // Logical Maximum (1)
    0x75, 0x01,        // Report Size (1 bit)
    0x95, 0x03,        // Report Count (3)
    0x09, 0xE2,        // Usage (Mute)             bit 0
    0x09, 0xE9,        // Usage (Volume Increment)  bit 1
    0x09, 0xEA,        // Usage (Volume Decrement)  bit 2
    0x81, 0x02,        // Input (Data, Variable, Absolute)
    0x75, 0x05,        // Report Size (5 bits) — padding
    0x95, 0x01,        // Report Count (1)
    0x81, 0x03,        // Input (Constant)
    0xC0               // End Collection
};

static IOHIDUserDeviceRef gDevice = NULL;

void VolumeKeysCreate(void) {
    CFDataRef descriptor = CFDataCreate(kCFAllocatorDefault, kDescriptor, sizeof(kDescriptor));
    CFNumberRef vendorID  = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &(int){0x05AC});
    CFNumberRef productID = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &(int){0x0FFF});

    CFStringRef keys[]   = { CFSTR(kIOHIDReportDescriptorKey), CFSTR(kIOHIDProductKey),
                              CFSTR(kIOHIDVendorIDKey),         CFSTR(kIOHIDProductIDKey) };
    CFTypeRef   values[] = { descriptor, CFSTR("PowerMate Volume Keys"), vendorID, productID };
    CFDictionaryRef props = CFDictionaryCreate(kCFAllocatorDefault,
                                               (const void **)keys, (const void **)values, 4,
                                               &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
    gDevice = IOHIDUserDeviceCreateWithProperties(kCFAllocatorDefault, props, 0);
    CFRelease(props); CFRelease(descriptor); CFRelease(vendorID); CFRelease(productID);

    if (gDevice) {
        fprintf(stderr, "VolumeKeys: device created OK, activating\n");
        IOHIDUserDeviceSetDispatchQueue(gDevice, dispatch_get_main_queue());
        IOHIDUserDeviceActivate(gDevice);
    } else {
        fprintf(stderr, "VolumeKeys: IOHIDUserDeviceCreateWithProperties returned NULL\n");
    }
}

static void send(uint8_t bits) {
    if (!gDevice) { fprintf(stderr, "VolumeKeys: send called but gDevice is NULL\n"); return; }
    uint64_t ts = mach_absolute_time();
    IOReturn r = IOHIDUserDeviceHandleReportWithTimeStamp(gDevice, ts, &bits, 1);
    fprintf(stderr, "VolumeKeys: send bits=0x%02x result=0x%08x\n", bits, r);
    bits = 0;
    r = IOHIDUserDeviceHandleReportWithTimeStamp(gDevice, ts + 1000000, &bits, 1);
    if (r != 0) fprintf(stderr, "VolumeKeys: send release result=0x%08x\n", r);
}

void VolumeKeysSendUp(void)   { send(0x02); }
void VolumeKeysSendDown(void) { send(0x04); }
void VolumeKeysSendMute(void) { send(0x01); }
