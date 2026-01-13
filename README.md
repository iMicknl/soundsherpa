# Headphone Battery Monitor

A native macOS menu bar application that monitors Bose QC35 headphone battery levels and device information via Bluetooth.

## Features

### Bose QC35 Support
- **Battery Level**: Real-time battery percentage with color-coded status bar icon
- **Connection Status**: Shows when your Bose QC35 is connected/disconnected
- **Device Information**: Displays device name and connection state
- **Firmware Version**: Shows firmware version when available
- **Noise Cancellation Status**: Indicates if noise cancellation is enabled (when detectable)
- **Audio Codec**: Shows current audio codec being used
- **Paired Devices**: View all paired devices with connection status indicators
  - `!` indicates the current device (your Mac)
  - `*` indicates other connected devices
  - Shows total paired and connected device counts

### Status Bar Indicators
- **Green/Default**: Battery > 50%
- **Orange**: Battery 20-50%
- **Red**: Battery < 20%

### Menu Options
- **Refresh**: Manually scan for Bose devices and update information
- **Real-time Updates**: Automatic updates when device connects/disconnects

## Supported Information

The app can extract the following information from Bose QC35 headphones:

1. **Battery Level** (0-100%) - Most reliable
2. **Connection Status** - Always available
3. **Device Name** - "Bose QC35" or similar
4. **Firmware Version** - When available via Bluetooth services
5. **Noise Cancellation** - Detected through manufacturer data (when available)
6. **Audio Codec** - SBC/AAC detection
7. **Paired Devices** - Shows all paired devices with connection indicators
   - Total paired device count
   - Number of connected devices
   - Device addresses with status (current/connected/paired)

## Technical Details

The app uses Core Bluetooth to:
- Scan for Bose devices by name matching
- Parse manufacturer data (Company ID: 0x009E for Bose)
- Connect to devices to read battery service (UUID: 180F)
- Read device information service (UUID: 180A) for firmware

## Requirements

- macOS 13.0 or later
- Swift 5.9 or later
- Bluetooth permissions

## Building

```bash
swift build
./build.sh  # Creates app bundle (if available)
```

## Running

```bash
swift run
# or
./run.sh    # Runs the built app (if available)
```

The app will appear in your menu bar with a headphones icon that changes color based on battery level.

## Permissions

The app requests Bluetooth permissions to scan for and connect to Bose headphones. Make sure to grant these permissions when prompted.

## Supported Devices

Currently optimized for:
- Bose QC35
- Bose QC35 II
- Other Bose headphones may work with limited functionality

https://blog.davidv.dev/posts/reverse-engineering-the-bose-qc35-bluetooth-protocol/