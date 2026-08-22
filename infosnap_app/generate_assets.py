import os
import math
from PIL import Image, ImageDraw, ImageFont


def draw_round_rect(draw, xy, radius, fill):
    x0, y0, x1, y1 = xy
    draw.rectangle([x0+radius, y0, x1-radius, y1], fill=fill)
    draw.rectangle([x0, y0+radius, x1, y1-radius], fill=fill)
    draw.pieslice([x0, y0, x0+radius*2, y0+radius*2], 180, 270, fill=fill)
    draw.pieslice([x1-radius*2, y0, x1, y0+radius*2], 270, 360, fill=fill)
    draw.pieslice([x0, y1-radius*2, x0+radius*2, y1], 90, 180, fill=fill)
    draw.pieslice([x1-radius*2, y1-radius*2, x1, y1], 0, 90, fill=fill)

def get_font(size, bold=True):
    """Get a font - preferring bold sans-serif fonts for visibility"""
    if bold:
        fonts = [
            "C:\\Windows\\Fonts\\arialbd.ttf",  # Arial Bold
            "C:\\Windows\\Fonts\\calibrib.ttf",  # Calibri Bold
            "C:\\Windows\\Fonts\\seguisb.ttf",  # Segoe UI Semibold
            "C:\\Windows\\Fonts\\arial.ttf"
        ]
    else:
        fonts = [
            "C:\\Windows\\Fonts\\arial.ttf",
            "C:\\Windows\\Fonts\\calibri.ttf",
            "C:\\Windows\\Fonts\\segoeui.ttf"
        ]
    for f in fonts:
        if os.path.exists(f):
            return ImageFont.truetype(f, size)
    return ImageFont.load_default()

def draw_hexagon_grid_spaced(draw, width, height, hex_radius, color, line_width):
    """
    Draw hexagon grid with SPACING between hexagons (not touching).
    Matches the splash screen / welcome-email-2.html style.
    From email: stroke="#f59e0b" stroke-opacity="0.2" (20%)
    """
    # Spacing multiplier - hexagons are widely spaced, not touching
    horizontal_spacing = hex_radius * 3.5  # Large gap between columns
    vertical_spacing = hex_radius * 3.0    # Large gap between rows
    
    for row in range(-2, int(height / vertical_spacing) + 3):
        for col in range(-2, int(width / horizontal_spacing) + 3):
            # Offset every other row for honeycomb pattern
            x = col * horizontal_spacing + (horizontal_spacing * 0.5 if row % 2 else 0)
            y = row * vertical_spacing
            pts = []
            for i in range(6):
                angle = math.radians(i * 60 + 30)  # 30 degree offset for flat-top hexagons
                pts.append((x + hex_radius * math.cos(angle), y + hex_radius * math.sin(angle)))
            draw.polygon(pts, outline=color, width=line_width)


def draw_infosnap_logo_at(img, center_x, center_y, logo_size):
    """Draw the infoSnap logo (two overlapping green rounded squares) at specific position"""
    draw = ImageDraw.Draw(img)
    logo_x = center_x - logo_size // 2
    logo_y = center_y - logo_size // 2
    corner_radius = int(logo_size * 0.2)

    # Back square (solid green)
    back_size = int(logo_size * 0.7)
    back_box = (logo_x, logo_y, logo_x + back_size, logo_y + back_size)
    draw_round_rect(draw, back_box, corner_radius, (34, 197, 94, 255))

    # Front square (semi-transparent green, offset)
    offset = int(logo_size * 0.3)
    front_box = (
        logo_x + offset,
        logo_y + offset,
        logo_x + offset + back_size,
        logo_y + offset + back_size,
    )
    draw_round_rect(draw, front_box, corner_radius, (34, 197, 94, 200))


