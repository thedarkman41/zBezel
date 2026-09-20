// A live RDP session with pixels. See rdp_session.h for what and why.
//
// C, like rdp.c and ddc.c, because FreeRDP's client is a struct of C function
// pointers filled in before the context exists.

#include "rdp_session.h"

#include <freerdp/freerdp.h>
#include <freerdp/client.h>
#include <freerdp/settings.h>
#include <freerdp/session.h>
#include <freerdp/update.h>
#include <freerdp/graphics.h>
#include <freerdp/error.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/gdi/gfx.h>
#include <freerdp/codec/color.h>
#include <freerdp/input.h>
#include <freerdp/event.h>
#include <freerdp/channels/rdpgfx.h>
#include <winpr/winpr.h>
#include <winpr/synch.h>
#include <winpr/sysinfo.h>

#include <pthread.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <limits.h>

// ---- input queue ----------------------------------------------------------

enum { EV_MOUSE, EV_WHEEL, EV_KEY, EV_UNICODE, EV_SYNC };

typedef struct
{
    int      type;
    uint16_t flags;   // mouse PTR_FLAGS
    int      x, y;
    int      notches;
    uint8_t  scancode;
    int      extended;
    int      down;
    uint16_t code;    // unicode
    uint32_t sync;
} in_ev;

#define QCAP 512

struct zbezel_rdp_session
{
    freerdp    *instance;
    rdpContext *context;

    zbezel_rdp_frame_cb frame_cb;
    zbezel_rdp_state_cb state_cb;
    void       *cb_ctx;

    char       *expected_fingerprint;   // strdup'd, or NULL
    char       *fingerprint_out;
    int         fingerprint_out_len;
    int         fingerprint_matched;
    /* Set the moment the server presents a certificate. Without it,
     * "fingerprint did not match" is indistinguishable from "we never got far
     * enough to see one" — and a machine that is simply switched off then
     * reports a host-key mismatch. See the error naming in session_thread. */
    int         cert_checked;

    int         want_width, want_height;

    pthread_t   thread;
    pthread_mutex_t lock;
    pthread_cond_t  started_cv;
    int         connect_result;         // 0 pending, 1 ok, -1 fail
    char        error_name[128];

    volatile int running;
    volatile int want_refresh;

    in_ev       q[QCAP];
    int         qhead, qtail;
};

/// The context FreeRDP allocates, carrying only a back-pointer to us.
typedef struct
{
    rdpContext common;
    zbezel_rdp_session *owner;
} zbSessionContext;

static zbezel_rdp_session *owner_of(rdpContext *context)
{
    return ((zbSessionContext *)context)->owner;
}

static void enqueue(zbezel_rdp_session *s, const in_ev *e)
{
    pthread_mutex_lock(&s->lock);
    int next = (s->qtail + 1) % QCAP;
    if (next != s->qhead)   // drop on overflow rather than block the UI
    {
        s->q[s->qtail] = *e;
        s->qtail = next;
    }
    pthread_mutex_unlock(&s->lock);
    // The session thread polls its wait with an 8ms timeout, so a queued event
    // is picked up within a frame; no wake is needed, and none must break the
    // event wait.
}

// ---- callbacks ------------------------------------------------------------

static BOOL zb_pointer_new(rdpContext *c, rdpPointer *p) { (void)c; (void)p; return TRUE; }
static void zb_pointer_free(rdpContext *c, rdpPointer *p) { (void)c; (void)p; }
static BOOL zb_pointer_set(rdpContext *c, rdpPointer *p) { (void)c; (void)p; return TRUE; }
static BOOL zb_pointer_setnull(rdpContext *c) { (void)c; return TRUE; }
static BOOL zb_pointer_setdefault(rdpContext *c) { (void)c; return TRUE; }
static BOOL zb_pointer_setpos(rdpContext *c, UINT32 x, UINT32 y) { (void)c; (void)x; (void)y; return TRUE; }

static BOOL zb_begin_paint(rdpContext *context)
{
    rdpGdi *gdi = context->gdi;
    if (gdi && gdi->primary && gdi->primary->hdc && gdi->primary->hdc->hwnd)
    {
        gdi->primary->hdc->hwnd->invalid->null = TRUE;
        gdi->primary->hdc->hwnd->ninvalid = 0;
    }
    return TRUE;
}

