// RDP, used only to make a session exist. See rdp.h for why.
//
// C rather than Swift because FreeRDP's client entry points are a struct of C
// function pointers filled in before the context exists — the same reason
// ddc.c is C.

#include "rdp.h"

#include <freerdp/freerdp.h>
#include <freerdp/client.h>
#include <freerdp/settings.h>
#include <freerdp/session.h>
#include <freerdp/update.h>
#include <freerdp/error.h>
#include <winpr/winpr.h>
#include <winpr/synch.h>
#include <winpr/sysinfo.h>

#include <string.h>
#include <stdio.h>

/// Carried through the context so the callbacks can see what the caller wanted.
/// FreeRDP allocates this for us when ContextSize says so.
typedef struct
{
    rdpContext  common;
    const char *expected_fingerprint;
    char       *fingerprint_out;
    int         fingerprint_out_len;
    int         fingerprint_matched;

    /* What the server said about the logon, from its Save Session Info and
       Logon Error Info PDUs. Written by the callbacks, read by the wait loop
       in zbezel_rdp_touch — same thread, no locking needed. */
    int         logon_seen;
    UINT32      logon_session;
    int         logon_failed;
    char        logon_error[64];
} zbContext;

/// The server reports the session it logged us into. This is the moment the
/// touch is FOR. Until it arrives the session is a ConnectQuery placeholder
/// with nobody in it — measured on rigel: disconnecting the instant the
/// connection sequence finished left the console untouched, and Windows
/// simply tore the placeholder down.
static BOOL zb_save_session_info(rdpContext *context, UINT32 type, void *data)
{
    zbContext *ctx = (zbContext *)context;
    switch (type)
    {
        case INFO_TYPE_LOGON:
        case INFO_TYPE_LOGON_LONG:
            if (data) ctx->logon_session = ((const logon_info *)data)->sessionId;
            ctx->logon_seen = 1;
            break;

        case INFO_TYPE_LOGON_PLAIN_NOTIFY:
            ctx->logon_seen = 1;
            break;

        case INFO_TYPE_LOGON_EXTENDED_INF:
        {
            const logon_info_ex *ex = (const logon_info_ex *)data;
            if (ex && ex->haveErrorInfo)
            {
                snprintf(ctx->logon_error, sizeof ctx->logon_error, "LOGON_ERROR_%08X_%08X",
                         (unsigned)ex->ErrorNotificationType, (unsigned)ex->ErrorNotificationData);
                ctx->logon_failed = 1;
            }
            else if (ex && ex->haveCookie)
            {
                /* The auto-reconnect cookie is only issued once the user is
                   logged on, so it is as good as a logon notice. */
                ctx->logon_seen = 1;
            }
            break;
        }

        default:
            break;
    }
    return TRUE;
}

/// Winlogon's verdict when it is bad news. LOGON_MSG_SESSION_CONTINUE is the
/// one benign value ("carry on"); anything else means the credentials were
/// good enough for the connection but the logon itself is not happening, and
/// waiting for a session notice that will never come would only time out.
static int zb_logon_error_info(freerdp *instance, UINT32 data, UINT32 type)
{
    zbContext *ctx = (zbContext *)instance->context;
    if (type == LOGON_MSG_SESSION_CONTINUE) return 1;

    const char *why;
    switch (data)
    {
        case LOGON_FAILED_BAD_PASSWORD:    why = "LOGON_FAILED_BAD_PASSWORD"; break;
        case LOGON_FAILED_UPDATE_PASSWORD: why = "LOGON_FAILED_UPDATE_PASSWORD"; break;
        case LOGON_FAILED_OTHER:           why = "LOGON_FAILED_OTHER"; break;
        case LOGON_WARNING:                why = "LOGON_WARNING"; break;
        default:                           why = NULL; break;
    }
    const char *how;
    switch (type)
    {
        case LOGON_MSG_DISCONNECT_REFUSED:   how = "DISCONNECT_REFUSED"; break;
        case LOGON_MSG_NO_PERMISSION:        how = "NO_PERMISSION"; break;
        case LOGON_MSG_BUMP_OPTIONS:         how = "BUMP_OPTIONS"; break;
        case LOGON_MSG_RECONNECT_OPTIONS:    how = "RECONNECT_OPTIONS"; break;
        case LOGON_MSG_SESSION_TERMINATE:    how = "SESSION_TERMINATE"; break;
        case LOGON_MSG_SESSION_BUSY_OPTIONS: how = "SESSION_BUSY"; break;
        default:                             how = NULL; break;
    }
    if (why && how)      snprintf(ctx->logon_error, sizeof ctx->logon_error, "%s_%s", why, how);
    else if (why)        snprintf(ctx->logon_error, sizeof ctx->logon_error, "%s", why);
    else if (how)        snprintf(ctx->logon_error, sizeof ctx->logon_error, "LOGON_MSG_%s", how);
    else                 snprintf(ctx->logon_error, sizeof ctx->logon_error, "LOGON_MSG_%08X_%08X",
                                  (unsigned)type, (unsigned)data);
    ctx->logon_failed = 1;
    return 1;
}

