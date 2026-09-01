#ifndef ZBEZEL_RDP_H
#define ZBEZEL_RDP_H

#include <stdint.h>

/// Establish an RDP session on a Windows host, then drop it.
///
/// This is not a remote desktop. zBezel needs RDP for exactly one thing: on a
/// machine with no reachable keyboard, the login screen is the Winlogon secure
/// desktop, and Windows blocks synthetic input to it by design — so the KVM
/// cannot get past it and never will. RDP authenticates over the network
/// instead, and a session that is disconnected rather than signed out survives
/// as Disconnected. `BezelAgent reclaim` (running as SYSTEM, because the move
/// needs SeTcbPrivilege) then puts that session on the physical console.
///
/// So there is no framebuffer, no input, no clipboard, and no channels in use.
/// Connect, confirm a session exists, disconnect.
///
/// Returns 0 on success. On failure returns FreeRDP's connect error code and
/// fills `error_name` with its symbolic name, which is far more useful than a
/// bare number when this fails at 2am on a machine you cannot see.
///
/// Blocking; call it off the main thread.
int zbezel_rdp_touch(const char *host,
                     uint16_t    port,
                     const char *username,
                     const char *domain,      /* may be NULL */
                     const char *password,
                     const char *expected_fingerprint, /* NULL = accept any (see note) */
                     char       *error_name,  /* caller buffer */
                     int         error_name_len,
                     char       *fingerprint_out, /* caller buffer, may be NULL */
                     int         fingerprint_out_len);

#endif
