//
//  Utils.swift
//  Plugin
//
//  Created by Svend on 2024/1/26.
//  Copyright © 2024 Max Lynch. All rights reserved.
//

import Foundation

public class Utils {

    private struct IPv4Interface {
        let name: String
        let address: String
        let prefixLength: Int
        let isLoopback: Bool
    }

    private static func isExcludedInterface(_ name: String) -> Bool {
        name.hasPrefix("awdl") || name.hasPrefix("llw")
    }

    private static func interfacePriority(_ name: String) -> Int {
        if name.hasPrefix("en"), let index = Int(name.dropFirst(2)) {
            return index
        }
        if name.hasPrefix("utun"), let index = Int(name.dropFirst(4)) {
            return 50 + index
        }
        if name.hasPrefix("ppp"), let index = Int(name.dropFirst(3)) {
            return 50 + index
        }
        return 100
    }

    private static func hostname(from addr: UnsafePointer<sockaddr>, len: socklen_t) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(addr, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else {
            return nil
        }
        return String(cString: host)
    }

    private static func prefixLength(family: sa_family_t, netmask: UnsafePointer<sockaddr>?) -> Int {
        guard family == UInt8(AF_INET), let netmask = netmask else { return 0 }
        let mask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        let bytes = withUnsafeBytes(of: mask.s_addr.bigEndian) { Array($0) }
        var bits = 0
        for byte in bytes {
            if byte == 0xff {
                bits += 8
            } else if byte == 0 {
                break
            } else {
                var value = byte
                while value & 0x80 != 0 {
                    bits += 1
                    value <<= 1
                }
                break
            }
        }
        return bits
    }

    private static func listIPv4Interfaces() -> [IPv4Interface] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        var results: [IPv4Interface] = []
        for ifptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ifptr.pointee
            guard let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            guard let address = hostname(from: addr, len: socklen_t(addr.pointee.sa_len)) else { continue }

            let name = String(cString: interface.ifa_name)
            let isLoopback = (interface.ifa_flags & UInt32(IFF_LOOPBACK)) != 0
            let prefix = prefixLength(family: addr.pointee.sa_family, netmask: interface.ifa_netmask)
            results.append(IPv4Interface(name: name, address: address, prefixLength: prefix, isLoopback: isLoopback))
        }
        return results
    }

    private static func pickBestIPv4Interface(_ interfaces: [IPv4Interface]) -> IPv4Interface? {
        interfaces
            .filter { !$0.isLoopback && !isExcludedInterface($0.name) && $0.prefixLength > 0 }
            .sorted { left, right in
                if left.prefixLength != right.prefixLength {
                    return left.prefixLength > right.prefixLength
                }
                return interfacePriority(left.name) < interfacePriority(right.name)
            }
            .first
    }

    static func getPreferredInterfaceName() -> String? {
        pickBestIPv4Interface(listIPv4Interfaces())?.name
    }

    static func interfaceName(forIPv4 address: String) -> String? {
        listIPv4Interfaces().first { $0.address == address }?.name
    }

    static func getIPv4Address() -> String? {
        pickBestIPv4Interface(listIPv4Interfaces())?.address
    }

    static func getIPv6Address() -> String? {
        guard let preferredName = getPreferredInterfaceName() else { return nil }

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ifptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ifptr.pointee
            let name = String(cString: interface.ifa_name)
            guard name == preferredName else { continue }
            guard let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET6) else { continue }
            guard var host = hostname(from: addr, len: socklen_t(addr.pointee.sa_len)) else { continue }
            if let scopeIndex = host.firstIndex(of: "%") {
                host = String(host[..<scopeIndex])
            }
            return host
        }
        return nil
    }
}
