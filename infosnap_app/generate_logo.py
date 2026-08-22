from PIL import Image, ImageDraw
import os

size = 1024
image = Image.new("RGBA", (size, size), (255, 255, 255, 0))
draw = ImageDraw.Draw(image)

def draw_rounded_rect(draw, xy, cornerradius, fill):
    x0, y0, x1, y1 = xy
    draw.rectangle([(x0, y0 + cornerradius), (x1, y1 - cornerradius)], fill=fill)
    draw.rectangle([(x0 + cornerradius, y0), (x1 - cornerradius, y1)], fill=fill)
    draw.pieslice([(x0, y0), (x0 + cornerradius * 2, y0 + cornerradius * 2)], 180, 270, fill=fill)
    draw.pieslice([(x1 - cornerradius * 2, y0), (x1, y0 + cornerradius * 2)], 270, 360, fill=fill)
    draw.pieslice([(x0, y1 - cornerradius * 2), (x0 + cornerradius * 2, y1)], 90, 180, fill=fill)
    draw.pieslice([(x1 - cornerradius * 2, y1 - cornerradius * 2), (x1, y1)], 0, 90, fill=fill)

base_scale = 1024 / 64
s0_coords = (4*base_scale, 4*base_scale, 44*base_scale, 44*base_scale)
s1_coords = (16*base_scale, 16*base_scale, 56*base_scale, 56*base_scale)
radius = 10 * base_scale

draw_rounded_rect(draw, s0_coords, radius, (21, 128, 61, 255))
layer2 = Image.new("RGBA", (size, size), (255, 255, 255, 0))
draw2 = ImageDraw.Draw(layer2)
draw_rounded_rect(draw2, s1_coords, radius, (34, 197, 94, 204))
image = Image.alpha_composite(image, layer2)

os.makedirs("C:/Users/ameet/Documents/NotesApp/infosnap_app/assets", exist_ok=True)
image.save("C:/Users/ameet/Documents/NotesApp/infosnap_app/assets/logo.png")
