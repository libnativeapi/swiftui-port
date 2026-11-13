#pragma once
#ifdef __cplusplus
extern "C" {
#endif
typedef struct {
  int dpi, aware, pixel_errors, child_pixel_errors;
  int hover_events, position_changes, immediate_paints, clip_errors,
      atomic_errors;
  int damage_pixels, surface_pixels;
  int scope_errors;
  int group_errors;
  int expose_errors;
} drawing_probe_result;
drawing_probe_result drawing_probe(void);
typedef struct {
  int copies, pixel_errors, fallback_errors;
} scroll_probe_result;
scroll_probe_result scroll_probe(void);
#ifdef __cplusplus
}
#endif
