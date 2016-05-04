import Foundation
import Result

public class Session {
    public let URLSession: NSURLSession
    
    public init(URLSession: NSURLSession) {
        self.URLSession = URLSession
    }

    // send request and build response object
    public func sendRequest<T: RequestType>(request: T, handler: (Result<T.Response, APIError>) -> Void = {r in}) -> NSURLSessionDataTask? {
        switch request.buildURLRequest() {
        case .Failure(let error):
            dispatch_async(dispatch_get_main_queue()) {
                handler(.Failure(error))
            }
            return nil

        case .Success(let URLRequest):
            let dataTask = URLSession.dataTaskWithRequest(URLRequest)
            dataTask.request = Box(request)
            dataTask.completionHandler = { data, URLResponse, connectionError in
                let sessionResult: Result<(NSData, NSURLResponse?), APIError>
                if let error = connectionError {
                    sessionResult = .Failure(.ConnectionError(error))
                } else {
                    sessionResult = .Success((data, URLResponse))
                }

                let result: Result<T.Response, APIError> = sessionResult.flatMap { data, URLResponse in
                    request.parseData(data, URLResponse: URLResponse)
                }

                dispatch_async(dispatch_get_main_queue()) {
                    handler(result)
                }
            }
            
            dataTask.resume()
            
            return dataTask
        }
    }
    
    public func cancelRequest<T: RequestType>(requestType: T.Type, passingTest test: T -> Bool = { r in true }) {
        URLSession.getTasksWithCompletionHandler { dataTasks, uploadTasks, downloadTasks in
            let allTasks = dataTasks as [NSURLSessionTask]
                + uploadTasks as [NSURLSessionTask]
                + downloadTasks as [NSURLSessionTask]

            allTasks.filter { task in
                let request: T?
                switch task {
                case let x as NSURLSessionDataTask:
                    request = x.request?.value as? T

                case let x as NSURLSessionDownloadTask:
                    request = x.request?.value as? T
                    
                default:
                    request = nil
                }
                
                if let request = request {
                    return test(request)
                } else {
                    return false
                }
            }.forEach { $0.cancel() }
        }
    }
    
    // Shared session for class methods
    private static let privateSharedSession = Session(URLSession: NSURLSession(
        configuration: NSURLSessionConfiguration.defaultSessionConfiguration(),
        delegate: URLSessionDelegate(),
        delegateQueue: nil
    ))

    public class var sharedSession: Session {
        return privateSharedSession
    }

    public class func sendRequest<T: RequestType>(request: T, handler: (Result<T.Response, APIError>) -> Void = {r in}) -> NSURLSessionDataTask? {
        return sharedSession.sendRequest(request, handler: handler)
    }
    
    public class func cancelRequest<T: RequestType>(requestType: T.Type, passingTest test: T -> Bool = { r in true }) {
        sharedSession.cancelRequest(requestType, passingTest: test)
    }
}

@available(*, unavailable, renamed="Session")
public typealias API = Session

extension Session {
    @available(*, unavailable, message="Use separated Session instance instead.")
    public static func sendRequest<T: RequestType>(request: T, URLSession: NSURLSession, handler: (Result<T.Response, APIError>) -> Void = {r in}) -> NSURLSessionDataTask? {
        abort()
    }
    
    @available(*, unavailable, message="Use separated Session instance instead.")
    public static func cancelRequest<T: RequestType>(requestType: T.Type, URLSession: NSURLSession, passingTest test: T -> Bool = { r in true }) {
        abort()
    }
}

// MARK: - default implementation of URLSessionDelegate
public class URLSessionDelegate: NSObject, NSURLSessionDelegate, NSURLSessionDataDelegate {
    // MARK: NSURLSessionTaskDelegate
    public func URLSession(session: NSURLSession, task: NSURLSessionTask, didCompleteWithError connectionError: NSError?) {
        if let dataTask = task as? NSURLSessionDataTask {
            dataTask.completionHandler?(dataTask.responseBuffer, dataTask.response, connectionError)
        }
    }

    // MARK: NSURLSessionDataDelegate
    public func URLSession(session: NSURLSession, dataTask: NSURLSessionDataTask, didReceiveData data: NSData) {
        dataTask.responseBuffer.appendData(data)
    }
    
    public func URLSession(session: NSURLSession, dataTask: NSURLSessionDataTask, didBecomeDownloadTask downloadTask: NSURLSessionDownloadTask) {
        downloadTask.request = dataTask.request
    }
}

// Box<T> is still necessary internally to store struct into associated object
private final class Box<T> {
    let value: T
    init(_ value: T) {
        self.value = value
    }
}

// MARK: - NSURLSessionTask extensions
private var taskRequestKey = 0
private var dataTaskResponseBufferKey = 0
private var dataTaskCompletionHandlerKey = 0

private extension NSURLSessionDataTask {
    // `var request: RequestType?` is not available in Swift 2.0
    // ("protocol can only be used as a generic constraint")
    private var request: Box<Any>? {
        get {
            return objc_getAssociatedObject(self, &taskRequestKey) as? Box<Any>
        }
        
        set {
            if let value = newValue {
                objc_setAssociatedObject(self, &taskRequestKey, value, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            } else {
                objc_setAssociatedObject(self, &taskRequestKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }
        }
    }
    
    private var responseBuffer: NSMutableData {
        if let responseBuffer = objc_getAssociatedObject(self, &dataTaskResponseBufferKey) as? NSMutableData {
            return responseBuffer
        } else {
            let responseBuffer = NSMutableData()
            objc_setAssociatedObject(self, &dataTaskResponseBufferKey, responseBuffer, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            return responseBuffer
        }
    }
    
    private var completionHandler: ((NSData, NSURLResponse?, NSError?) -> Void)? {
        get {
            return (objc_getAssociatedObject(self, &dataTaskCompletionHandlerKey) as? Box<(NSData, NSURLResponse?, NSError?) -> Void>)?.value
        }
        
        set {
            if let value = newValue  {
                objc_setAssociatedObject(self, &dataTaskCompletionHandlerKey, Box(value), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            } else {
                objc_setAssociatedObject(self, &dataTaskCompletionHandlerKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }
        }
    }
}

private extension NSURLSessionDownloadTask {
    private var request: Box<Any>? {
        get {
            return objc_getAssociatedObject(self, &taskRequestKey) as? Box<Any>
        }
        
        set {
            if let value = newValue {
                objc_setAssociatedObject(self, &taskRequestKey, value, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            } else {
                objc_setAssociatedObject(self, &taskRequestKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }
        }
    }
}
