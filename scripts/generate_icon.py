#!/usr/bin/env python3
"""Generate app icon for CCCanopy by applying squircle mask to source image.

Usage:
  python generate_icon.py
"""

from pathlib import Path

from AppKit import (
    NSBezierPath,
    NSBitmapImageRep,
    NSColor,
    NSCompositingOperationSourceOver,
    NSGraphicsContext,
    NSImage,
    NSMakeRect,
    NSPNGFileType,
)
from Foundation import NSMakeSize, NSPoint


def create_squircle_path(x: float, y: float, width: float, height: float) -> NSBezierPath:
    """
    Create Apple's continuous curvature rounded rectangle (squircle).
    Based on PaintCode's reverse-engineering of iOS 7+ UIBezierPath.
    """
    path = NSBezierPath.bezierPath()

    LIMIT_FACTOR = 1.52866483
    TOP_RIGHT_P1 = 1.52866483
    TOP_RIGHT_P2 = 1.08849323
    TOP_RIGHT_P3 = 0.86840689
    TOP_RIGHT_P4 = 0.66993427
    TOP_RIGHT_P5 = 0.63149399
    TOP_RIGHT_P6 = 0.37282392
    TOP_RIGHT_P7 = 0.16906013

    TOP_RIGHT_CP1 = 0.06549600
    TOP_RIGHT_CP2 = 0.07491100
    TOP_RIGHT_CP3 = 0.16905899
    TOP_RIGHT_CP4 = 0.37282401

    corner_radius = min(width, height) * 0.22
    max_radius = min(width, height) / 2
    limited_radius = min(corner_radius, max_radius / LIMIT_FACTOR)
    r = limited_radius

    left = x
    right = x + width
    top = y + height
    bottom = y

    path.moveToPoint_(NSPoint(left + r * TOP_RIGHT_P1, top))
    path.lineToPoint_(NSPoint(right - r * TOP_RIGHT_P1, top))

    path.curveToPoint_controlPoint1_controlPoint2_(
        NSPoint(right - r * TOP_RIGHT_P4, top - r * TOP_RIGHT_CP1),
        NSPoint(right - r * TOP_RIGHT_P2, top),
        NSPoint(right - r * TOP_RIGHT_P3, top),
    )
    path.curveToPoint_controlPoint1_controlPoint2_(
        NSPoint(right - r * TOP_RIGHT_CP2, top - r * TOP_RIGHT_P5),
        NSPoint(right - r * TOP_RIGHT_P6, top - r * TOP_RIGHT_CP3),
        NSPoint(right - r * TOP_RIGHT_P7, top - r * TOP_RIGHT_CP4),
    )
    path.curveToPoint_controlPoint1_controlPoint2_(
        NSPoint(right, top - r * TOP_RIGHT_P1),
        NSPoint(right, top - r * TOP_RIGHT_P3),
        NSPoint(right, top - r * TOP_RIGHT_P2),
    )

    path.lineToPoint_(NSPoint(right, bottom + r * TOP_RIGHT_P1))

    path.curveToPoint_controlPoint1_controlPoint2_(
        NSPoint(right - r * TOP_RIGHT_CP1, bottom + r * TOP_RIGHT_P4),
        NSPoint(right, bottom + r * TOP_RIGHT_P2),
        NSPoint(right, bottom + r * TOP_RIGHT_P3),
    )
    path.curveToPoint_controlPoint1_controlPoint2_(
        NSPoint(right - r * TOP_RIGHT_P5, bottom + r * TOP_RIGHT_CP2),
        NSPoint(right - r * TOP_RIGHT_CP3, bottom + r * TOP_RIGHT_P6),
        NSPoint(right - r * TOP_RIGHT_CP4, bottom + r * TOP_RIGHT_P7),
    )
    path.curveToPoint_controlPoint1_controlPoint2_(
        NSPoint(right - r * TOP_RIGHT_P1, bottom),
        NSPoint(right - r * TOP_RIGHT_P3, bottom),
        NSPoint(right - r * TOP_RIGHT_P2, bottom),
    )

    path.lineToPoint_(NSPoint(left + r * TOP_RIGHT_P1, bottom))

    path.curveToPoint_controlPoint1_controlPoint2_(
        NSPoint(left + r * TOP_RIGHT_P4, bottom + r * TOP_RIGHT_CP1),
        NSPoint(left + r * TOP_RIGHT_P2, bottom),
        NSPoint(left + r * TOP_RIGHT_P3, bottom),
    )
    path.curveToPoint_controlPoint1_controlPoint2_(
        NSPoint(left + r * TOP_RIGHT_CP2, bottom + r * TOP_RIGHT_P5),
        NSPoint(left + r * TOP_RIGHT_P6, bottom + r * TOP_RIGHT_CP3),
        NSPoint(left + r * TOP_RIGHT_P7, bottom + r * TOP_RIGHT_CP4),
    )
    path.curveToPoint_controlPoint1_controlPoint2_(
        NSPoint(left, bottom + r * TOP_RIGHT_P1),
        NSPoint(left, bottom + r * TOP_RIGHT_P3),
        NSPoint(left, bottom + r * TOP_RIGHT_P2),
    )

    path.lineToPoint_(NSPoint(left, top - r * TOP_RIGHT_P1))

    path.curveToPoint_controlPoint1_controlPoint2_(
        NSPoint(left + r * TOP_RIGHT_CP1, top - r * TOP_RIGHT_P4),
        NSPoint(left, top - r * TOP_RIGHT_P2),
        NSPoint(left, top - r * TOP_RIGHT_P3),
    )
    path.curveToPoint_controlPoint1_controlPoint2_(
        NSPoint(left + r * TOP_RIGHT_P5, top - r * TOP_RIGHT_CP2),
        NSPoint(left + r * TOP_RIGHT_CP3, top - r * TOP_RIGHT_P6),
        NSPoint(left + r * TOP_RIGHT_CP4, top - r * TOP_RIGHT_P7),
    )
    path.curveToPoint_controlPoint1_controlPoint2_(
        NSPoint(left + r * TOP_RIGHT_P1, top),
        NSPoint(left + r * TOP_RIGHT_P3, top),
        NSPoint(left + r * TOP_RIGHT_P2, top),
    )

    path.closePath()
    return path


