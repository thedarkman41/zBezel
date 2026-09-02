#ifndef ZBEZEL_RDP_SESSION_H
#define ZBEZEL_RDP_SESSION_H

#include <stdint.h>

/// A live RDP session with pixels — the "View/Control" path, as opposed to the
/// pixel-less `zbezel_rdp_touch` that only makes a session exist for reclaim.
///
/// This decodes the remote desktop into a framebuffer and hands changed
/// regions to a callback, and forwards mouse and keyboard back. It exists for
/// the one thing the screen-scrape stream cannot do: show and answer the
/// secure desktop — a UAC prompt or the sign-in screen — which Windows renders
/// into the RDP session but forbids a user process from capturing locally.
///
/// The remote's own compression does the work here (RemoteFX / NSCodec, both
/// built into FreeRDP), which is why this is the efficient path even though it
/// is the heavier one to wire up.
///
/// Threading: everything runs on one internal thread this owns. The frame and
/// state callbacks fire on THAT thread — marshal to your UI thread yourself.
/// The input functions are safe to call from any thread; they queue, and the
/// session thread drains and sends, so the transport is only ever touched by
/// its owner.

typedef struct zbezel_rdp_session zbezel_rdp_session;

/// A changed rectangle of the desktop. `bgra` points into the session's own
/// framebuffer (BGRA32, top-down, `stride` bytes per row) and is valid ONLY
/// for the duration of this call — copy what you need before returning. The
/// rectangle (x,y,w,h) is the sub-region that changed; the full surface is
/// `width` by `height`.
typedef void (*zbezel_rdp_frame_cb)(void *ctx,
                                    const uint8_t *bgra, int width, int height, int stride,
                                    int x, int y, int w, int h);

/// State changes worth showing. `state`: 0 connecting, 1 connected (frames
/// follow), 2 disconnected (the session ended), 3 error (see `detail`),
/// 4 resized (`detail` is "<w>x<h>"). Fires on the session thread.
typedef void (*zbezel_rdp_state_cb)(void *ctx, int state, const char *detail);

/// Connect. Blocks until the session is up or has failed. On success returns a
/// handle and the session thread is running; on failure returns NULL and fills
/// `error_name` (FreeRDP's symbolic connect error, HOST_KEY_MISMATCH, or a
/// LOGON_* verdict). `width`/`height` request the session desktop size; pass 0
/// for a sensible default. `fingerprint_out` records the host key on first
/// contact, the way `zbezel_rdp_touch` does.
zbezel_rdp_session *zbezel_rdp_open(const char *host, uint16_t port,
                                    const char *username, const char *domain,
                                    const char *password,
                                    const char *expected_fingerprint,
                                    int width, int height,
                                    zbezel_rdp_frame_cb frame_cb,
                                    zbezel_rdp_state_cb state_cb,
                                    void *cb_ctx,
                                    char *error_name, int error_name_len,
                                    char *fingerprint_out, int fingerprint_out_len);

int zbezel_rdp_width(zbezel_rdp_session *s);
int zbezel_rdp_height(zbezel_rdp_session *s);

/// Mouse, in remote desktop pixels. `flags` is a FreeRDP PTR_FLAGS_* value
/// (MOVE, DOWN|BUTTON1, BUTTON1, …). Queued; sent on the session thread.
void zbezel_rdp_mouse(zbezel_rdp_session *s, int x, int y, uint16_t flags);

/// Wheel notches: positive up, negative down.
void zbezel_rdp_wheel(zbezel_rdp_session *s, int notches);

/// A key by RDP (set-1) scancode. `extended` for the E0-prefixed keys
/// (arrows, right-hand modifiers, nav cluster). `down` false for release.
void zbezel_rdp_key(zbezel_rdp_session *s, uint8_t scancode, int extended, int down);

/// A character by Unicode code point, when a scancode is not to hand.
void zbezel_rdp_unicode(zbezel_rdp_session *s, uint16_t code, int down);

/// Lock-key state (caps/num/scroll), so the remote agrees with this Mac.
void zbezel_rdp_sync(zbezel_rdp_session *s, uint32_t toggle_flags);

/// Redraw everything (after the view was hidden, or on first show).
void zbezel_rdp_refresh(zbezel_rdp_session *s);

/// End it: stop the thread, disconnect, free. Safe to call once.
void zbezel_rdp_close(zbezel_rdp_session *s);

#endif
