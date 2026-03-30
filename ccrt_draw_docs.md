# ccrt_draw.lua — Documentation

A drawing library for CC:Tweaked Advanced Monitors. Renders a framebuffer to
a monitor with automatic scaling, 16-colour palette quantisation, and
CC's 2×3 sub-pixel character encoding.

---

## Setup

Copy `ccrt_draw.lua` to your computer, then:

```lua
local gfx = require("ccrt_draw")
```

Your monitor must be an **Advanced monitor**. Set text scale before
drawing — `0.5` gives the most sub-pixels:

```lua
local mon = peripheral.find("monitor")
mon.setTextScale(0.5)
```

---

## Framebuffer format

A framebuffer is a 2D array:

```lua
fb[y][x] = {r, g, b}   -- 1-indexed, values 0-255
```

All functions that accept a framebuffer expect this format.

---

## API Reference

---

### `gfx.make_fb(w, h [, r, g, b])`

Create a new framebuffer filled with a solid colour.

| Parameter | Type | Description |
|-----------|------|-------------|
| `w` | number | Width in pixels |
| `h` | number | Height in pixels |
| `r, g, b` | number | Fill colour, 0–255 each (default `0, 0, 0`) |

**Returns:** framebuffer

```lua
local fb = gfx.make_fb(164, 81)           -- black
local fb = gfx.make_fb(164, 81, 30, 30, 60)  -- dark blue
```

---

### `gfx.fb_size(fb)`

Get the dimensions of a framebuffer.

**Returns:** `width, height`

```lua
local w, h = gfx.fb_size(fb)
```

---

### `gfx.get_pixel(fb, x, y)`

Read a pixel from a framebuffer. Returns `0, 0, 0` if out of bounds.

**Returns:** `r, g, b`

```lua
local r, g, b = gfx.get_pixel(fb, 10, 5)
```

---

### `gfx.set_pixel(fb, x, y, r, g, b)`

Write a single pixel to a framebuffer. Out-of-bounds writes are silently ignored.

```lua
gfx.set_pixel(fb, 82, 40, 255, 0, 0)   -- red dot
```

---

### `gfx.fill(fb, x1, y1, x2, y2, r, g, b)`

Fill a rectangular region with a solid colour. Coordinates are 1-indexed and
inclusive. Automatically clamps to framebuffer bounds.

```lua
gfx.fill(fb, 1, 1, 164, 40, 0, 0, 128)   -- dark blue top band
```

---

### `gfx.blit_fb(src, dst [, src_x, src_y, dst_x, dst_y, w, h])`

Copy a region from one framebuffer into another. All position/size parameters
default to copying the entire source to the top-left of the destination.
Out-of-bounds areas are silently skipped.

| Parameter | Default |
|-----------|---------|
| `src_x, src_y` | `1, 1` |
| `dst_x, dst_y` | `1, 1` |
| `w, h` | full source size |

```lua
-- Stamp a 32x32 sprite onto a larger canvas at position (50, 20)
gfx.blit_fb(sprite_fb, canvas_fb, 1, 1, 50, 20, 32, 32)
```

---

### `gfx.build_palette(fb [, max_samples])`

Build a 16-colour palette from a framebuffer using median-cut quantisation.
Samples up to `max_samples` pixels (default 2000) to keep it fast.

**Returns:** array of 16 `{r, g, b}` tables

```lua
local palette = gfx.build_palette(fb)
```

Use this when you want to build the palette once and reuse it across multiple
draw calls (e.g. animating over a static background).

---

### `gfx.draw(fb, mon)`

Draw a full framebuffer to a monitor in one pass.

- Builds a 16-colour palette via median-cut
- Applies it to the monitor with `setPaletteColour`
- Scales the framebuffer to fit the monitor using nearest-neighbour if sizes differ
- Blits every character row, yielding once per row to avoid CC's "too long without yielding" error

```lua
gfx.draw(fb, mon)
```