def load_source_image(source_path: Path) -> NSImage:
    """Load the source image file."""
    image = NSImage.alloc().initWithContentsOfFile_(str(source_path))
    if image is None:
        raise FileNotFoundError(f"Could not load image: {source_path}")
    return image


def create_icon(source_image: NSImage, size: int = 1024) -> NSImage:
    """Create the app icon by applying squircle mask to source image with bevel effect."""
    from AppKit import NSCalibratedRGBColorSpace

    bitmap = NSBitmapImageRep.alloc().initWithBitmapDataPlanes_pixelsWide_pixelsHigh_bitsPerSample_samplesPerPixel_hasAlpha_isPlanar_colorSpaceName_bytesPerRow_bitsPerPixel_(
        None, size, size, 8, 4, True, False, NSCalibratedRGBColorSpace, 0, 0,
    )
    bitmap.setSize_(NSMakeSize(size, size))

    ctx = NSGraphicsContext.graphicsContextWithBitmapImageRep_(bitmap)
    NSGraphicsContext.setCurrentContext_(ctx)
    ctx.setShouldAntialias_(True)

    # macOS standard: 832x832 icon within 1024x1024 canvas
    icon_size = size * 0.8125
    margin = (size - icon_size) / 2

    squircle_path = create_squircle_path(margin, margin, icon_size, icon_size)

    ctx.saveGraphicsState()
    squircle_path.addClip()

    # Draw source image zoomed in to make the symbol larger
    source_size = source_image.size()
    crop_ratio = 0.12
    crop_px = source_size.width * crop_ratio
    source_image.drawInRect_fromRect_operation_fraction_(
        NSMakeRect(margin, margin, icon_size, icon_size),
        NSMakeRect(crop_px, crop_px, source_size.width - crop_px * 2, source_size.height - crop_px * 2),
        NSCompositingOperationSourceOver,
        1.0,
    )

    ctx.restoreGraphicsState()

    # Bevel effect using offset strokes
    bevel_offset = size * 0.004
    stroke_width = size * 0.008

    ctx.saveGraphicsState()
    squircle_path.addClip()

    highlight_path = create_squircle_path(
        margin + bevel_offset, margin - bevel_offset, icon_size, icon_size,
    )
    highlight_path.setLineWidth_(stroke_width)
    NSColor.colorWithCalibratedRed_green_blue_alpha_(1.0, 1.0, 1.0, 0.5).setStroke()
    highlight_path.stroke()

    shadow_path = create_squircle_path(
        margin - bevel_offset, margin + bevel_offset, icon_size, icon_size,
    )
    shadow_path.setLineWidth_(stroke_width)
    NSColor.colorWithCalibratedRed_green_blue_alpha_(0.0, 0.0, 0.0, 0.25).setStroke()
    shadow_path.stroke()

    ctx.restoreGraphicsState()

    NSGraphicsContext.setCurrentContext_(None)

    image = NSImage.alloc().initWithSize_(NSMakeSize(size, size))
    image.addRepresentation_(bitmap)
    return image


