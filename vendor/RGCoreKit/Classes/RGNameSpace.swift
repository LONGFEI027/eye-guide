//
//  RGNameSpace.swift
//  RGCoreKit
//
//  Created by Topredator on 2025/4/21.
//

import Foundation


public protocol RGTypeWrapper {
    associatedtype TargetType
    var base: TargetType { get }
    init(_ base: TargetType)
}

public struct RGNameSpace<Base>: RGTypeWrapper {
    public var base: Base
    public init(_ base: Base) {
        self.base = base
    }
}

/// 命名空间协议
public protocol RGNameSpaceWrappable {
    associatedtype TargetType
    var rokid: TargetType { get set }
    static var rokid: TargetType.Type { get set }
}

extension RGNameSpaceWrappable {
    public var rokid: RGNameSpace<Self> {
        get { RGNameSpace<Self>(self) }
        set {}
    }
    public static var rokid: RGNameSpace<Self>.Type {
        get { RGNameSpace<Self>.self }
        set {}
    }
}