static BOOL zb_end_paint(rdpContext *context)
{
    zbezel_rdp_session *s = owner_of(context);
    rdpGdi *gdi = context->gdi;
    if (!gdi || !gdi->primary || !gdi->primary_buffer) return TRUE;
    if (!gdi->primary->hdc || !gdi->primary->hdc->hwnd) return TRUE;

    INT32 ninvalid = gdi->primary->hdc->hwnd->ninvalid;
    if (ninvalid < 1) return TRUE;
    HGDI_RGN cinvalid = gdi->primary->hdc->hwnd->cinvalid;

    int x1 = INT_MAX, y1 = INT_MAX, x2 = 0, y2 = 0;
    for (INT32 i = 0; i < ninvalid; i++)
    {
        int rx = cinvalid[i].x, ry = cinvalid[i].y, rw = cinvalid[i].w, rh = cinvalid[i].h;
        if (rw <= 0 || rh <= 0) continue;
        if (rx < x1) x1 = rx;
        if (ry < y1) y1 = ry;
        if (rx + rw > x2) x2 = rx + rw;
        if (ry + rh > y2) y2 = ry + rh;
    }
    gdi->primary->hdc->hwnd->ninvalid = 0;
    if (x2 <= x1 || y2 <= y1) return TRUE;

    if (x1 < 0) x1 = 0;
    if (y1 < 0) y1 = 0;
    if (x2 > gdi->width) x2 = gdi->width;
    if (y2 > gdi->height) y2 = gdi->height;

    if (s->frame_cb)
        s->frame_cb(s->cb_ctx, gdi->primary_buffer, gdi->width, gdi->height,
                    (int)gdi->stride, x1, y1, x2 - x1, y2 - y1);
    return TRUE;
}

static BOOL zb_desktop_resize(rdpContext *context)
{
    zbezel_rdp_session *s = owner_of(context);
    rdpGdi *gdi = context->gdi;
    UINT32 w = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopWidth);
    UINT32 h = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopHeight);
    if (!gdi_resize(gdi, w, h)) return FALSE;
    if (s->state_cb)
    {
        char dim[32];
        snprintf(dim, sizeof dim, "%ux%u", (unsigned)w, (unsigned)h);
        s->state_cb(s->cb_ctx, 4, dim);
    }
    return TRUE;
}

/// The one place a certificate is judged, shared by the new- and
/// changed-certificate callbacks.
///
/// Returns 1 ("accept AND STORE") rather than 2 ("accept for this session
/// only") on a match, deliberately: returning 2 leaves FreeRDP's own store
/// empty, so every later connection re-enters the new/changed path and depends
/// on a callback answering correctly. Storing keeps FreeRDP's view in step
/// with the pin instead of letting the two drift apart.
static DWORD zb_decide_certificate(zbezel_rdp_session *s, const char *fingerprint)
{
    s->cert_checked = 1;
    if (s->fingerprint_out && s->fingerprint_out_len > 0 && fingerprint)
    {
        strncpy(s->fingerprint_out, fingerprint, (size_t)s->fingerprint_out_len - 1);
        s->fingerprint_out[s->fingerprint_out_len - 1] = '\0';
    }
    /* No pin yet: first contact, take it and record it (the caller reads it
     * back out of fingerprint_out and pins it). */
    if (!s->expected_fingerprint || !s->expected_fingerprint[0]) { s->fingerprint_matched = 1; return 1; }
    if (fingerprint && strcmp(fingerprint, s->expected_fingerprint) == 0) { s->fingerprint_matched = 1; return 1; }
    s->fingerprint_matched = 0;
    return 0;
}

static DWORD zb_verify_certificate(freerdp *instance, const char *host, UINT16 port,
                                   const char *common_name, const char *subject,
                                   const char *issuer, const char *fingerprint, DWORD flags)
{
    (void)host; (void)port; (void)common_name; (void)subject; (void)issuer; (void)flags;
    return zb_decide_certificate(owner_of(instance->context), fingerprint);
}

/// The CHANGED-certificate callback.
///
/// FreeRDP keeps its own known-hosts store (~/.config/freerdp/server/*.pem)
/// alongside our pin, and when the certificate it has on file differs from the
/// one presented it asks HERE rather than through VerifyCertificateEx. Leaving
/// this NULL means "reject", which is how a machine whose certificate we pin
/// and accept could still fail verification — the two stores disagreeing, with
/// only FreeRDP's getting a vote.
///
/// Our pin is the authority: this defers to exactly the same comparison. The
/// old fingerprint is deliberately ignored — what the far end presents either
/// matches what the user pinned or it does not, and FreeRDP's cached opinion of
/// a previous certificate adds nothing to that question.
static DWORD zb_verify_changed_certificate(freerdp *instance, const char *host, UINT16 port,
                                           const char *common_name, const char *subject,
                                           const char *issuer, const char *new_fingerprint,
                                           const char *old_subject, const char *old_issuer,
                                           const char *old_fingerprint, DWORD flags)
{
    (void)host; (void)port; (void)common_name; (void)subject; (void)issuer;
    (void)old_subject; (void)old_issuer; (void)old_fingerprint; (void)flags;
    return zb_decide_certificate(owner_of(instance->context), new_fingerprint);
}

