# SoundSherpa

**Smart controls for non-Apple headphones**

A native macOS menu bar application that brings the Control Center experience to all headphones, not just Apple ones. Manage noise cancellation, battery, connections, and device switching from your menu bar. No more guessing. No more digging through menus.

## Features

### Bose QC35 Support
- **Battery Level**: Real-time battery percentage with color-coded status bar icon
- **Connection Status**: Shows when your Bose QC35 is connected/disconnected
- **Device Information**: Displays device name and connection state
- **Firmware Version**: Shows firmware version when available
- **Noise Cancellation Control**: Toggle between Off, Low, and High noise cancellation
- **Self Voice Control**: Adjust self-voice levels (Off, Low, Medium, High)
- **Audio Codec**: Shows current audio codec being used
- **Paired Devices**: View and manage all paired devices with connection status indicators
  - Device type icons (iPhone, iPad, Mac, etc.)
  - Connect/disconnect devices directly from the menu
  - Shows total paired and connected device counts

### Advanced Settings
- **Auto-Off Timer**: Configure automatic power-off (Never, 5min, 20min, 40min, 60min, 180min)
- **Language Settings**: Choose voice prompt language
- **Voice Prompts**: Enable/disable voice prompts
- **Button Action**: Configure what the action button does (Alexa or Noise Cancellation)

### Status Bar Indicators
- **Green/Default**: Battery > 50%
- **Orange**: Battery 20-50%
- **Red**: Battery < 20%

### Menu Options
- **Real-time Controls**: Adjust noise cancellation and self-voice without opening Bose apps
- **Device Management**: Connect/disconnect paired devices
- **Refresh**: Manually scan for Bose devices and update information
- **About SoundSherpa**: View app information and version

## Supported Information

SoundSherpa can extract and control the following from Bose QC35 headphones:

1. **Battery Level** (0-100%) - Real-time monitoring
2. **Connection Status** - Always available
3. **Device Name** - "Bose QC35" or similar
4. **Firmware Version** - When available via Bluetooth services
5. **Noise Cancellation** - Full control (Off/Low/High)
6. **Self Voice** - Full control (Off/Low/Medium/High)
7. **Audio Codec** - SBC/AAC detection
8. **Paired Devices** - Complete management with device type detection
9. **Advanced Settings** - Auto-off, language, voice prompts, button actions

## Technical Details

SoundSherpa uses:
- **Core Bluetooth** for device discovery and basic information
- **IOBluetooth** for advanced device management
- **RFCOMM Protocol** for direct communication with Bose devices
- **Native macOS UI** for seamless integration

## Requirements

- macOS 13.0 or later
- Swift 5.9 or later
- Bluetooth permissions

## Building

```bash
swift build
./build.sh  # Creates SoundSherpa.app bundle
```

## Running

```bash
swift run
# or
./run.sh    # Runs the development version
# or
open SoundSherpa.app  # Runs the built app bundle
```

The app will appear in your menu bar with a headphones icon that changes color based on battery level.

## Permissions

SoundSherpa requests Bluetooth permissions to scan for and connect to Bose headphones. Make sure to grant these permissions when prompted.

## Supported Devices

Currently optimized for:
- Bose QC35
- Bose QC35 II
- Other Bose headphones may work with limited functionality

## About

SoundSherpa brings the Control Center experience to all headphones, not just Apple ones. Manage noise cancellation, battery, connections, and device switching from your menu bar. No more guessing. No more digging through menus.

Version 1.0

---

*Technical reference: https://blog.davidv.dev/posts/reverse-engineering-the-bose-qc35-bluetooth-protocol/*