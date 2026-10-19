//
//  Navigator.swift
//  RGCoreKit
//
//  Created by Topredator on 2025/4/2.
//

import UIKit

/// 导航 控制器
public struct Navigator {
    /// 当前控制器
    public static func currentVC() -> UIViewController? {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first(where: { $0.isKeyWindow }) else {
            return nil
        }
        
        let rootVC = window.rootViewController
        return self.current(from: rootVC)
    }
    /// 当前导航控制器
    public static func currentNavigationVC() -> UINavigationController? {
        return self.currentVC()?.navigationController
    }
    /// 检查整个视图层级中是否包含指定类型的控制器
    /// 支持复杂的视图层级结构（包含多层 push 和 present）
    /// - Parameter cls: 目标控制器类型
    /// - Returns: 如果存在返回 true，否则返回 false
    public static func isContains<T: UIViewController>(_ cls: T.Type) -> Bool {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first(where: { $0.isKeyWindow }),
              let rootVC = window.rootViewController else {
            return false
        }
        
        // 递归检查整个视图层级
        func contains(in vc: UIViewController) -> Bool {
            // 检查当前控制器
            if vc is T {
                return true
            }
            
            // 如果是导航控制器，检查其栈中的所有控制器
            if let navVC = vc as? UINavigationController {
                if navVC.viewControllers.contains(where: { $0 is T }) {
                    return true
                }
            }
            
            // 如果是 TabBarController，递归检查所有 tab
            if let tabBarVC = vc as? UITabBarController {
                for viewController in tabBarVC.viewControllers ?? [] {
                    if contains(in: viewController) {
                        return true
                    }
                }
            }
            
            // 递归检查 presentedViewController
            if let presentedVC = vc.presentedViewController {
                if contains(in: presentedVC) {
                    return true
                }
            }
            
            return false
        }
        
        return contains(in: rootVC)
    }
    /// 获取整个视图层级中第一个指定类型的控制器
    /// 支持复杂的视图层级结构（包含多层 push 和 present）
    /// - Parameter type: 目标控制器类型
    /// - Returns: 找到的第一个控制器实例，未找到返回 nil
    public static func getFirst<T: UIViewController>(ofType type: T.Type) -> T? {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first(where: { $0.isKeyWindow }),
              let rootVC = window.rootViewController else {
            return nil
        }
        
        // 递归查找第一个匹配的控制器
        func findFirst(in vc: UIViewController) -> T? {
            // 检查当前控制器
            if let target = vc as? T {
                return target
            }
            
            // 如果是导航控制器，检查其栈中的所有控制器
            if let navVC = vc as? UINavigationController {
                if let target = navVC.viewControllers.first(where: { $0 is T }) as? T {
                    return target
                }
            }
            
            // 如果是 TabBarController，递归检查所有 tab
            if let tabBarVC = vc as? UITabBarController {
                for viewController in tabBarVC.viewControllers ?? [] {
                    if let target = findFirst(in: viewController) {
                        return target
                    }
                }
            }
            
            // 递归检查 presentedViewController
            if let presentedVC = vc.presentedViewController {
                if let target = findFirst(in: presentedVC) {
                    return target
                }
            }
            
            return nil
        }
        
        return findFirst(in: rootVC)
    }
    // MARK:  ------------- push --------------------
    /// push
    public static func push(_ targetVC: UIViewController?, animated: Bool = true) {
        guard let target = targetVC, !(target is UINavigationController) else { return }
        guard let navigaitonVC = self.currentNavigationVC() else { return }
        navigaitonVC.pushViewController(target, animated: animated)
    }
    // MARK:  ------------- present 模态 --------------------
    public static func present(_ targetVC: UIViewController?, animated: Bool) {
        self.present(targetVC, animated: animated, completion: nil)
    }
    public static func present(_ targetVC: UIViewController?, animated: Bool = true, completion: (() -> Void)? = nil) {
        guard let navigationVC = self.currentNavigationVC(), let target = targetVC else { return }
        navigationVC.present(target, animated: animated, completion: completion)
    }
    // MARK:  ------------- pop --------------------
    public static func pop(_ withTimes: Int, animated: Bool) {
        guard let currentNavigationVC = self.currentNavigationVC() else { return }
        let count: Int = currentNavigationVC.viewControllers.count
        if count > withTimes {
            currentNavigationVC.popToViewController(currentNavigationVC.viewControllers[count - 1 - withTimes], animated: animated)
        }
    }
    public static func popToRootVC(animated: Bool) {
        guard let currentNavigationVC = self.currentNavigationVC() else { return }
    
        let count: Int = currentNavigationVC.viewControllers.count
        self.pop(count-1, animated: animated)
    }
    