def main():
    W, H = 4096, 4096
    bg_color = (24, 24, 27)  # Dark background #18181b

    # ============ ADAPTIVE ICON BACKGROUND ============
    # Amber hexagons on dark background - matching email: #f59e0b at 20% opacity
    # 20% of 255 = 51
    img_bg = Image.new("RGBA", (W, H), bg_color)
    draw_bg = ImageDraw.Draw(img_bg)
    draw_hexagon_grid_spaced(
        draw_bg,
        W,
        H,
        hex_radius=200,                    # Smaller hexagons
        color=(245, 158, 11, 51),          # Amber #f59e0b at 20% opacity
        line_width=8,                      # Thin lines like email
    )
    img_bg.resize((1024, 1024), Image.Resampling.LANCZOS).convert("RGB").save("assets/icon_background.png")
    
    # ============ ADAPTIVE ICON FOREGROUND ============
    # Layout: Logo on LEFT, "info" and "Snap" stacked on RIGHT
    # Text should be BIG - covering good portion of icon
    img_fg = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    draw_fg = ImageDraw.Draw(img_fg)

    # Use larger font for better visibility
    text_font = get_font(1000, bold=True)
    
    # Measure text
    w_info = draw_fg.textlength("info", font=text_font)
    w_snap = draw_fg.textlength("Snap", font=text_font)
    text_width = max(w_info, w_snap)
    line_height = 970  # Height per line including spacing
    text_block_height = line_height * 2
    
    # Logo size proportional to text
    logo_size = 1150
    
    # Calculate total width: logo + gap + text
    gap = 160
    total_width = logo_size + gap + text_width
    
    # Center everything
    start_x = (W - total_width) // 2
    center_y = H // 2
    
    # Draw logo on LEFT, vertically centered
    logo_center_x = start_x + logo_size // 2
    logo_center_y = center_y
    draw_infosnap_logo_at(img_fg, logo_center_x, logo_center_y, logo_size)
    
    # Text block starts after logo + gap
    text_x = start_x + logo_size + gap
    
    # "info" in WHITE - top line
    info_y = center_y - line_height + 80
    draw_fg.text((text_x, info_y), "info", font=text_font, fill=(255, 255, 255, 255))
    
    # "Snap" in PASTEL GREEN (0xFF86EFAC) - bottom line
    snap_y = info_y + line_height
    draw_fg.text((text_x, snap_y), "Snap", font=text_font, fill=(134, 239, 172, 255))

    img_fg.resize((1024, 1024), Image.Resampling.LANCZOS).save("assets/icon_foreground.png")

    # ============ FULL ICON (iOS/legacy) ============
    img_icon = img_bg.copy()
    img_icon = Image.alpha_composite(img_icon, img_fg)
    img_icon.resize((1024, 1024), Image.Resampling.LANCZOS).convert("RGB").save("assets/icon.png")

    # ============ PREVIEW (for verification) ============
    # Create a square preview with rounded corners (like actual app icons)
    icon_full = img_bg.copy()
    icon_full = Image.alpha_composite(icon_full, img_fg)
    icon_full = icon_full.resize((1024, 1024), Image.Resampling.LANCZOS)
    
    # Create rounded rectangle mask for square icon preview
    mask = Image.new("L", (1024, 1024), 0)
    mask_draw = ImageDraw.Draw(mask)
    corner_radius = 180  # Rounded corners like Android icons
    # Draw rounded rectangle
    mask_draw.rounded_rectangle([0, 0, 1024, 1024], radius=corner_radius, fill=255)
    
    preview = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
    preview.paste(icon_full, (0, 0), mask)
    preview.save("assets/icon_preview.png")

    # ============ NATIVE SPLASH LOGO ============
    img_splash_logo = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    draw_infosnap_logo_at(img_splash_logo, W // 2, H // 2, 1200)
    img_splash_logo.resize((1024, 1024), Image.Resampling.LANCZOS).save("assets/native_splash_logo.png")
    
    print("Generated assets:")
    print("  - assets/icon_background.png (amber hexagons - spaced apart, 20% opacity)")
    print("  - assets/icon_foreground.png (logo LEFT + stacked info/Snap)")
    print("  - assets/icon.png (full icon)")
    print("  - assets/icon_preview.png (square preview with rounded corners)")
    print("  - assets/native_splash_logo.png")

if __name__ == "__main__":
    main()