static BOOL zb_authenticate(freerdp *instance, char **u, char **p, char **d, rdp_auth_reason reason)
{
    (void)instance; (void)u; (void)p; (void)d; (void)reason;
    return TRUE;   /* already in settings */
}

/// The RDP Graphics Pipeline (RDPGFX) is a dynamic channel: it appears after
/// the connection sequence, and its surface commands — H.264 among them — have
/// to be pointed at our software-GDI framebuffer, or the desktop simply never
/// draws. gdi_graphics_pipeline_init wires the channel's output into the same
/// primary surface our BeginPaint/EndPaint already watch, so the frame path
/// downstream is unchanged whether a region arrived as H.264 or RemoteFX.
static void zb_channel_connected(void *context, const ChannelConnectedEventArgs *e)
{
    rdpContext *ctx = (rdpContext *)context;
    if (strcmp(e->name, RDPGFX_DVC_CHANNEL_NAME) == 0)
        gdi_graphics_pipeline_init(ctx->gdi, (RdpgfxClientContext *)e->pInterface);
}

static void zb_channel_disconnected(void *context, const ChannelDisconnectedEventArgs *e)
{
    rdpContext *ctx = (rdpContext *)context;
    if (strcmp(e->name, RDPGFX_DVC_CHANNEL_NAME) == 0)
        gdi_graphics_pipeline_uninit(ctx->gdi, (RdpgfxClientContext *)e->pInterface);
}

static BOOL zb_pre_connect(freerdp *instance)
{
    // Before the channels come up, so the GFX channel's arrival is caught.
    PubSub_SubscribeChannelConnected(instance->context->pubSub, zb_channel_connected);
    PubSub_SubscribeChannelDisconnected(instance->context->pubSub, zb_channel_disconnected);
    return TRUE;
}

static BOOL zb_post_connect(freerdp *instance)
{
    rdpContext *context = instance->context;
    zbezel_rdp_session *s = owner_of(context);

    if (!gdi_init(instance, PIXEL_FORMAT_BGRA32)) return FALSE;

    rdpPointer pointer;
    memset(&pointer, 0, sizeof pointer);
    pointer.size        = sizeof(rdpPointer);
    pointer.New         = zb_pointer_new;
    pointer.Free        = zb_pointer_free;
    pointer.Set         = zb_pointer_set;
    pointer.SetNull     = zb_pointer_setnull;
    pointer.SetDefault  = zb_pointer_setdefault;
    pointer.SetPosition = zb_pointer_setpos;
    graphics_register_pointer(context->graphics, &pointer);

    context->update->BeginPaint    = zb_begin_paint;
    context->update->EndPaint      = zb_end_paint;
    context->update->DesktopResize = zb_desktop_resize;

    if (s->state_cb) s->state_cb(s->cb_ctx, 1, NULL);
    return TRUE;
}

static void zb_post_disconnect(freerdp *instance) { (void)instance; }

static BOOL zb_client_new(freerdp *instance, rdpContext *context)
{
    (void)context;
    instance->PreConnect          = zb_pre_connect;
    instance->PostConnect         = zb_post_connect;
    instance->PostDisconnect      = zb_post_disconnect;
    instance->VerifyCertificateEx = zb_verify_certificate;
    /* Without this one, a certificate FreeRDP has cached and now sees differ
     * is rejected outright, whatever our pin says. */
    instance->VerifyChangedCertificateEx = zb_verify_changed_certificate;
    instance->AuthenticateEx      = zb_authenticate;
    return TRUE;
}

static void zb_client_free(freerdp *instance, rdpContext *context) { (void)instance; (void)context; }
static int  zb_client_start(rdpContext *context) { (void)context; return 0; }
static int  zb_client_stop(rdpContext *context)  { (void)context; return 0; }

// ---- input drain (session thread) -----------------------------------------

