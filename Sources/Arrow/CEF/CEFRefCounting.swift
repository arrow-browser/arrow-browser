import CEF
import Synchronization

// CEF C API reference counting, implemented in Swift.
//
// Rules (see libcef_dll/cpptoc and ctocpp in the CEF distribution):
// - Struct arguments received by a callback (except `self`) carry a reference
//   that the callback must release.
// - Structs returned by CEF functions carry a reference the caller releases.
// - Structs passed to CEF functions transfer one reference to CEF.
// - Structs returned from callbacks must carry a reference for CEF.

/// Every ref-counted CEF struct starts with a `cef_base_ref_counted_t`.
@inline(__always)
func cefBase<T>(_ pointer: UnsafeMutablePointer<T>) -> UnsafeMutablePointer<cef_base_ref_counted_t> {
    UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: cef_base_ref_counted_t.self)
}

@inline(__always)
func cefAddRef<T>(_ pointer: UnsafeMutablePointer<T>?) {
    guard let pointer else { return }
    let base = cefBase(pointer)
    base.pointee.add_ref?(base)
}

@inline(__always)
func cefRelease<T>(_ pointer: UnsafeMutablePointer<T>?) {
    guard let pointer else { return }
    let base = cefBase(pointer)
    _ = base.pointee.release?(base)
}

/// Owning (+1) reference to an object implemented by CEF.
final class CefRef<T>: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<T>

    /// Takes ownership of a reference that was already added (callback
    /// argument or function return value).
    init?(adopting pointer: UnsafeMutablePointer<T>?) {
        guard let pointer else { return nil }
        self.pointer = pointer
    }

    /// Adds a new reference to `pointer`.
    init?(retaining pointer: UnsafeMutablePointer<T>?) {
        guard let pointer else { return nil }
        cefAddRef(pointer)
        self.pointer = pointer
    }

    deinit {
        cefRelease(pointer)
    }

    /// The pointer with an extra reference, for CEF functions that take
    /// ownership of their arguments.
    func retained() -> UnsafeMutablePointer<T> {
        cefAddRef(pointer)
        return pointer
    }

    var pointee: T { pointer.pointee }
}

// MARK: - Structs implemented in Swift

/// Trailer stored right after a Swift-implemented CEF struct.
private final class CefHandlerBox: @unchecked Sendable {
    let refCount = Atomic<Int>(1)
    weak let owner: AnyObject?

    init(owner: AnyObject) {
        self.owner = owner
    }
}

@inline(__always)
private func trailerOffset(structSize: Int) -> Int {
    (structSize + 15) & ~15
}

@inline(__always)
private func handlerBox(_ base: UnsafeMutablePointer<cef_base_ref_counted_t>?) -> CefHandlerBox? {
    guard let base else { return nil }
    let raw = UnsafeMutableRawPointer(base) + trailerOffset(structSize: base.pointee.size)
    let opaque = raw.load(as: UnsafeMutableRawPointer.self)
    return Unmanaged<CefHandlerBox>.fromOpaque(opaque).takeUnretainedValue()
}

private func freeHandler(_ base: UnsafeMutablePointer<cef_base_ref_counted_t>) {
    let raw = UnsafeMutableRawPointer(base)
    let opaque = (raw + trailerOffset(structSize: base.pointee.size)).load(as: UnsafeMutableRawPointer.self)
    Unmanaged<CefHandlerBox>.fromOpaque(opaque).release()
    raw.deallocate()
}

/// A CEF callback struct (client, handlers, tasks…) implemented in Swift.
///
/// The Swift object holds one reference for its lifetime; CEF holds the
/// others. Callbacks resolve their Swift owner through `owner(of:)`, which
/// returns nil once the owner is gone.
final class CefHandler<T>: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<T>

    init(owner: AnyObject, configure: (inout T) -> Void) {
        let size = MemoryLayout<T>.size
        let offset = trailerOffset(structSize: size)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: offset + MemoryLayout<UnsafeRawPointer>.size, alignment: 16)
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: offset)
        let box = CefHandlerBox(owner: owner)
        (raw + offset).storeBytes(of: Unmanaged.passRetained(box).toOpaque(), as: UnsafeMutableRawPointer.self)

        let base = raw.assumingMemoryBound(to: cef_base_ref_counted_t.self)
        base.pointee.size = size
        base.pointee.add_ref = { base in
            handlerBox(base)?.refCount.wrappingAdd(1, ordering: .relaxed)
        }
        base.pointee.release = { base in
            guard let base, let box = handlerBox(base) else { return 0 }
            if box.refCount.subtract(1, ordering: .acquiringAndReleasing).newValue == 0 {
                freeHandler(base)
                return 1
            }
            return 0
        }
        base.pointee.has_one_ref = { base in
            handlerBox(base)?.refCount.load(ordering: .acquiring) == 1 ? 1 : 0
        }
        base.pointee.has_at_least_one_ref = { base in
            (handlerBox(base)?.refCount.load(ordering: .acquiring) ?? 0) >= 1 ? 1 : 0
        }

        pointer = raw.bindMemory(to: T.self, capacity: 1)
        configure(&pointer.pointee)
    }

    deinit {
        cefRelease(pointer)
    }

    /// The struct with a reference for CEF (callback return values and
    /// arguments to CEF functions).
    func retained() -> UnsafeMutablePointer<T> {
        cefAddRef(pointer)
        return pointer
    }

    /// Resolves the Swift owner of a struct received as `self` in a callback.
    static func owner<O: AnyObject>(of pointer: UnsafeMutablePointer<T>?, as _: O.Type = O.self) -> O? {
        guard let pointer else { return nil }
        return handlerBox(cefBase(pointer))?.owner as? O
    }
}
