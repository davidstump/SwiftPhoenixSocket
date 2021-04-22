//
//  URLSessionTransport.swift
//  SwiftPhoenixClient
//
//  Created by Daniel Rees on 4/22/21.
//  Copyright © 2021 SwiftPhoenixClient. All rights reserved.
//

import Foundation

//----------------------------------------------------------------------
// MARK: - Default Websocket Transport Implementation
//----------------------------------------------------------------------
/**
 A `Transport` implementation that relies on URLSession's native WebSocket
 implementation.
 
 This implementation ships default with SwiftPhoenixClient however
 SwiftPhoenixClient supports earlier OS versions using one of the submodule
 `Transport` implementations. Or you can create your own implementation using
 your own WebSocket library or implementation.
 */
@available(macOS 10.15, iOS 13, watchOS 6, tvOS 13, *)
public class URLSessionTransport: NSObject, PhoenixTransport, URLSessionWebSocketDelegate {
  
  
  /// The URL to connect to
  internal let url: URL
  
  /// An optional hook that allows the caller of the client to manipulate
  /// the task prior to resuming.
  internal let taskConfigHook: ((URLSessionWebSocketTask) -> URLSessionWebSocketTask)
  
  /// The underling URLsession. Assigned during `connect()`
  private var session: URLSession? = nil
  
  /// The ongoing task. Assigned during `connect()`
  private var task: URLSessionWebSocketTask? = nil
  
  
  
  /**
   Initializes a `Transport` layer built using URLSession's WebSocket
   
   Example:
   
   ```swift
   let url = URL("wss://example.com/socket")
   let transport: Transport = URLSessionTransport(url: url)
   ```
   
   - parameter url: URL to connect to
   */
  public init(url: URL, taskConfigHook: @escaping ((URLSessionWebSocketTask) -> URLSessionWebSocketTask) = { $0 }) {
  
    // URLSession requires that the endpoint be "wss" instead of "https".
    let endpoint = url.absoluteString
    let wsEndpoint = endpoint
      .replacingOccurrences(of: "http://", with: "ws://")
      .replacingOccurrences(of: "https://", with: "wss://")
    
    // Force unwrapping should be safe here since a valid URL came in and we just
    // replaced the protocol.
    self.url = URL(string: wsEndpoint)!
    self.taskConfigHook = taskConfigHook
    
    super.init()
  }
  
  
  
  // MARK: - Transport
  public var readyState: PhoenixTransportReadyState = .closed
  public var delegate: PhoenixTransportDelegate? = nil
  
  public func connect() {
    // Set the trasport state as connecting
    self.readyState = .connecting
    
    // Create the session and websocket task
    let session = URLSession(configuration: .default, delegate: self, delegateQueue: OperationQueue())
    self.session = session
    
    // Create a task and allow the consumer of the client an opportunity to manipulate it,
    // such as adding cookies.
    self.task = self.taskConfigHook(session.webSocketTask(with: url))
    
    // Start the task
    self.task?.resume()
  }
  
  public func disconnect(code: Int, reason: String?) {
    /*
     TODO:
     1. Provide a "strict" mode that fails if an invalid close code is given
     2. If strict mode is disabled, default to CloseCode.invalid
     3. Provide default .normalClosure function
     */
    guard let closeCode = URLSessionWebSocketTask.CloseCode.init(rawValue: code) else {
      fatalError("Could not create a CloseCode with invalid code: [\(code)].")
    }
    
    self.readyState = .closing
    self.task?.cancel(with: closeCode, reason: reason?.data(using: .utf8))
    self.session?.invalidateAndCancel()
  }
  
  public func send(data: Data) {
    self.task?.send(.data(data)) { (error) in
      // TODO: What is the behavior when an error occurs?
    }
  }
  
  
  // MARK: - URLSessionWebSocketDelegate
  public func urlSession(_ session: URLSession,
                         webSocketTask: URLSessionWebSocketTask,
                         didOpenWithProtocol protocol: String?) {
    // The Websocket is connected. Set Transport state to open and inform delegate
    self.readyState = .open
    self.delegate?.onOpen()
    
    // Start receiving messages
    self.receive()
  }
  
  public func urlSession(_ session: URLSession,
                         webSocketTask: URLSessionWebSocketTask,
                         didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                         reason: Data?) {
    // A close frame was received from the server.
    self.readyState = .closed
    self.delegate?.onClose(code: closeCode.rawValue)
  }
  
  public func urlSession(_ session: URLSession,
                         task: URLSessionTask,
                         didCompleteWithError error: Error?) {
    // The task has terminated. Inform the delegate that the transport has closed abnormally
    // if this was caused by an error.
    guard let err = error else { return }
    self.abnormalErrorReceived(err)
  }
  
  
  // MARK: - Private
  private func receive() {
    self.task?.receive { result in
      switch result {
      case .success(let message):
        switch message {
        case .data:
          print("Data received. This method is unsupported by the Client")
        case .string(let text):
          self.delegate?.onMessage(message: text)
        default:
          fatalError("Unknown result was received. [\(result)]")
        }
        
        // Since `.receive()` is only good for a single message, it must
        // be called again after a message is received in order to
        // received the next message.
        self.receive()
      case .failure(let error):
        print("Error when receiving \(error)")
        self.abnormalErrorReceived(error)
      }
    }
  }
  
  private func abnormalErrorReceived(_ error: Error) {
    // Set the state of the Transport to closed
    self.readyState = .closed
    
    // Inform the Transport's delegate that an error occurred.
    self.delegate?.onError(error: error)
    
    // An abnormal error is results in an abnormal closure, such as internet getting dropped
    // so inform the delegate that the Transport has closed abnormally. This will kick off
    // the reconnect logic.
    self.delegate?.onClose(code: Socket.CloseCode.abnormal.rawValue)
  }
}