static void drain_input(zbezel_rdp_session *s)
{
    rdpInput *input = s->context->input;
    for (;;)
    {
        in_ev e;
        pthread_mutex_lock(&s->lock);
        if (s->qhead == s->qtail) { pthread_mutex_unlock(&s->lock); break; }
        e = s->q[s->qhead];
        s->qhead = (s->qhead + 1) % QCAP;
        pthread_mutex_unlock(&s->lock);

        switch (e.type)
        {
            case EV_MOUSE:
                freerdp_input_send_mouse_event(input, e.flags, (UINT16)e.x, (UINT16)e.y);
                break;
            case EV_WHEEL:
            {
                UINT16 f = PTR_FLAGS_WHEEL;
                int rot = e.notches * 120;
                if (rot < 0) { f |= PTR_FLAGS_WHEEL_NEGATIVE; f |= ((UINT16)(-rot)) & 0x01FF; }
                else         { f |= ((UINT16)rot) & 0x01FF; }
                freerdp_input_send_mouse_event(input, f, 0, 0);
                break;
            }
            case EV_KEY:
            {
                UINT16 f = e.extended ? KBD_FLAGS_EXTENDED : 0;
                if (!e.down) f |= KBD_FLAGS_RELEASE;
                freerdp_input_send_keyboard_event(input, f, e.scancode);
                break;
            }
            case EV_UNICODE:
            {
                UINT16 f = e.down ? 0 : KBD_FLAGS_RELEASE;
                freerdp_input_send_unicode_keyboard_event(input, f, e.code);
                break;
            }
            case EV_SYNC:
                freerdp_input_send_synchronize_event(input, e.sync);
                break;
        }
    }
}

static void *session_thread(void *arg)
{
    zbezel_rdp_session *s = (zbezel_rdp_session *)arg;
    rdpContext *context = s->context;

    BOOL ok = freerdp_connect(context->instance);
    if (!ok)
    {
        UINT32 code = freerdp_get_last_error(context);
        const char *name = code ? freerdp_get_last_error_name(code) : NULL;
        pthread_mutex_lock(&s->lock);
        /* Only the certificate can be blamed for a certificate problem.
         *
         * This used to say HOST_KEY_MISMATCH whenever a fingerprint was
         * pinned and had not matched — but a connection that never reached
         * TLS never calls the verify callback, so `fingerprint_matched` is
         * still 0 and an unreachable machine was reported as a changed host
         * key. That sends you to check a pin that is fine while the box is
         * simply switched off, asleep, or off the tailnet. `cert_checked`
         * says whether a certificate was ever actually presented. */
        if (s->cert_checked && s->expected_fingerprint && s->expected_fingerprint[0]
            && !s->fingerprint_matched)
            snprintf(s->error_name, sizeof s->error_name, "HOST_KEY_MISMATCH");
        else
            snprintf(s->error_name, sizeof s->error_name, "%s", name ? name : "CONNECT_FAILED");
        s->connect_result = -1;
        pthread_cond_signal(&s->started_cv);
        pthread_mutex_unlock(&s->lock);
        return NULL;
    }

    pthread_mutex_lock(&s->lock);
    s->connect_result = 1;
    s->running = 1;
    pthread_cond_signal(&s->started_cv);
    pthread_mutex_unlock(&s->lock);

    while (s->running && !freerdp_shall_disconnect_context(context))
    {
        drain_input(s);

        if (s->want_refresh)
        {
            s->want_refresh = 0;
            rdpGdi *gdi = context->gdi;
            if (gdi) gdi_send_suppress_output(gdi, FALSE);
        }

        HANDLE handles[64];
        DWORD n = freerdp_get_event_handles(context, handles, 64);
        if (n == 0) break;

        DWORD st = WaitForMultipleObjects(n, handles, FALSE, 8);   // 8ms: input stays snappy
        if (st == WAIT_FAILED) break;

        if (!freerdp_check_event_handles(context)) break;
    }

    if (s->state_cb) s->state_cb(s->cb_ctx, 2, NULL);

    freerdp_disconnect(context->instance);
    gdi_free(context->instance);
    return NULL;
}

// ---- public ---------------------------------------------------------------