static BOOL zb_pre_connect(freerdp *instance)
{
    /* Registered before the connection sequence, not after it: a session that
       reconnects to an existing desktop can report its logon while the
       sequence is still running, and a callback installed in PostConnect
       would miss it. */
    instance->context->update->SaveSessionInfo = zb_save_session_info;
    return TRUE;
}

static BOOL zb_post_connect(freerdp *instance)
{
    (void)instance;
    return TRUE;
}

static void zb_post_disconnect(freerdp *instance)
{
    (void)instance;
}

/// The host key.
///
/// Blanket-accepting here would mean trusting whatever answers on that address,
/// which is exactly the property ssh's known_hosts exists to deny. So when the
/// caller supplies a fingerprint we compare and refuse on mismatch. The first
/// connection has nothing to compare against: it reports the fingerprint back
/// so the caller can pin it, the same shape as ssh's first-contact prompt.
static DWORD zb_verify_certificate(freerdp *instance, const char *host, UINT16 port,
                                   const char *common_name, const char *subject,
                                   const char *issuer, const char *fingerprint,
                                   DWORD flags)
{
    (void)host; (void)port; (void)common_name; (void)subject; (void)issuer; (void)flags;

    zbContext *ctx = (zbContext *)instance->context;

    if (ctx->fingerprint_out && ctx->fingerprint_out_len > 0 && fingerprint)
    {
        strncpy(ctx->fingerprint_out, fingerprint, (size_t)ctx->fingerprint_out_len - 1);
        ctx->fingerprint_out[ctx->fingerprint_out_len - 1] = '\0';
    }

    if (!ctx->expected_fingerprint || !ctx->expected_fingerprint[0])
    {
        ctx->fingerprint_matched = 1;   /* nothing pinned yet */
        return 2;                       /* accept */
    }

    if (fingerprint && strcmp(fingerprint, ctx->expected_fingerprint) == 0)
    {
        ctx->fingerprint_matched = 1;
        return 2;
    }

    ctx->fingerprint_matched = 0;
    return 0;                           /* reject */
}

/// Credentials come from the caller (Beacon's broker), never a prompt. Without
/// this FreeRDP falls back to reading a password off the terminal, which in a
/// GUI app means a tcgetattr failure on a socket and a connection that dies
/// somewhere confusing.
static BOOL zb_authenticate(freerdp *instance, char **username, char **password, char **domain,
                            rdp_auth_reason reason)
{
    (void)instance; (void)username; (void)password; (void)domain; (void)reason;
    return TRUE;   /* already set in settings; do not prompt, whatever asked */
}

static BOOL zb_client_new(freerdp *instance, rdpContext *context)
{
    (void)context;
    instance->PreConnect          = zb_pre_connect;
    instance->PostConnect         = zb_post_connect;
    instance->PostDisconnect      = zb_post_disconnect;
    instance->VerifyCertificateEx = zb_verify_certificate;
    instance->AuthenticateEx      = zb_authenticate;
    instance->LogonErrorInfo      = zb_logon_error_info;
    return TRUE;
}

static void zb_client_free(freerdp *instance, rdpContext *context) { (void)instance; (void)context; }
static int  zb_client_start(rdpContext *context) { (void)context; return 0; }
static int  zb_client_stop(rdpContext *context)  { (void)context; return 0; }
static BOOL zb_global_init(void)   { return TRUE; }
static void zb_global_uninit(void) { }

