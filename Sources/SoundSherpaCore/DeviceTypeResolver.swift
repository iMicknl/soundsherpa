import Foundation

/// The kind of paired device, used to pick an icon in the menu.
///
/// This is the transport/UI-agnostic identity; mapping to an SF Symbol name happens in
/// the AppKit layer so this module stays free of UI dependencies.
public enum PairedDeviceType: String, Equatable, Sendable {
    case iPhone
    case iPad
    case macBook
    case mac
    case appleWatch
    case appleTV
    case airPods
    case appleGeneric
    case windows
    case android
    case unknown
}

/// Pure logic that guesses a paired device's type from its advertised name and MAC
/// address. Extracted from AppDelegate so it can be unit-tested without Bluetooth.
///
/// Resolution order:
///   1. Specific name patterns (Apple product names, then non-Apple vendor names).
///   2. OUI vendor lookup from the MAC address.
///
/// The non-Apple name patterns are checked before the OUI fallback so that a device
/// clearly named for another vendor is never mislabeled as Apple just because its MAC
/// happens to fall in an Apple-registered range.
public enum DeviceTypeResolver {

    public static func resolve(name: String, address: String) -> PairedDeviceType {
        let lowercaseName = name.lowercased()

        // 1a. Specific Apple product names.
        if lowercaseName.contains("iphone") {
            return .iPhone
        } else if lowercaseName.contains("ipad") {
            return .iPad
        } else if lowercaseName.contains("macbook") {
            return .macBook
        } else if lowercaseName.contains("imac") || lowercaseName.contains("mac mini")
                    || lowercaseName.contains("mac pro") || lowercaseName.contains("mac studio") {
            return .mac
        } else if lowercaseName.contains("apple watch") || lowercaseName.contains("watch") {
            return .appleWatch
        } else if lowercaseName.contains("apple tv") || lowercaseName.contains("appletv") {
            return .appleTV
        } else if lowercaseName.contains("airpods") {
            return .airPods
        } else if lowercaseName.contains("mac") && !lowercaseName.contains("macbook") {
            // Generic "Mac" in name but not MacBook.
            return .mac
        }

        // 1b. Non-Apple vendor names. Checked before the OUI fallback so a device named
        // for another vendor is not shown as Apple due to an Apple-range MAC.
        if lowercaseName.contains("microsoft") || lowercaseName.contains("windows")
            || lowercaseName.contains("surface") {
            return .windows
        } else if lowercaseName.contains("android") {
            return .android
        }

        // 2. OUI vendor lookup.
        let ouiType = deviceTypeFromMACAddress(address)
        if ouiType == .appleGeneric {
            // Apple device but unknown specific type; try a light name heuristic.
            if lowercaseName.contains("'s") {
                if lowercaseName.contains("pro") || lowercaseName.contains("air") {
                    return .macBook
                }
            }
            return .appleGeneric
        }

        return ouiType
    }

    // MARK: - OUI lookup

    private static func deviceTypeFromMACAddress(_ address: String) -> PairedDeviceType {
        let cleanAddress = address.uppercased().replacingOccurrences(of: "-", with: ":")

        let components = cleanAddress.split(separator: ":")
        guard components.count >= 3 else {
            // Try to parse an address with no separators.
            let noSeparators = cleanAddress.replacingOccurrences(of: ":", with: "")
            if noSeparators.count >= 6 {
                let index1 = noSeparators.index(noSeparators.startIndex, offsetBy: 2)
                let index2 = noSeparators.index(noSeparators.startIndex, offsetBy: 4)
                let index3 = noSeparators.index(noSeparators.startIndex, offsetBy: 6)
                let oui = "\(noSeparators[..<index1]):\(noSeparators[index1..<index2]):\(noSeparators[index2..<index3])"
                return checkOUI(oui)
            }
            return .unknown
        }

        let oui = "\(components[0]):\(components[1]):\(components[2])"
        return checkOUI(oui)
    }

    private static func checkOUI(_ oui: String) -> PairedDeviceType {
        if OUIPrefixes.apple.contains(oui) {
            return .appleGeneric
        }
        if OUIPrefixes.microsoft.contains(oui) {
            return .windows
        }
        return .unknown
    }
}
