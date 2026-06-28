import SoundSherpaCore

extension PairedDeviceType {
    var iconName: String {
        switch self {
        case .iPhone: return "iphone"
        case .iPad: return "ipad"
        case .macBook: return "laptopcomputer"
        case .mac: return "desktopcomputer"
        case .appleWatch: return "applewatch"
        case .appleTV: return "appletv"
        case .airPods: return "airpods"
        case .appleGeneric: return "apple.logo"
        case .windows: return "pc"
        case .android: return "smartphone"
        case .unknown: return "display"
        }
    }
}
