#ifndef VolumeKeys_h
#define VolumeKeys_h

// Creates a virtual HID Consumer Control device that sends volume key events
// through the kernel HID stack — the same path as a real keyboard, so macOS
// shows the system volume HUD.
// Call VolumeKeysCreate() once at startup, then use the send functions.

void VolumeKeysCreate(void);
void VolumeKeysSendUp(void);
void VolumeKeysSendDown(void);
void VolumeKeysSendMute(void);

#endif
