#!/bin/bash

echo "Building Headphone Battery Monitor..."
swift build

if [ $? -eq 0 ]; then
    echo "Build successful!"
    echo "To run the app: swift run"
    echo "The app will appear in your menu bar with a headphone icon."
else
    echo "Build failed!"
    exit 1
fi