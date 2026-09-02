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
/// Connect, wait until the server reports the session logged on, disconnect.
///
/// Returns 0 on success, with the session the server logged us into in
/// `session_id_out` (0 when the server did not say). On failure returns a
/// non-zero code and fills `error_name`: FreeRDP's own symbolic connect error,
/// HOST_KEY_MISMATCH, one of the LOGON_* verdicts the server gave after
/// accepting the credentials, DROPPED_BEFORE_LOGON, or LOGON_TIMEOUT (the
/// server accepted the connection but reported no logon within 30 s). A name
/// is far more useful than a bare number when this fails at 2am on a machine
/// you cannot see.
///
/// Blocking, up to ~40 s; call it off the main thread.
int zbezel_rdp_touch(const char *host,
                     uint16_t    port,
                     const char *username,
                     const char *domain,      /* may be NULL */
                     const char *password,
                     const char *expected_fingerprint, /* NULL = accept any (see note) */
                     char       *error_name,  /* caller buffer */
                     int         error_name_len,
                     char       *fingerprint_out, /* caller buffer, may be NULL */
                     int         fingerprint_out_len,
                     uint32_t   *session_id_out); /* may be NULL */

#endif
