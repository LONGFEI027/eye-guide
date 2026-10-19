
import Foundation

public class RGCxrBaseResponse : NSObject {
    public var reqId: Int32 = 0
    public var status: Int32 = 0
    public var cmd: String = ""
    public var enumCmd: RGCxrCmd? {
        RGCxrCmd(rawValue: cmd)
    }
    public var caps: Any?
    public var subCmd: String = ""
    public var enumSubCmd: RGCxrSubCmd? {
        RGCxrSubCmd(rawValue: subCmd)
    }
    
    public func stringValue() -> String {
        return "type:\(1) reqId:\(reqId) status:\(status) cmd:\(cmd) subCmd:\(subCmd)"
    }
}

public class RGCxrErrorResponse : RGCxrBaseResponse {
    public var errorCode: Int32 = -1199
    public var errorMsg: String = ""
    
    public init(errorCode: Int32 = -1199, errorMsg: String = "") {
        self.errorCode = errorCode
        self.errorMsg = errorMsg
    }
    
    public override func stringValue() -> String {
        return super.stringValue() + " errorCode:\(errorCode) errorMsg:\(errorMsg)"
    }
}

public class RGCxrDataResponse : RGCxrBaseResponse {
    public var responseData: Any?
    public var responseDataEx: Any?
    
    public override func stringValue() -> String {
        let str = super.stringValue() + " responseData:\(String(describing: responseData))"
        if let responseDataEx = responseDataEx {
            return str + " responseDataEx:\(String(describing: responseDataEx))"
        } else {
            return str
        }
    }
}

public class RGCxrStreamResponse : RGCxrDataResponse {
    public var streamData: Data?
    
    public override func stringValue() -> String {
        return super.stringValue() + " streamData:\(String(describing: streamData?.count))"
    }
}
