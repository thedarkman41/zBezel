// RDP, used only to make a session exist. See rdp.h for why.
//
// C rather than Swift because FreeRDP's client entry points are a struct of C
// function pointers filled in before the context exists — the same reason
// ddc.c is C.

#include "rdp.h"

#include <freerdp/freerdp.h>
#include <freerdp/client.h>
#include <freerdp/settings.h>
#include <freerdp/error.h>
#include <winpr/winpr.h>

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
} zbContext;

static BOOL zb_pre_connect(freerdp *instance)
{
    (void)instance;
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
                     char *fingerprint_out, int fingerprint_out_len)
{
    if (error_name && error_name_len > 0) error_name[0] = '\0';
    if (fingerprint_out && fingerprint_out_len > 0) fingerprint_out[0] = '\0';
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

    rdpSettings *s = context->settings;
    freerdp_settings_set_string(s, FreeRDP_ServerHostname, host);
    freerdp_settings_set_uint32(s, FreeRDP_ServerPort, port ? port : 3389);
    freerdp_settings_set_string(s, FreeRDP_Username, username);
    if (domain && domain[0]) freerdp_settings_set_string(s, FreeRDP_Domain, domain);
    if (password) freerdp_settings_set_string(s, FreeRDP_Password, password);

    /* NLA: authenticate before a session is created, which is what makes this
       safe to point at a login screen in the first place. */
    freerdp_settings_set_bool(s, FreeRDP_NlaSecurity, TRUE);

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

    /* Connected. Drop it immediately: a disconnected session is precisely what
       `BezelAgent reclaim` looks for. Signing out would destroy it instead. */
    freerdp_disconnect(context->instance);
    freerdp_client_context_free(context);
    return 0;
}
