// ddc.c — DDC/CI + DisplayPort AUX transport over IOFramebuffer's I2C interface.
//
// This is the Intel-Mac path: IOFBCopyI2CInterfaceForBus / IOI2CSendRequest.
// On a DisplayPort bus the driver carries our I2C transactions over the AUX
// channel. Two distinct things travel that channel and it matters which:
//
//   * I2C-over-AUX to address 0xA0  -> the EDID
//   * I2C-over-AUX to address 0x6E  -> DDC/CI (VESA MCCS)
//   * native AUX reads              -> DPCD, which identifies the link itself
//
// A dock or MST hub commonly proxies the first and refuses the second, so the
// diagnosis path below reads DPCD to name whichever device is really answering.

#include "ddc.h"

#include <string.h>
#include <stdio.h>
#include <unistd.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/i2c/IOI2CInterface.h>
#include <IOKit/graphics/IOGraphicsTypes.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreFoundation/CoreFoundation.h>

#define DDC_WRITE_ADDR   0x6E
#define DDC_READ_ADDR    0x6F
#define DDC_SOURCE_ADDR  0x51
#define EDID_WRITE_ADDR  0xA0
#define EDID_READ_ADDR   0xA1

#define MS(x) ((uint64_t)(x) * 1000000ULL)

// ---------------------------------------------------------------------------
// Locating the IOFramebuffer that drives a given CGDirectDisplayID.
// ---------------------------------------------------------------------------

static int number_prop(io_service_t s, CFStringRef key, int *out) {
    CFNumberRef n = IORegistryEntryCreateCFProperty(s, key, kCFAllocatorDefault, 0);
    if (!n) return 0;
    int ok = 0;
    if (CFGetTypeID(n) == CFNumberGetTypeID()) ok = CFNumberGetValue(n, kCFNumberIntType, out);
    CFRelease(n);
    return ok;
}

// Walk a framebuffer's children looking for the IODisplay node, and report the
// EDID identity it advertises.
static int framebuffer_identity(io_service_t fb, int *vendor, int *product, int *serial) {
    io_iterator_t it;
    if (IORegistryEntryCreateIterator(fb, kIOServicePlane,
            kIORegistryIterateRecursively, &it) != KERN_SUCCESS) return 0;
    int found = 0;
    io_service_t child;
    while ((child = IOIteratorNext(it))) {
        int v = 0, p = 0, s = 0;
        if (number_prop(child, CFSTR("DisplayVendorID"), &v) &&
            number_prop(child, CFSTR("DisplayProductID"), &p)) {
            number_prop(child, CFSTR("DisplaySerialNumber"), &s);
            *vendor = v; *product = p; *serial = s;
            found = 1;
        }
        IOObjectRelease(child);
        if (found) break;
    }
    IOObjectRelease(it);
    return found;
}

static io_service_t framebuffer_for_display(uint32_t displayID) {
    CGDirectDisplayID did = (CGDirectDisplayID)displayID;
    uint32_t wantVendor = CGDisplayVendorNumber(did);
    uint32_t wantProduct = CGDisplayModelNumber(did);
    uint32_t wantSerial = CGDisplaySerialNumber(did);

    io_iterator_t it;
    if (IOServiceGetMatchingServices(kIOMainPortDefault,
            IOServiceMatching("IOFramebuffer"), &it) != KERN_SUCCESS) return 0;

    io_service_t fb, exact = 0, loose = 0;
    while ((fb = IOIteratorNext(it))) {
        int v = 0, p = 0, s = 0;
        if (framebuffer_identity(fb, &v, &p, &s)) {
            if ((uint32_t)v == wantVendor && (uint32_t)p == wantProduct) {
                if ((uint32_t)s == wantSerial && !exact) { exact = fb; continue; }
                if (!loose) { loose = fb; continue; }
            }
        }
        IOObjectRelease(fb);
    }
    IOObjectRelease(it);

    if (exact) { if (loose) IOObjectRelease(loose); return exact; }
    return loose;
}

