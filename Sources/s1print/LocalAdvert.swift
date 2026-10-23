import dnssd
import Foundation

/// The Bonjour advert for the print server, published by the app rather than by
/// `ippeveprinter`. ippeveprinter also advertises `_ipps` with `TLS=1.2`, but it
/// cannot set up TLS on current macOS (sandboxed or not), so print dialogs that
/// prefer `ipps` hang on «Preparing…» or fail to add the printer. This advert
/// offers plain `ipp` only, in the AirPrint subtypes «Add Printer» looks for.
final class LocalAdvert {
    private var ref: DNSServiceRef?

    /// - Parameter localOnly: visible on this Mac only, pointing at `localhost`
    ///   (the server listens on loopback); otherwise on every interface.
    func start(name: String, port: Int, localOnly: Bool, uuid: String) {
        stop()
        let txt: [(String, String)] = [
            ("txtvers", "1"), ("qtotal", "1"), ("rp", "ipp/print"),
            ("ty", "s1print Luck Jingle S1"), ("product", "(s1print Luck Jingle S1)"),
            ("note", "Bluetooth"), ("pdl", "image/pwg-raster,image/urf"),
            ("URF", "V1.4,W8,DM1,RS406,CP1,IS1,MT1-3-10-12"),
            ("Color", "F"), ("Duplex", "F"), ("UUID", uuid),
        ]
        var record = Data()
        for (key, value) in txt {
            let entry = Data("\(key)=\(value)".utf8)
            record.append(UInt8(entry.count))
            record.append(entry)
        }
        var newRef: DNSServiceRef?
        let interface: UInt32 = localOnly ? kDNSServiceInterfaceIndexLocalOnly : 0
        let err = record.withUnsafeBytes { bytes in
            DNSServiceRegister(&newRef, 0, interface, name, "_ipp._tcp,_universal,_print", nil,
                               localOnly ? "localhost." : nil, UInt16(port).bigEndian,
                               UInt16(bytes.count), bytes.baseAddress, nil, nil)
        }
        guard err == kDNSServiceErr_NoError, let newRef else { return }
        DNSServiceSetDispatchQueue(newRef, .main)
        ref = newRef
    }

    func stop() {
        if let ref { DNSServiceRefDeallocate(ref) }
        ref = nil
    }

    /// One stable UUID per installation, so CUPS keeps matching the printer.
    static var uuid: String {
        if let saved = UserDefaults.standard.string(forKey: "advertUUID") { return saved }
        let fresh = UUID().uuidString.lowercased()
        UserDefaults.standard.set(fresh, forKey: "advertUUID")
        return fresh
    }
}
