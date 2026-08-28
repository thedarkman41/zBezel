// ddc.h — C transport layer for DDC/CI and DisplayPort AUX on macOS.
// Deliberately free of IOKit types so it can serve as a Swift bridging header.
#ifndef BEZEL_DDC_H
#define BEZEL_DDC_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---- Result codes -----------------------------------------------------------
#define BEZEL_OK               0    // transaction succeeded
#define BEZEL_UNSUPPORTED      1    // display answered, but does not implement this VCP code
#define BEZEL_ERR_NO_FB       -1    // no IOFramebuffer matched this display
#define BEZEL_ERR_NO_BUS      -2    // framebuffer exposes no I2C bus
#define BEZEL_ERR_OPEN        -3    // could not open the I2C interface
#define BEZEL_ERR_IO          -4    // the bus transaction failed (NACK / timeout / driver error)
#define BEZEL_ERR_PROTOCOL    -5    // display replied, but the reply was malformed
#define BEZEL_ERR_ARG         -6

// ---- Link diagnosis ---------------------------------------------------------
// Describes what is actually on the far end of the video link, which is what
// determines whether DDC/CI can work at all.
typedef struct {
    int32_t framebufferFound;   // 1 if a matching IOFramebuffer was located
    int32_t i2cBusCount;        // number of I2C buses the framebuffer exposes
    int32_t busType;            // 1 = native I2C, 2 = DisplayPort AUX
    int32_t transactionTypes;   // bitmask of supported IOI2C transaction types

    int32_t edidReadOK;         // EDID readable over I2C-over-AUX at 0xA0
    int32_t ddcAddressACK;      // display ACKs the DDC/CI address (0x37 / 0x6E)
    int32_t ddcReplyOK;         // a full DDC/CI Get VCP round trip succeeded

    int32_t dpcdReadOK;         // raw DPCD readable over native AUX
    uint8_t dpcdRev;            // DPCD 0x0000
    uint8_t maxLinkRate;        // DPCD 0x0001
    uint8_t maxLaneCount;       // DPCD 0x0002
    uint8_t downstreamPort;     // DPCD 0x0005
    uint8_t mstCap;             // DPCD 0x0021
    uint8_t mstCtrl;            // DPCD 0x0111

    // Identity of the devices on the link. A populated branch block with an
    // empty sink block means an intermediate device (dock / MST hub) is
    // terminating AUX — the usual reason DDC/CI is unreachable.
    int32_t branchPresent;
    uint8_t branchOUI[3];
    char    branchDeviceID[8];
    uint8_t branchHWRev;
    uint8_t branchFWMajor;
    uint8_t branchFWMinor;

    int32_t sinkPresent;
    uint8_t sinkOUI[3];
    char    sinkDeviceID[8];

    int32_t lastIOReturn;       // raw IOReturn from the failing transaction
} BezelLinkReport;

// ---- API --------------------------------------------------------------------

// Read a VCP feature. Returns BEZEL_OK, BEZEL_UNSUPPORTED, or a negative error.
int32_t bezel_ddc_get_vcp(uint32_t displayID, uint8_t vcp,
                          uint16_t *current, uint16_t *maximum, uint8_t *vcpType);

// Write a VCP feature. Returns BEZEL_OK or a negative error.
// DDC/CI Set has no acknowledgement, so success only means the bus accepted it.
int32_t bezel_ddc_set_vcp(uint32_t displayID, uint8_t vcp, uint16_t value);

// Read the monitor's capabilities string (VCP 0xF3 / reply 0xE3).
// Returns the number of bytes written, or a negative error.
int32_t bezel_ddc_capabilities(uint32_t displayID, char *out, uint32_t outCapacity);

// Characterise the link. Always safe: performs only reads.
int32_t bezel_diagnose(uint32_t displayID, BezelLinkReport *out);

// Read the raw EDID over I2C-over-AUX (not the cached IORegistry copy).
// Returns bytes read, or a negative error.
int32_t bezel_read_edid(uint32_t displayID, uint8_t *out, uint32_t outCapacity);

#ifdef __cplusplus
}
#endif
#endif
