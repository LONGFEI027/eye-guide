import Foundation

private class RGClosureWrapper: NSObject {
    let closure: () -> Void
    init(_ closure: @escaping () -> Void) {
        self.closure = closure
    }
    
    @objc func invoke() {
        closure()
    }
}

public class RGThread: NSObject {
//    static let shared = RGThread()
    
    private var residentThread: Thread?
    var isKeepRunning = true
    
    var currentResidentThread: Thread {
        // 使用双重检查锁定模式确保线程只创建一次
        if residentThread == nil {
            objc_sync_enter(self)
            defer { objc_sync_exit(self) }
            
            if residentThread == nil {
                residentThread = createThread()
            }
        }
        return residentThread!
    }
    let name: String
    @objc private func creatThreadMethod(_ wrapper: RGClosureWrapper) {
        wrapper.invoke()
    }
    
    @objc private func threadTaskMethod(_ wrapper: RGClosureWrapper) {
        wrapper.invoke()
    }
    
    public init(_ name: String) {
        self.name = name
    }
    
    private func createThread() -> Thread {
        let thread: Thread
        weak var weakSelf = self
        
        let creatThreadBlock: () -> Void = {
            let currentLoop = RunLoop.current
            currentLoop.add(Port(), forMode: .default)
            
            while weakSelf?.isKeepRunning == true {
                currentLoop.run(mode: .default, before: .distantFuture)
            }
        }
        
        // 使用包装器传递闭包
        let wrapper = RGClosureWrapper(creatThreadBlock)
        
        if #available(iOS 10.0, *) {
            thread = Thread(target: self,
                            selector: #selector(creatThreadMethod(_:)),
                            object: wrapper)
        } else {
            thread = Thread(block: creatThreadBlock)
        }
        
        thread.name = name
        isKeepRunning = true
        thread.start()
        return thread
    }
    
    public func execute(_ task: @escaping () -> Void) {
        let wrapper = RGClosureWrapper(task)
        perform(#selector(threadTaskMethod(_:)),
                on: currentResidentThread,
                with: wrapper,
                waitUntilDone: false)
    }
}