zbezel_rdp_session *zbezel_rdp_open(const char *host, uint16_t port,
                                    const char *username, const char *domain,
                                    const char *password,
                                    const char *expected_fingerprint,
                                    int width, int height,
                                    zbezel_rdp_frame_cb frame_cb,
                                    zbezel_rdp_state_cb state_cb,
                                    void *cb_ctx,
                                    char *error_name, int error_name_len,
                                    char *fingerprint_out, int fingerprint_out_len)
{
    if (error_name && error_name_len > 0) error_name[0] = '\0';
    if (fingerprint_out && fingerprint_out_len > 0) fingerprint_out[0] = '\0';
    if (!host || !username) return NULL;

    zbezel_rdp_session *s = (zbezel_rdp_session *)calloc(1, sizeof *s);
    if (!s) return NULL;
    s->frame_cb = frame_cb;
    s->state_cb = state_cb;
    s->cb_ctx = cb_ctx;
    s->expected_fingerprint = (expected_fingerprint && expected_fingerprint[0]) ? strdup(expected_fingerprint) : NULL;
    s->fingerprint_out = fingerprint_out;
    s->fingerprint_out_len = fingerprint_out_len;
    s->want_width = width > 0 ? width : 1920;
    s->want_height = height > 0 ? height : 1080;
    pthread_mutex_init(&s->lock, NULL);
    pthread_cond_init(&s->started_cv, NULL);

    RDP_CLIENT_ENTRY_POINTS ep;
    memset(&ep, 0, sizeof ep);
    ep.Version      = RDP_CLIENT_INTERFACE_VERSION;
    ep.Size         = sizeof ep;
    ep.ContextSize  = sizeof(zbSessionContext);
    ep.ClientNew    = zb_client_new;
    ep.ClientFree   = zb_client_free;
    ep.ClientStart  = zb_client_start;
    ep.ClientStop   = zb_client_stop;

    rdpContext *context = freerdp_client_context_new(&ep);
    if (!context)
    {
        if (error_name && error_name_len > 0) snprintf(error_name, (size_t)error_name_len, "CONTEXT_NEW_FAILED");
        goto fail_early;
    }
    ((zbSessionContext *)context)->owner = s;
    s->context = context;
    s->instance = context->instance;

    rdpSettings *set = context->settings;
    freerdp_settings_set_string(set, FreeRDP_ServerHostname, host);
    freerdp_settings_set_uint32(set, FreeRDP_ServerPort, port ? port : 3389);
    freerdp_settings_set_string(set, FreeRDP_Username, username);
    if (domain && domain[0]) freerdp_settings_set_string(set, FreeRDP_Domain, domain);
    if (password) freerdp_settings_set_string(set, FreeRDP_Password, password);

    freerdp_settings_set_bool(set, FreeRDP_NlaSecurity, TRUE);
    freerdp_settings_set_bool(set, FreeRDP_AutoLogonEnabled, TRUE);

    // Pixels ON. Software GDI gives us a framebuffer; 32bpp so the surface is
    // BGRA and maps straight to a CoreGraphics image with no conversion.
    freerdp_settings_set_bool(set, FreeRDP_SoftwareGdi, TRUE);
    freerdp_settings_set_uint32(set, FreeRDP_ColorDepth, 32);
    freerdp_settings_set_uint32(set, FreeRDP_DesktopWidth, (UINT32)s->want_width);
    freerdp_settings_set_uint32(set, FreeRDP_DesktopHeight, (UINT32)s->want_height);

    // The remote's compression, which is the point of this path. The Graphics
    // Pipeline carries H.264 (AVC420/AVC444) — the efficient desktop codec —
    // decoded by openh264, which FreeRDP dlopens at runtime; RemoteFX and
    // NSCodec stay on beneath it as the fallback the server drops to if the
    // pipeline or the H.264 decoder is not there. AVC444 sends luma and chroma
    // in full where the newer server offers it; AVC420 is the floor.
    freerdp_settings_set_bool(set, FreeRDP_SupportGraphicsPipeline, TRUE);
    freerdp_settings_set_bool(set, FreeRDP_GfxH264, TRUE);
    freerdp_settings_set_bool(set, FreeRDP_GfxAVC444, TRUE);
    freerdp_settings_set_bool(set, FreeRDP_GfxAVC444v2, TRUE);
    freerdp_settings_set_bool(set, FreeRDP_GfxSmallCache, TRUE);
    freerdp_settings_set_bool(set, FreeRDP_RemoteFxCodec, TRUE);
    freerdp_settings_set_bool(set, FreeRDP_NSCodec, TRUE);
    freerdp_settings_set_bool(set, FreeRDP_FastPathOutput, TRUE);
    freerdp_settings_set_bool(set, FreeRDP_FrameMarkerCommandEnabled, TRUE);

    // No redirection: this is a viewer, not a full remote desktop.
    freerdp_settings_set_bool(set, FreeRDP_AudioPlayback, FALSE);
    freerdp_settings_set_bool(set, FreeRDP_AudioCapture, FALSE);
    freerdp_settings_set_bool(set, FreeRDP_RedirectClipboard, FALSE);
    freerdp_settings_set_bool(set, FreeRDP_DeviceRedirection, FALSE);
    freerdp_settings_set_bool(set, FreeRDP_RedirectDrives, FALSE);
    freerdp_settings_set_bool(set, FreeRDP_RedirectPrinters, FALSE);
    freerdp_settings_set_bool(set, FreeRDP_RedirectSmartCards, FALSE);

    if (s->state_cb) s->state_cb(s->cb_ctx, 0, NULL);

    if (pthread_create(&s->thread, NULL, session_thread, s) != 0)
    {
        if (error_name && error_name_len > 0) snprintf(error_name, (size_t)error_name_len, "THREAD_START_FAILED");
        goto fail_context;
    }

    pthread_mutex_lock(&s->lock);
    while (s->connect_result == 0) pthread_cond_wait(&s->started_cv, &s->lock);
    int result = s->connect_result;
    if (result < 0 && error_name && error_name_len > 0)
        snprintf(error_name, (size_t)error_name_len, "%s", s->error_name);
    pthread_mutex_unlock(&s->lock);

    if (result == 1) return s;

    pthread_join(s->thread, NULL);
    freerdp_client_context_free(context);
    s->context = NULL;
    goto fail_free;

fail_context:
    freerdp_client_context_free(context);
    s->context = NULL;
fail_free:
    if (s->expected_fingerprint) free(s->expected_fingerprint);
    pthread_mutex_destroy(&s->lock);
    pthread_cond_destroy(&s->started_cv);
    free(s);
    return NULL;
fail_early:
    if (s->expected_fingerprint) free(s->expected_fingerprint);
    pthread_mutex_destroy(&s->lock);
    pthread_cond_destroy(&s->started_cv);
    free(s);
    return NULL;
}