def save_png(image: NSImage, path: Path, size: int, source_size: int = 1024):
    """Save NSImage as PNG at specified pixel size."""
    from AppKit import NSCalibratedRGBColorSpace

    bitmap = NSBitmapImageRep.alloc().initWithBitmapDataPlanes_pixelsWide_pixelsHigh_bitsPerSample_samplesPerPixel_hasAlpha_isPlanar_colorSpaceName_bytesPerRow_bitsPerPixel_(
        None, size, size, 8, 4, True, False, NSCalibratedRGBColorSpace, 0, 0,
    )
    bitmap.setSize_(NSMakeSize(size, size))

    ctx = NSGraphicsContext.graphicsContextWithBitmapImageRep_(bitmap)
    NSGraphicsContext.setCurrentContext_(ctx)
    ctx.setImageInterpolation_(3)

    image.drawInRect_fromRect_operation_fraction_(
        NSMakeRect(0, 0, size, size),
        NSMakeRect(0, 0, source_size, source_size),
        NSCompositingOperationSourceOver,
        1.0,
    )

    NSGraphicsContext.setCurrentContext_(None)

    png_data = bitmap.representationUsingType_properties_(NSPNGFileType, None)
    png_data.writeToFile_atomically_(str(path), True)
    print(f"  Created: {path.name} ({size}x{size})")


def main():
    project_root = Path(__file__).parent.parent
    source_path = project_root / "images" / "appiconbase.png"

    if not source_path.exists():
        print(f"Error: Source image not found: {source_path}")
        return 1

    output_dir = (
        project_root / "Sources" / "Canopy" / "Resources" / "Assets.xcassets" / "AppIcon.appiconset"
    )
    output_dir.mkdir(parents=True, exist_ok=True)

    print(f"Loading source image: {source_path}")
    source_image = load_source_image(source_path)

    print("Creating icon with squircle mask...")
    icon = create_icon(source_image, 1024)

    sizes = [16, 32, 64, 128, 256, 512, 1024]

    print("\nGenerating PNG icons...")
    for size in sizes:
        output_path = output_dir / f"appicon_{size}.png"
        save_png(icon, output_path, size)

    # Write Contents.json
    contents = {
        "images": [
            {"filename": f"appicon_{size}.png", "idiom": "mac", "size": f"{size}x{size}", "scale": "1x"}
            for size in sizes
        ],
        "info": {"author": "xcode", "version": 1},
    }
    import json
    contents_path = output_dir / "Contents.json"
    contents_path.write_text(json.dumps(contents, indent=2) + "\n")
    print(f"  Created: Contents.json")

    print("\nAll icons generated successfully!")


if __name__ == "__main__":
    main()