// ---------------------------------------------------------------------------
// Framebuffer rotation.
//
// Turning the panel is a GPU transform on the IOFramebuffer, NOT a monitor
// command — so it works on this Mac even though the dock refuses DDC/CI and
// every VCP has to be proxied through the PC. IOServiceRequestProbe carries the
// request; kIOFBSetTransform (0x400) is the private option that tells the
// framebuffer to read a rotation out of bits 16+, and the rotation is one of the
// public kIOScaleRotate* scaler flags. This is the mechanism fb-rotate and its
// kin have used for years; it is stable where it is present (Intel).
// ---------------------------------------------------------------------------

#define BEZEL_FB_SET_TRANSFORM 0x00000400u

int32_t bezel_display_rotate(uint32_t displayID, int32_t degrees) {
    uint32_t flag;
    switch (((degrees % 360) + 360) % 360) {
        case 0:   flag = kIOScaleRotate0;   break;
        case 90:  flag = kIOScaleRotate90;  break;
        case 180: flag = kIOScaleRotate180; break;
        case 270: flag = kIOScaleRotate270; break;
        default:  return BEZEL_ERR_ARG;
    }
    io_service_t fb = framebuffer_for_display(displayID);
    if (!fb) return BEZEL_ERR_NO_FB;
    kern_return_t kr = IOServiceRequestProbe(fb, BEZEL_FB_SET_TRANSFORM | (flag << 16));
    IOObjectRelease(fb);
    return kr == KERN_SUCCESS ? BEZEL_OK : BEZEL_ERR_IO;
}

// ---------------------------------------------------------------------------
// Bus plumbing
// ---------------------------------------------------------------------------

typedef struct {
    io_service_t fb;
    io_service_t iface;
    IOI2CConnectRef connect;
} BezelBus;

static int bus_open(uint32_t displayID, BezelBus *b) {
    memset(b, 0, sizeof(*b));
    b->fb = framebuffer_for_display(displayID);
    if (!b->fb) return BEZEL_ERR_NO_FB;

    IOItemCount count = 0;
    if (IOFBGetI2CInterfaceCount(b->fb, &count) != kIOReturnSuccess || count == 0) {
        IOObjectRelease(b->fb); b->fb = 0;
        return BEZEL_ERR_NO_BUS;
    }
    if (IOFBCopyI2CInterfaceForBus(b->fb, 0, &b->iface) != kIOReturnSuccess) {
        IOObjectRelease(b->fb); b->fb = 0;
        return BEZEL_ERR_NO_BUS;
    }
    if (IOI2CInterfaceOpen(b->iface, kNilOptions, &b->connect) != kIOReturnSuccess) {
        IOObjectRelease(b->iface); IOObjectRelease(b->fb);
        b->iface = 0; b->fb = 0;
        return BEZEL_ERR_OPEN;
    }
    return BEZEL_OK;
}

static void bus_close(BezelBus *b) {
    if (b->connect) IOI2CInterfaceClose(b->connect, kNilOptions);
    if (b->iface) IOObjectRelease(b->iface);
    if (b->fb) IOObjectRelease(b->fb);
    memset(b, 0, sizeof(*b));
}

static IOReturn raw_xact(BezelBus *b,
                         uint32_t sendType, uint32_t sendAddr, const uint8_t *sendBuf, uint32_t sendLen,
                         uint32_t replyType, uint32_t replyAddr, uint8_t *replyBuf, uint32_t replyLen,
                         uint64_t delayNs, uint32_t *bytesRead) {
    IOI2CRequest r;
    memset(&r, 0, sizeof(r));
    r.sendTransactionType = sendType;
    r.sendAddress = sendAddr;
    r.sendBuffer = (vm_address_t)sendBuf;
    r.sendBytes = sendLen;
    r.minReplyDelay = delayNs;
    r.replyTransactionType = replyType;
    r.replyAddress = replyAddr;
    r.replyBuffer = (vm_address_t)replyBuf;
    r.replyBytes = replyLen;

    IOReturn kr = IOI2CSendRequest(b->connect, kNilOptions, &r);
    if (bytesRead) *bytesRead = r.replyBytes;
    return (kr == kIOReturnSuccess) ? r.result : kr;
}

