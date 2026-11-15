import Foundation
import IOKit
import IOKit.usb
import PocketXRCore

/// The Mac's USB devices, from IOKit's registry: vendor, product, interface classes and name, for Glasses.detect.
enum UsbDevices {
    static func list() -> [UsbDeviceInfo] {
        var out = [UsbDeviceInfo]()
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iter) == KERN_SUCCESS else {
            return out
        }
        defer { IOObjectRelease(iter) }
        while true {
            let dev = IOIteratorNext(iter)
            if dev == 0 { break }
            defer { IOObjectRelease(dev) }
            guard let vid = number(dev, "idVendor"), let pid = number(dev, "idProduct") else { continue }
            let name = string(dev, "USB Product Name") ?? string(dev, "kUSBProductString") ?? ""
            out.append(UsbDeviceInfo(vendor: vid, product: pid, interfaceClasses: interfaceClasses(dev), name: name))
        }
        return out
    }

    /// The bInterfaceClass of each interface under [dev].
    private static func interfaceClasses(_ dev: io_object_t) -> [Int] {
        var classes = [Int]()
        var children: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(dev, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &children) == KERN_SUCCESS else {
            return classes
        }
        defer { IOObjectRelease(children) }
        while true {
            let child = IOIteratorNext(children)
            if child == 0 { break }
            defer { IOObjectRelease(child) }
            if IOObjectConformsTo(child, "IOUSBHostInterface") != 0, let c = number(child, "bInterfaceClass") {
                classes.append(c)
            }
        }
        return classes
    }

    private static func number(_ obj: io_object_t, _ key: String) -> Int? {
        guard let v = IORegistryEntryCreateCFProperty(obj, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else {
            return nil
        }
        return (v as? NSNumber)?.intValue
    }

    private static func string(_ obj: io_object_t, _ key: String) -> String? {
        guard let v = IORegistryEntryCreateCFProperty(obj, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else {
            return nil
        }
        return v as? String
    }

    /// One line per USB device, for the log.
    static func describe(_ list: [UsbDeviceInfo]) -> String {
        list.map { String(format: "%04X:%04X \"%@\" classes %@", $0.vendor, $0.product, $0.name,
                          $0.interfaceClasses.map { String(format: "%02X", $0) }.joined(separator: ",")) }
            .joined(separator: "; ")
    }
}