int zbezel_rdp_touch(const char *host, uint16_t port,
                     const char *username, const char *domain, const char *password,
                     const char *expected_fingerprint,
                     char *error_name, int error_name_len,
                     char *fingerprint_out, int fingerprint_out_len,
                     uint32_t *session_id_out)
{
    if (error_name && error_name_len > 0) error_name[0] = '\0';
    if (fingerprint_out && fingerprint_out_len > 0) fingerprint_out[0] = '\0';
    if (session_id_out) *session_id_out = 0;
    if (!host || !username) return -1;

    RDP_CLIENT_ENTRY_POINTS ep;
    memset(&ep, 0, sizeof(ep));
    ep.Version      = RDP_CLIENT_INTERFACE_VERSION;
    ep.Size         = sizeof(ep);
    ep.ContextSize  = sizeof(zbContext);
    ep.GlobalInit   = zb_global_init;
    ep.GlobalUninit = zb_global_uninit;
    ep.ClientNew    = zb_client_new;
    ep.ClientFree   = zb_client_free;
    ep.ClientStart  = zb_client_start;
    ep.ClientStop   = zb_client_stop;

    rdpContext *context = freerdp_client_context_new(&ep);
    if (!context)
    {
        if (error_name && error_name_len > 0)
            snprintf(error_name, (size_t)error_name_len, "CONTEXT_NEW_FAILED");
        return -1;
    }

    zbContext *zb = (zbContext *)context;
    zb->expected_fingerprint = expected_fingerprint;
    zb->fingerprint_out      = fingerprint_out;
    zb->fingerprint_out_len  = fingerprint_out_len;
    zb->fingerprint_matched  = 0;
    zb->logon_seen           = 0;
    zb->logon_session        = 0;
    zb->logon_failed         = 0;
    zb->logon_error[0]       = '\0';

    rdpSettings *s = context->settings;
    freerdp_settings_set_string(s, FreeRDP_ServerHostname, host);
    freerdp_settings_set_uint32(s, FreeRDP_ServerPort, port ? port : 3389);
    freerdp_settings_set_string(s, FreeRDP_Username, username);
    if (domain && domain[0]) freerdp_settings_set_string(s, FreeRDP_Domain, domain);
    if (password) freerdp_settings_set_string(s, FreeRDP_Password, password);

    /* NLA: authenticate before a session is created, which is what makes this
       safe to point at a login screen in the first place. */
    freerdp_settings_set_bool(s, FreeRDP_NlaSecurity, TRUE);

    /* LOG ON with these, do not merely present them. Without AutoLogon the
       server accepts the credentials for the connection and then puts a logon
       screen inside the session — which nobody is there to fill in, so the
       session sits in ConnectQuery with no user and the console never moves. */
    freerdp_settings_set_bool(s, FreeRDP_AutoLogonEnabled, TRUE);

    /* No pixels. Nothing decodes them and nobody looks at them. */
    freerdp_settings_set_bool(s, FreeRDP_DeactivateClientDecoding, TRUE);
    freerdp_settings_set_uint32(s, FreeRDP_DesktopWidth, 1024);
    freerdp_settings_set_uint32(s, FreeRDP_DesktopHeight, 768);
    freerdp_settings_set_uint32(s, FreeRDP_ColorDepth, 16);

    /* No redirection of anything. This session is a means to an end. */
    freerdp_settings_set_bool(s, FreeRDP_AudioPlayback, FALSE);
    freerdp_settings_set_bool(s, FreeRDP_AudioCapture, FALSE);
    freerdp_settings_set_bool(s, FreeRDP_RedirectClipboard, FALSE);
    freerdp_settings_set_bool(s, FreeRDP_DeviceRedirection, FALSE);
    freerdp_settings_set_bool(s, FreeRDP_RedirectDrives, FALSE);
    freerdp_settings_set_bool(s, FreeRDP_RedirectPrinters, FALSE);
    freerdp_settings_set_bool(s, FreeRDP_RedirectSmartCards, FALSE);

    BOOL ok = freerdp_connect(context->instance);

    if (!ok)
    {
        UINT32 code = freerdp_get_last_error(context);
        if (error_name && error_name_len > 0)
        {
            const char *name = freerdp_get_last_error_name(code);
            snprintf(error_name, (size_t)error_name_len, "%s", name ? name : "UNKNOWN");
        }
        /* A rejected host key surfaces as a generic connect failure; say which
           it was, because the remedies could not be more different. */
        if (zb->expected_fingerprint && zb->expected_fingerprint[0] && !zb->fingerprint_matched
            && error_name && error_name_len > 0)
            snprintf(error_name, (size_t)error_name_len, "HOST_KEY_MISMATCH");

        freerdp_client_context_free(context);
        return (int)(code ? code : 1);
    }

    /* Connected, which only means the wire is up and the credentials passed
       NLA. Now wait for Winlogon: the server says which session it put us in,
       or why it will not. Pumping the connection is what delivers those PDUs
       to the callbacks above; nothing else is decoded. */
    const ULONGLONG deadline = GetTickCount64() + 30000;
    int dropped = 0;
    while (!zb->logon_seen && !zb->logon_failed)
    {
        if (GetTickCount64() >= deadline) break;

        HANDLE handles[64];
        DWORD n = freerdp_get_event_handles(context, handles, 64);
        if (n == 0) { dropped = 1; break; }

        DWORD st = WaitForMultipleObjects(n, handles, FALSE, 250);
        if (st == WAIT_FAILED) { dropped = 1; break; }

        if (!freerdp_check_event_handles(context)) { dropped = 1; break; }
        if (freerdp_shall_disconnect_context(context)) { dropped = 1; break; }
    }

    int rc;
    if (zb->logon_seen)
    {
        if (session_id_out) *session_id_out = zb->logon_session;
        rc = 0;
    }
    else if (zb->logon_failed)
    {
        if (error_name && error_name_len > 0)
            snprintf(error_name, (size_t)error_name_len, "%s", zb->logon_error);
        rc = 2;
    }
    else if (dropped)
    {
        UINT32 code = freerdp_get_last_error(context);
        if (error_name && error_name_len > 0)
        {
            const char *name = code ? freerdp_get_last_error_name(code) : NULL;
            snprintf(error_name, (size_t)error_name_len, "%s", name ? name : "DROPPED_BEFORE_LOGON");
        }
        rc = (int)(code ? code : 3);
    }
    else
    {
        if (error_name && error_name_len > 0)
            snprintf(error_name, (size_t)error_name_len, "LOGON_TIMEOUT");
        rc = 4;
    }

    /* Drop it either way, and drop it rather than sign out: a disconnected
       session survives, and is precisely what `BezelAgent reclaim` looks for. */
    freerdp_disconnect(context->instance);
    freerdp_client_context_free(context);
    return rc;
}