// Frame and send one DDC/CI message, optionally collecting a reply.
static IOReturn ddc_message(BezelBus *b, const uint8_t *payload, uint32_t payloadLen,
                            uint8_t *reply, uint32_t replyLen, uint32_t *got) {
    uint8_t frame[40];
    if (payloadLen + 3 > sizeof(frame)) return kIOReturnBadArgument;

    frame[0] = DDC_SOURCE_ADDR;
    frame[1] = (uint8_t)(0x80 | payloadLen);
    memcpy(&frame[2], payload, payloadLen);

    // Checksum is seeded with the destination address, which the bus sends for us.
    uint8_t sum = DDC_WRITE_ADDR;
    for (uint32_t i = 0; i < payloadLen + 2; i++) sum ^= frame[i];
    frame[payloadLen + 2] = sum;

    return raw_xact(b,
                    kIOI2CSimpleTransactionType, DDC_WRITE_ADDR, frame, payloadLen + 3,
                    reply ? kIOI2CDDCciReplyTransactionType : kIOI2CNoTransactionType,
                    DDC_READ_ADDR, reply, replyLen,
                    reply ? MS(40) : 0, got);
}

// Read-only by construction: the send phase is always kIOI2CNoTransactionType,
// so this can never write DPCD. Writing DPCD can perturb link training and has
// no legitimate use here.
static int dpcd_read(BezelBus *b, uint32_t offset, uint8_t *out, uint32_t len) {
    return raw_xact(b, kIOI2CNoTransactionType, 0, NULL, 0,
                    kIOI2CDisplayPortNativeTransactionType, offset, out, len,
                    0, NULL) == kIOReturnSuccess;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

static int32_t get_vcp_on(BezelBus *b, uint8_t vcp,
                          uint16_t *current, uint16_t *maximum, uint8_t *vcpType) {
    uint8_t payload[2] = { 0x01, vcp };
    for (int attempt = 0; attempt < 4; attempt++) {
        uint8_t reply[16];
        uint32_t got = 0;
        memset(reply, 0, sizeof(reply));
        IOReturn r = ddc_message(b, payload, 2, reply, 11, &got);
        if (r != kIOReturnSuccess) { usleep(60000); continue; }

        // Expected: 6E 88 02 <result> <vcp> <type> <maxH> <maxL> <curH> <curL> <chk>
        if (reply[2] != 0x02) { usleep(60000); continue; }
        if (reply[3] == 0x01) return BEZEL_UNSUPPORTED;
        if (reply[3] != 0x00) { usleep(60000); continue; }
        if (reply[4] != vcp)  { usleep(60000); continue; }

        if (vcpType) *vcpType = reply[5];
        if (maximum) *maximum = (uint16_t)((reply[6] << 8) | reply[7]);
        if (current) *current = (uint16_t)((reply[8] << 8) | reply[9]);
        return BEZEL_OK;
    }
    return BEZEL_ERR_IO;
}

int32_t bezel_ddc_get_vcp(uint32_t displayID, uint8_t vcp,
                          uint16_t *current, uint16_t *maximum, uint8_t *vcpType) {
    BezelBus b;
    int rc = bus_open(displayID, &b);
    if (rc != BEZEL_OK) return rc;
    int32_t out = get_vcp_on(&b, vcp, current, maximum, vcpType);
    bus_close(&b);
    return out;
}

int32_t bezel_ddc_set_vcp(uint32_t displayID, uint8_t vcp, uint16_t value) {
    BezelBus b;
    int rc = bus_open(displayID, &b);
    if (rc != BEZEL_OK) return rc;

    uint8_t payload[4] = { 0x03, vcp, (uint8_t)(value >> 8), (uint8_t)(value & 0xFF) };
    IOReturn r = kIOReturnError;
    for (int attempt = 0; attempt < 3; attempt++) {
        r = ddc_message(&b, payload, 4, NULL, 0, NULL);
        if (r == kIOReturnSuccess) break;
        usleep(60000);
    }
    usleep(50000);   // MCCS requires a settle period after a write
    bus_close(&b);
    return (r == kIOReturnSuccess) ? BEZEL_OK : BEZEL_ERR_IO;
}

int32_t bezel_ddc_capabilities(uint32_t displayID, char *out, uint32_t outCapacity) {
    if (!out || outCapacity < 2) return BEZEL_ERR_ARG;
    BezelBus b;
    int rc = bus_open(displayID, &b);
    if (rc != BEZEL_OK) return rc;

    uint32_t written = 0;
    uint16_t offset = 0;
    int consecutiveFailures = 0;
    int sawAnything = 0;

    while (written < outCapacity - 1 && offset < 8192) {
        uint8_t payload[3] = { 0xF3, (uint8_t)(offset >> 8), (uint8_t)(offset & 0xFF) };
        uint8_t reply[64];
        uint32_t got = 0;
        memset(reply, 0, sizeof(reply));

        IOReturn r = ddc_message(&b, payload, 3, reply, 39, &got);
        if (r != kIOReturnSuccess || reply[2] != 0xE3) {
            if (++consecutiveFailures > 3) break;
            usleep(80000);
            continue;
        }
        consecutiveFailures = 0;
        sawAnything = 1;

        // reply: 6E <0x80|len> E3 <offH> <offL> <data...> <chk>
        int payloadLen = (reply[1] & 0x7F);
        int dataLen = payloadLen - 3;
        if (dataLen <= 0) break;            // zero-length fragment terminates the string

        // reply[1] comes from the monitor, so payloadLen can claim up to 127 and
        // dataLen up to 124 — far past this 64-byte buffer. Clamp to what the
        // buffer holds and to what was actually received. A well-formed fragment
        // answering a 39-byte request has payloadLen <= 36, so this never fires
        // in normal operation; it only stops a malformed or truncated reply from
        // copying adjacent stack into the capabilities string.
        int maxFragment = (int)sizeof(reply) - 6;      // 5 header bytes + checksum
        if (got >= 6 && (int)got - 6 < maxFragment) maxFragment = (int)got - 6;
        if (dataLen > maxFragment) dataLen = maxFragment;
        if (dataLen <= 0) break;

        for (int i = 0; i < dataLen && written < outCapacity - 1; i++)
            out[written++] = (char)reply[5 + i];
        offset = (uint16_t)(offset + dataLen);
        usleep(50000);
    }

    out[written] = '\0';
    bus_close(&b);
    if (!sawAnything) return BEZEL_ERR_IO;
    return (int32_t)written;
}

int32_t bezel_read_edid(uint32_t displayID, uint8_t *out, uint32_t outCapacity) {
    if (!out || outCapacity < 128) return BEZEL_ERR_ARG;
    BezelBus b;
    int rc = bus_open(displayID, &b);
    if (rc != BEZEL_OK) return rc;

    uint32_t total = 0;
    for (uint32_t block = 0; block < outCapacity / 128 && block < 2; block++) {
        uint8_t offset = (uint8_t)(block * 128);
        uint32_t got = 0;
        IOReturn r = raw_xact(&b, kIOI2CSimpleTransactionType, EDID_WRITE_ADDR, &offset, 1,
                              kIOI2CSimpleTransactionType, EDID_READ_ADDR, out + total, 128,
                              0, &got);
        if (r != kIOReturnSuccess) break;
        total += 128;
        if (block == 0 && out[126] == 0) break;   // no extension blocks
        usleep(20000);
    }
    bus_close(&b);
    return total ? (int32_t)total : BEZEL_ERR_IO;
}

int32_t bezel_diagnose(uint32_t displayID, BezelLinkReport *out) {
    if (!out) return BEZEL_ERR_ARG;
    memset(out, 0, sizeof(*out));

    BezelBus b;
    int rc = bus_open(displayID, &b);
    if (rc != BEZEL_OK) return rc;
    out->framebufferFound = 1;

    IOItemCount count = 0;
    IOFBGetI2CInterfaceCount(b.fb, &count);
    out->i2cBusCount = (int32_t)count;
    number_prop(b.iface, CFSTR("IOI2CBusType"), &out->busType);
    number_prop(b.iface, CFSTR("IOI2CTransactionTypes"), &out->transactionTypes);

    uint8_t buf[32];

    // 1. Can we read the EDID over I2C-over-AUX? Proves the I2C path works.
    {
        uint8_t offset = 0;
        uint32_t got = 0;
        IOReturn r = raw_xact(&b, kIOI2CSimpleTransactionType, EDID_WRITE_ADDR, &offset, 1,
                              kIOI2CSimpleTransactionType, EDID_READ_ADDR, buf, 8, 0, &got);
        out->edidReadOK = (r == kIOReturnSuccess &&
                           buf[0] == 0x00 && buf[1] == 0xFF && buf[2] == 0xFF) ? 1 : 0;
    }
    usleep(30000);

    // 2. Does anything ACK the DDC/CI address? Send the DDC/CI null message — a
    //    well-formed zero-length packet a compliant display is required to
    //    discard. That isolates the address-level ACK from any question of DDC
    //    framing without putting a stray byte into the display's state machine.
    {
        uint8_t nullMessage[3];
        nullMessage[0] = DDC_SOURCE_ADDR;
        nullMessage[1] = 0x80;                  // length 0
        nullMessage[2] = DDC_WRITE_ADDR ^ nullMessage[0] ^ nullMessage[1];
        IOReturn r = raw_xact(&b, kIOI2CSimpleTransactionType, DDC_WRITE_ADDR, nullMessage, 3,
                              kIOI2CNoTransactionType, 0, NULL, 0, 0, NULL);
        out->ddcAddressACK = (r == kIOReturnSuccess) ? 1 : 0;
        out->lastIOReturn = (int32_t)r;
    }
    usleep(50000);

    // 3. Full DDC/CI round trip (VCP 0xDF = MCCS version; harmless and universal).
    if (out->ddcAddressACK) {
        uint16_t cur = 0, max = 0; uint8_t type = 0;
        out->ddcReplyOK = (get_vcp_on(&b, 0xDF, &cur, &max, &type) == BEZEL_OK) ? 1 : 0;
    }

    // 4. DPCD — identifies who is actually terminating the AUX channel.
    if (dpcd_read(&b, 0x00000, buf, 8)) {
        out->dpcdReadOK = 1;
        out->dpcdRev = buf[0];
        out->maxLinkRate = buf[1];
        out->maxLaneCount = buf[2];
        out->downstreamPort = buf[5];
    }
    usleep(15000);
    if (dpcd_read(&b, 0x00021, buf, 1)) out->mstCap = buf[0];
    usleep(15000);
    if (dpcd_read(&b, 0x00111, buf, 1)) out->mstCtrl = buf[0];
    usleep(15000);

    if (dpcd_read(&b, 0x00400, buf, 12)) {
        memcpy(out->sinkOUI, buf, 3);
        memcpy(out->sinkDeviceID, buf + 3, 6);
        out->sinkDeviceID[6] = '\0';
        out->sinkPresent = (buf[0] | buf[1] | buf[2]) ? 1 : 0;
    }
    usleep(15000);
    if (dpcd_read(&b, 0x00500, buf, 12)) {
        memcpy(out->branchOUI, buf, 3);
        memcpy(out->branchDeviceID, buf + 3, 6);
        out->branchDeviceID[6] = '\0';
        out->branchPresent = (buf[0] | buf[1] | buf[2]) ? 1 : 0;
        out->branchHWRev = buf[9];
        out->branchFWMajor = buf[10];
        out->branchFWMinor = buf[11];
    }

    bus_close(&b);
    return BEZEL_OK;
}
