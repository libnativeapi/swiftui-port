#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef void (*sui_event_callback)(void *context, int64_t id, int event);
void sui_prepare_application(void);
typedef struct {
  double width, height;
} sui_size;
typedef int (*sui_input_callback)(void *, int64_t, int, double, double, int,
                                  int);
void sui_surface_schedule(void *);
void sui_surface_trace_update(void *, int begin);
void sui_surface_trace_duration(void *surface, int stage, double milliseconds);
int sui_control_focused(void *control);
void sui_surface_flush(void *);
void sui_surface_input(void *, sui_input_callback);
void *sui_edit_create(void *, int64_t, int multiline, int secure);
void sui_edit_update(void *, void *, const char *, const char *, double, double,
                     double, double, const char *, double, double, uint32_t,
                     uint32_t, int, int);
int sui_edit_text(void *, char *, int);
void sui_edit_destroy(void *, void *);
void sui_control_clip(void *, double, double, double, double);
void sui_control_opacity(void *control, double opacity);
void sui_control_focus(void *);
void sui_edit_replace_text(void *, const char *);
void sui_surface_pointer(void *, int event, double x, double y, int value);

void *sui_surface_create(void *host, sui_event_callback callback, void *context,
                         uint64_t native_view);
void sui_surface_destroy(void *surface);
void sui_surface_begin(void *surface);
void sui_surface_shape(void *surface, double x, double y, double width,
                       double height, double radius, uint32_t fill,
                       uint32_t stroke, double stroke_width);
void sui_surface_text(void *surface, double x, double y, double width,
                      double height, const char *text, const char *family,
                      double size, double weight, double line_spacing,
                      uint32_t color);
void sui_surface_path(void *surface, const double *commands, int count,
                      uint32_t fill, uint32_t stroke, double width, int clip);
void sui_surface_translation(void *surface, double x, double y);
void sui_surface_transform(void *surface, double cx, double cy, double rotation,
                           double sx, double sy);
void sui_surface_gradient(void *surface, double x, double y, double width,
                          double height, double sx, double sy, double ex,
                          double ey, const uint32_t *colors, int count);
void sui_surface_image(void *surface, const char *file, double x, double y,
                       double width, double height);
void sui_surface_clip(void *surface, double x, double y, double width,
                      double height, double radius);
void sui_surface_restore(void *surface);
void sui_surface_scroll_begin(void *surface, int64_t id, int64_t revision,
                              double x, double y, double width, double height,
                              double content_x, double content_y);
void sui_surface_scroll_end(void *surface);
int64_t sui_surface_reused_pixels(void *surface);
typedef struct {
  double raster_ms, blit_ms;
  int paints;
} sui_paint_stats;
sui_paint_stats sui_surface_paint_stats(void *surface);
sui_paint_stats sui_surface_total_paint_stats(void *surface);
double sui_surface_publish_time(void *surface, int stage);
void sui_control_tab_visible(void *surface, void *control, int visible);
void sui_surface_end(void *surface);
void sui_control_frame(void *surface, void *control, double x, double y,
                       double width, double height);
// Group native controls under a scrolling content window. Coordinates remain
// relative to the surface; nested groups and clipping are handled by the
// bridge.
void sui_controls_begin(void *surface);
void sui_controls_push(void *surface, int64_t id, double x, double y,
                       double width, double height, double clip_x,
                       double clip_y, double clip_width, double clip_height);
void sui_controls_pop(void *surface);
void sui_surface_button(void *surface, void *button, int64_t id,
                        int custom_draw, uint64_t native_view);
void sui_surface_remove_button(void *surface, void *button);
void sui_button_update(void *surface, void *button, double radius,
                       const char *help, double x, double y, double width,
                       double height);
void sui_surface_focus_next(void *surface, void *current, int backward);
sui_size sui_measure_text(const char *text, const char *family, double size,
                          double weight);
// Sends BM_CLICK to one owned native control. Does not post global input.
void sui_button_activate(void *button);
#ifdef __cplusplus
}
#endif
