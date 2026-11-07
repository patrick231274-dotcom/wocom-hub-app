import AVFAudio
import CallKit
import Flutter
import PushKit
import UIKit
import flutter_callkit_incoming
#if canImport(WebRTC)
import WebRTC
#endif

/// WOCOM HUB on iPhone.
/// Incoming calls arrive as Apple VoIP pushes (PushKit). iOS requires every VoIP push to be shown
/// as a call straight away, so the ringer is put up here, natively, before Flutter is involved;
/// the Dart side then connects the line (Phone.pushIncoming) and the call lands on Answer.
@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, PKPushRegistryDelegate, CallkitIncomingAppDelegate {
  private var voipRegistry: PKPushRegistry?
  /// Last resort when the call plugin isn't loaded yet: report and end the call ourselves,
  /// because a VoIP push that shows no call gets the app's pushes cut off by iOS.
  private lazy var fallbackProvider: CXProvider = {
    let config = CXProviderConfiguration()
    config.supportsVideo = false
    config.maximumCallsPerCallGroup = 1
    config.supportedHandleTypes = [.generic, .phoneNumber]
    return CXProvider(configuration: config)
  }()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let ok = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    let registry = PKPushRegistry(queue: DispatchQueue.main)
    registry.delegate = self
    registry.desiredPushTypes = [.voIP]
    voipRegistry = registry
    return ok
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }

  // MARK: PushKit

  func pushRegistry(_ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType) {
    let token = credentials.token.map { String(format: "%02x", $0) }.joined()
    SwiftFlutterCallkitIncomingPlugin.sharedInstance?.setDevicePushTokenVoIP(token)
  }

  func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
    SwiftFlutterCallkitIncomingPlugin.sharedInstance?.setDevicePushTokenVoIP("")
  }

  func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload,
                    for type: PKPushType, completion: @escaping () -> Void) {
    guard type == .voIP else { completion(); return }
    let p = payload.dictionaryPayload
    let id = (p["call_uuid"] as? String).flatMap { UUID(uuidString: $0) != nil ? $0 : nil } ?? UUID().uuidString
    let number = p["caller_number"] as? String ?? ""
    let name = p["caller_name"] as? String ?? ""

    guard let plugin = SwiftFlutterCallkitIncomingPlugin.sharedInstance else {
      let update = CXCallUpdate()
      update.remoteHandle = CXHandle(type: .generic, value: name.isEmpty ? number : name)
      let uuid = UUID(uuidString: id) ?? UUID()
      fallbackProvider.reportNewIncomingCall(with: uuid, update: update) { _ in
        self.fallbackProvider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
        completion()
      }
      return
    }

    let data = flutter_callkit_incoming.Data(id: id, nameCaller: name.isEmpty ? number : name,
                                             handle: number, type: 0)
    data.appName = "WOCOM HUB"
    data.duration = 45000
    data.handleType = "generic"
    data.supportsVideo = false
    data.supportsDTMF = true
    data.supportsHolding = true
    data.includesCallsInRecents = true
    data.missedNotificationSubtitle = "Missed call"
    data.missedNotificationCallbackText = "Call back"
    data.extra = ["call_uuid": id, "caller_number": number, "caller_name": name, "platform": "ios"]
    plugin.showCallkitIncoming(data, fromPushKit: true) { completion() }
  }

  // MARK: CallKit actions (the Dart side does the SIP work; just let iOS move on)

  func onAccept(_ call: Call, _ action: CXAnswerCallAction) { action.fulfill() }
  func onDecline(_ call: Call, _ action: CXEndCallAction) { action.fulfill() }
  func onEnd(_ call: Call, _ action: CXEndCallAction) { action.fulfill() }
  func onTimeOut(_ call: Call) {}
  func providerDidReset() {}

  // CallKit owns the audio session during a call: hand it to WebRTC when iOS activates it.
  func didActivateAudioSession(_ audioSession: AVAudioSession) {
    #if canImport(WebRTC)
    RTCAudioSession.sharedInstance().audioSessionDidActivate(audioSession)
    RTCAudioSession.sharedInstance().isAudioEnabled = true
    #endif
  }

  func didDeactivateAudioSession(_ audioSession: AVAudioSession) {
    #if canImport(WebRTC)
    RTCAudioSession.sharedInstance().audioSessionDidDeactivate(audioSession)
    RTCAudioSession.sharedInstance().isAudioEnabled = false
    #endif
  }
}