int zbezel_rdp_width(zbezel_rdp_session *s)
{
    if (!s || !s->context) return 0;
    return (int)freerdp_settings_get_uint32(s->context->settings, FreeRDP_DesktopWidth);
}

int zbezel_rdp_height(zbezel_rdp_session *s)
{
    if (!s || !s->context) return 0;
    return (int)freerdp_settings_get_uint32(s->context->settings, FreeRDP_DesktopHeight);
}

void zbezel_rdp_mouse(zbezel_rdp_session *s, int x, int y, uint16_t flags)
{
    if (!s) return;
    in_ev e; memset(&e, 0, sizeof e);
    e.type = EV_MOUSE; e.flags = flags; e.x = x; e.y = y;
    enqueue(s, &e);
}

void zbezel_rdp_wheel(zbezel_rdp_session *s, int notches)
{
    if (!s) return;
    in_ev e; memset(&e, 0, sizeof e);
    e.type = EV_WHEEL; e.notches = notches;
    enqueue(s, &e);
}

void zbezel_rdp_key(zbezel_rdp_session *s, uint8_t scancode, int extended, int down)
{
    if (!s) return;
    in_ev e; memset(&e, 0, sizeof e);
    e.type = EV_KEY; e.scancode = scancode; e.extended = extended; e.down = down;
    enqueue(s, &e);
}

void zbezel_rdp_unicode(zbezel_rdp_session *s, uint16_t code, int down)
{
    if (!s) return;
    in_ev e; memset(&e, 0, sizeof e);
    e.type = EV_UNICODE; e.code = code; e.down = down;
    enqueue(s, &e);
}

void zbezel_rdp_sync(zbezel_rdp_session *s, uint32_t toggle_flags)
{
    if (!s) return;
    in_ev e; memset(&e, 0, sizeof e);
    e.type = EV_SYNC; e.sync = toggle_flags;
    enqueue(s, &e);
}

void zbezel_rdp_refresh(zbezel_rdp_session *s)
{
    if (s) s->want_refresh = 1;
}

void zbezel_rdp_close(zbezel_rdp_session *s)
{
    if (!s) return;
    s->running = 0;
    if (s->context)
    {
        freerdp_abort_connect_context(s->context);   // break the wait promptly
        pthread_join(s->thread, NULL);
        freerdp_client_context_free(s->context);
        s->context = NULL;
    }
    if (s->expected_fingerprint) free(s->expected_fingerprint);
    pthread_mutex_destroy(&s->lock);
    pthread_cond_destroy(&s->started_cv);
    free(s);
}