    /// 返回到指定类型的控制器
    /// 支持复杂的视图层级结构（包含多层 push 和 present）
    /// - Parameters:
    ///   - cls: 目标控制器类型
    ///   - animated: 是否使用动画，默认为 true
    ///   - completion: 完成回调
    /// - Note: 如果整个视图层级中不存在该类型的控制器，则不做任何操作
    public static func backTo<T: UIViewController>(_ cls: T.Type, animated: Bool = true, completion: (() -> Void)? = nil) {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first(where: { $0.isKeyWindow }),
              let rootVC = window.rootViewController else {
            completion?()
            return
        }
        
        // 递归查找目标控制器及其所在的导航控制器
        func findTargetVC(from vc: UIViewController) -> (targetVC: T, navigationVC: UINavigationController)? {
            // 检查当前控制器是否是目标类型
            if let target = vc as? T {
                // 如果有导航控制器，返回它
                if let navVC = vc.navigationController {
                    return (target, navVC)
                }
            }
            
            // 如果是导航控制器，检查其栈中的所有控制器
            if let navVC = vc as? UINavigationController {
                if let target = navVC.viewControllers.first(where: { $0 is T }) as? T {
                    return (target, navVC)
                }
            }
            
            // 如果是 TabBarController，递归检查所有 tab
            if let tabBarVC = vc as? UITabBarController {
                for viewController in tabBarVC.viewControllers ?? [] {
                    if let result = findTargetVC(from: viewController) {
                        return result
                    }
                }
            }
            
            // 递归检查 presentedViewController
            if let presentedVC = vc.presentedViewController {
                if let result = findTargetVC(from: presentedVC) {
                    return result
                }
            }
            
            return nil
        }
        
        // 查找目标控制器
        guard let result = findTargetVC(from: rootVC) else {
            // 未找到目标控制器，不做任何操作
            completion?()
            return
        }
        
        let targetVC = result.targetVC
        let targetNavigationVC = result.navigationVC
        
        // 查找需要 dismiss 的层级
        func findPresentingVC(for target: UIViewController) -> UIViewController? {
            var current = rootVC
            while let presented = current.presentedViewController {
                // 检查 presented 是否包含目标控制器
                if presented == target || presented == targetNavigationVC {
                    return current
                }
                // 如果 presented 是导航控制器，检查其栈
                if let navVC = presented as? UINavigationController,
                   navVC.viewControllers.contains(where: { $0 == target }) {
                    return current
                }
                // 如果 presented 是 TabBarController，递归检查
                if let tabBarVC = presented as? UITabBarController {
                    func containsTarget(in vc: UIViewController) -> Bool {
                        if vc == target || vc == targetNavigationVC {
                            return true
                        }
                        if let navVC = vc as? UINavigationController,
                           navVC.viewControllers.contains(where: { $0 == target }) {
                            return true
                        }
                        if let presented = vc.presentedViewController {
                            return containsTarget(in: presented)
                        }
                        return false
                    }
                    
                    for viewController in tabBarVC.viewControllers ?? [] {
                        if containsTarget(in: viewController) {
                            return current
                        }
                    }
                }
                current = presented
            }
            return nil
        }
        
        // 判断目标控制器是否在 present 层级中
        if let presentingVC = findPresentingVC(for: targetVC) {
            // 先 dismiss 到目标控制器所在的层级
            presentingVC.dismiss(animated: animated) {
                // dismiss 后再 pop 到目标控制器
                if targetNavigationVC.viewControllers.contains(targetVC) {
                    targetNavigationVC.popToViewController(targetVC, animated: false)
                }
                // 最后 dismiss 掉目标控制器上的所有模态视图
                if targetVC.presentedViewController != nil {
                    targetVC.dismiss(animated: false, completion: completion)
                } else {
                    completion?()
                }
            }
        } else {
            // 目标控制器不在 present 层级中，直接 pop
            targetNavigationVC.popToViewController(targetVC, animated: animated)
            // dismiss 掉目标控制器上的所有模态视图
            if targetVC.presentedViewController != nil {
                targetVC.dismiss(animated: false, completion: completion)
            } else {
                completion?()
            }
        }
    }
    // MARK:  ------------- dismiss --------------------
    public static func dismissVC(_ withTimes: Int, animated: Bool, completion: (() -> Void)?) {
        guard var currentVC = self.currentVC(), (currentVC.presentingViewController != nil) else {
            return
        }
        var times = withTimes
        while times > 0 {
            currentVC = currentVC.presentingViewController!
            if currentVC.presentingViewController == nil { break }
            times -= 1
        }
        currentVC.dismiss(animated: animated, completion: completion)
    }
    public static func dismissToRoot(animated: Bool, completion: (() -> Void)? = nil) {
        guard var currentVC = self.currentVC(), (currentVC.presentingViewController != nil) else {
            return
        }
        while currentVC.presentingViewController != nil {
            currentVC = currentVC.presentingViewController!
        }
        currentVC.dismiss(animated: animated, completion: completion)
    }
    