This is the main entry point for most use cases.

---

### `gfx.draw_with_palette(fb, mon, palette)`

Like `gfx.draw`, but skips palette quantisation and uses a supplied palette.
Apply the palette to the monitor yourself if needed, or let this function do it.

Useful when:
- Drawing multiple frames of the same scene (build palette once, reuse)
- You have a fixed palette you want to enforce

```lua
local palette = gfx.build_palette(fb)
-- ... render several frames ...
for _, frame_fb in ipairs(frames) do
    gfx.draw_with_palette(frame_fb, mon, palette)
end
```

---

### `gfx.draw_region(fb, mon, x1, y1, x2, y2 [, palette])`

Redraw only the character cells that cover a sub-rectangle of the framebuffer.
Coordinates are in **framebuffer pixel space** (1-indexed). The library maps
them to the correct monitor character cells automatically.

- If `palette` is nil, builds one from the full framebuffer first.
- Useful for incremental updates — only redraws the dirty area.

```lua
-- Only redraw the bottom-right quadrant
local w, h = gfx.fb_size(fb)
gfx.draw_region(fb, mon, w//2, h//2, w, h)
```

---

### `gfx.clear(mon [, r, g, b])`

Fill the monitor with a solid colour without needing a framebuffer.
Redefines colour slot 16 (black) to the requested colour and clears the screen.

```lua
gfx.clear(mon)              -- black
gfx.clear(mon, 20, 10, 40)  -- very dark purple
```

---

## Scaling behaviour

When the framebuffer and monitor sub-pixel dimensions don't match, all draw
functions use **nearest-neighbour scaling**. Each monitor sub-pixel maps to
the closest framebuffer pixel via:

```
fb_x = floor(sub_pixel_x * (fb_w / display_w)) + 1
fb_y = floor(sub_pixel_y * (fb_h / display_h)) + 1
```

A 328×162 framebuffer on an 82-column × 27-row monitor (`PIXEL_W=164, PIXEL_H=81`)
scales exactly 2:1. A 200×100 framebuffer on the same monitor scales ~1.22:1.

---

## Sub-pixel encoding

CC:Tweaked uses characters 128–159 to encode a 2-wide × 3-tall pixel grid per
character cell. Pixel 6 (bottom-right) is always the background colour; the
other 5 pixels each contribute one bit. The library picks the best fg/bg pair
for each cell by finding the two most common colours and assigning each pixel
to whichever it's closest to in RGB space.

Algorithm credit: [pixelbox_lite by 9551-Dev](https://github.com/9551-Dev/pixelbox_lite) (MIT).

---

## Examples

### Gradient

```lua
local gfx = require("ccrt_draw")
local mon = peripheral.find("monitor")
mon.setTextScale(0.5)

local w, h = 164, 81
local fb   = gfx.make_fb(w, h)

for y = 1, h do
    for x = 1, w do
        gfx.set_pixel(fb, x, y,
            math.floor(x / w * 255),
            math.floor(y / h * 255),
            128)
    end
end

gfx.draw(fb, mon)
```

### Compositing two framebuffers

```lua
local background = gfx.make_fb(164, 81, 10, 10, 30)
local overlay    = gfx.make_fb(64, 64, 200, 50, 50)

-- Draw something into overlay...
gfx.fill(overlay, 10, 10, 54, 54, 255, 100, 100)

-- Stamp overlay onto background at position (50, 10)
gfx.blit_fb(overlay, background, 1, 1, 50, 10, 64, 64)

gfx.draw(background, mon)
```

### Incremental update

```lua
local palette = gfx.build_palette(fb)
gfx.draw_with_palette(fb, mon, palette)

-- Later: something changed in a small region
gfx.set_pixel(fb, 80, 40, 255, 255, 0)
gfx.draw_region(fb, mon, 78, 38, 82, 42, palette)
-- Only the affected character cells are redrawn
```
