//
//  PointerArrayExtension.swift
//  PointerArrayExtension
//
//  Created by Ginger on 2024/1/11.
//

import Foundation

public extension NSPointerArray {
    func addWeakObject<T: NSObjectProtocol>(_ object: T?) {
        guard let weakObjc = object else { return }
        let pointer = Unmanaged.passUnretained(weakObjc).toOpaque()
        objc_sync_enter(self)
        compact()
        addPointer(pointer)
        objc_sync_exit(self)
    }
    
    func removeWeakObject<T: NSObjectProtocol>(_ object: T?) {
        objc_sync_enter(self)
        compact()
        var listenerIndexArray = [Int]()
        for index in 0 ..< count {
            let pointerListener = pointer(at: index)
            guard let tempPointer = pointerListener else {
                // nil也要移除掉
                listenerIndexArray.append(index)
                continue
            }
            let tempListener = Unmanaged<T>.fromOpaque(tempPointer).takeUnretainedValue()
            if tempListener.isEqual(object) {
                listenerIndexArray.append(index)
            }
        }
        for listenerIndex in listenerIndexArray.sorted(by: >) {
            if listenerIndex < count {
                removePointer(at: listenerIndex)
            }
        }
        compact()
        objc_sync_exit(self)
    }
    
    func forEachWeakObject<T: NSObjectProtocol>(_ block: (T?) -> Void) {
        objc_sync_enter(self)
        compact()
        var objects: [T] = []
        objects.reserveCapacity(count)
        for index in 0 ..< count {
            let pointerListener = pointer(at: index)
            guard let tempPointer = pointerListener else {
                continue
            }
            let tempListener = Unmanaged<T>.fromOpaque(tempPointer).takeUnretainedValue()
            objects.append(tempListener)
        }
        objc_sync_exit(self)
        for obj in objects {
            block(obj)
        }
    }
}
