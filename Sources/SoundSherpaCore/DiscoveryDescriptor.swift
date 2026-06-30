import Foundation

/// How to find and open a brand's control channel. Pure data supplied by each plugin, so the
/// controller's IOBluetooth connect flow has no hardcoded brand specifics. An entry is either
/// a service NAME (matched against IOBluetoothSDPServiceRecord.getServiceName()) or a UUID
/// string ("0x1101" 16-bit, or a 128-bit vendor UUID like Sony's
/// "96CC203E-5068-46AD-B32D-E316F5E069BA").
public enum ServiceMatcher: Sendable, Equatable {
    case serviceName(String)
    case uuid(String)
}

public struct DiscoveryDescriptor: Sendable {
    /// Service identifiers to look for, in priority order.
    public var serviceMatchers: [ServiceMatcher]
    /// RFCOMM channel IDs to brute-force if SDP channel lookup fails, in order.
    public var channelHints: [UInt8]
    public init(serviceMatchers: [ServiceMatcher], channelHints: [UInt8]) {
        self.serviceMatchers = serviceMatchers
        self.channelHints = channelHints
    }
}
