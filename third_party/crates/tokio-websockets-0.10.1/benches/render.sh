#!/bin/bash

# Check if cairosvg is installed
if ! command -v cairosvg &> /dev/null; then
    echo "cairosvg is not installed. Please install it using 'pip install cairosvg'."
    exit 1
fi

# Loop through all SVG files in the input directory
for svg_file in *.svg; do
    if [ -f "$svg_file" ]; then
        # Get the base name of the SVG file (excluding extension)
        base_name=$(basename -- "$svg_file")
        base_name_no_extension="${base_name%.svg}"
        # Construct the output PNG file path
        png_file="$base_name_no_extension.png"
        # Convert SVG to PNG using cairosvg
        cairosvg "$svg_file" -o "$png_file"
        echo "Converted $svg_file to $png_file"
    fi
done

echo "Conversion complete!"