    // MARK: ------------- 回到 rootViewController --------------------
    /// 回到 window 的 rootViewController
    /// 无论当前视图层级多复杂（包含多层 push 和 present），都会处理完所有视图层级
    /// - Parameters:
    ///   - animated: 是否使用动画，默认为 true
    ///   - completion: 完成回调
    public static func backToRootVC(animated: Bool = true, completion: (() -> Void)? = nil) {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first(where: { $0.isKeyWindow }),
              let rootVC = window.rootViewController else {
            completion?()
            return
        }
        
        // 获取最顶层的 presentedViewController（递归查找）
        func getTopmostPresentedViewController(from vc: UIViewController) -> UIViewController {
            if let presented = vc.presentedViewController {
                return getTopmostPresentedViewController(from: presented)
            }
            return vc
        }
        
        let topmostVC = getTopmostPresentedViewController(from: rootVC)
        
        // 处理 present 的 modal 视图
        let hasPresentedVC = topmostVC != rootVC
        
        // 处理 push 的视图栈
        func popToRootIfNeeded(in vc: UIViewController, animated: Bool) {
            // 如果是 NavigationController，pop 到根控制器
            if let navController = vc as? UINavigationController, navController.viewControllers.count > 1 {
                navController.popToRootViewController(animated: animated)
            }
            // 如果是 TabBarController，处理当前选中的 tab
            else if let tabBarController = vc as? UITabBarController,
                    let selectedNav = tabBarController.selectedViewController as? UINavigationController,
                    selectedNav.viewControllers.count > 1 {
                selectedNav.popToRootViewController(animated: animated)
            }
        }
        
        if hasPresentedVC {
            // 先 dismiss 所有 modal 视图
            rootVC.dismiss(animated: animated) {
                // dismiss 后再处理 push 栈
                popToRootIfNeeded(in: rootVC, animated: false)
                completion?()
            }
        } else {
            // 没有 modal 视图，只处理 push 栈
            popToRootIfNeeded(in: rootVC, animated: animated)
            completion?()
        }
    }
    
    /// 回到 window 的 rootViewController 并选中 TabBar 的指定标签页
    /// 无论当前视图层级多复杂（包含多层 push 和 present），都会处理完所有视图层级，然后切换 tab
    /// - Parameters:
    ///   - index: 要选中的 TabBar 索引
    ///   - animated: 是否使用动画，默认为 true
    ///   - completion: 完成回调
    public static func backToRootVCAndSelectTab(at index: Int, animated: Bool = true, completion: (() -> Void)? = nil) {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first(where: { $0.isKeyWindow }),
              let rootVC = window.rootViewController else {
            completion?()
            return
        }
        
        // 获取最顶层的 presentedViewController（递归查找）
        func getTopmostPresentedViewController(from vc: UIViewController) -> UIViewController {
            if let presented = vc.presentedViewController {
                return getTopmostPresentedViewController(from: presented)
            }
            return vc
        }
        
        let topmostVC = getTopmostPresentedViewController(from: rootVC)
        let hasPresentedVC = topmostVC != rootVC
        
        // 选中指定的 tab 并处理其 push 栈
        func selectTabAndPopIfNeeded(in vc: UIViewController, at index: Int, animated: Bool) {
            if let tabBarController = vc as? UITabBarController {
                tabBarController.selectedIndex = index
                // 如果选中的 tab 是 NavigationController，pop 到根控制器
                if let selectedNav = tabBarController.selectedViewController as? UINavigationController,
                   selectedNav.viewControllers.count > 1 {
                    selectedNav.popToRootViewController(animated: animated)
                }
            }
        }
        
        if hasPresentedVC {
            // 先 dismiss 所有 modal 视图
            rootVC.dismiss(animated: animated) {
                // dismiss 后再选中 tab 并处理 push 栈
                selectTabAndPopIfNeeded(in: rootVC, at: index, animated: false)
                completion?()
            }
        } else {
            // 没有 modal 视图，直接选中 tab 并处理 push 栈
            selectTabAndPopIfNeeded(in: rootVC, at: index, animated: animated)
            completion?()
        }
    }
    
    /// 递归 拿到当前控制器
    /// - Parameter from: root
    /// - Returns: 当前控制器
    static func current(from: UIViewController?) -> UIViewController? {
        if from is UINavigationController {
            return self.current(from: (from as! UINavigationController).viewControllers.last)
        } else if from is UITabBarController {
            return self.current(from: (from as! UITabBarController).selectedViewController)
        } else if from?.presentedViewController != nil {
            return self.current(from: from?.presentedViewController)
        } else {
            return from
        }
    }
    
}
