#pragma once
#include <flutter_linux/flutter_linux.h>
#include "frame_store.h"

struct WebviewCefTexture {
  FlPixelBufferTexture parent_instance;
  signagex::FrameStore* frames;
};
struct WebviewCefTextureClass { FlPixelBufferTextureClass parent_class; };

G_DEFINE_TYPE(WebviewCefTexture, webview_cef_texture, fl_pixel_buffer_texture_get_type())
#define WEBVIEW_CEF_TEXTURE(obj) \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), webview_cef_texture_get_type(), WebviewCefTexture))

static gboolean webview_cef_texture_copy_pixels(FlPixelBufferTexture* texture,
    const uint8_t** pixels, uint32_t* width, uint32_t* height, GError**) {
  return WEBVIEW_CEF_TEXTURE(texture)->frames->Snapshot(pixels, width, height);
}
static void webview_cef_texture_finalize(GObject* object) {
  delete WEBVIEW_CEF_TEXTURE(object)->frames;
  G_OBJECT_CLASS(webview_cef_texture_parent_class)->finalize(object);
}
static void webview_cef_texture_class_init(WebviewCefTextureClass* klass) {
  FL_PIXEL_BUFFER_TEXTURE_CLASS(klass)->copy_pixels = webview_cef_texture_copy_pixels;
  G_OBJECT_CLASS(klass)->finalize = webview_cef_texture_finalize;
}
static void webview_cef_texture_init(WebviewCefTexture* self) {
  self->frames = new signagex::FrameStore();
}
static WebviewCefTexture* webview_cef_texture_new() {
  return WEBVIEW_CEF_TEXTURE(g_object_new(webview_cef_texture_get_type(), nullptr));
}
