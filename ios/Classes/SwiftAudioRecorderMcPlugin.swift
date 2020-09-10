import Flutter
import UIKit

//This is a comment
public class SwiftAudioRecorderMcPlugin: NSObject, FlutterPlugin {
  var recorder = MCAudioRecorder()
  var eventSink: FlutterEventSink?
  
  public static func register(with registrar: FlutterPluginRegistrar) {
    let setupChannel = FlutterMethodChannel(
      name: "com.masterconcept.audiorecorder/setup", binaryMessenger: registrar.messenger())
    let startRecordChannel = FlutterMethodChannel(
      name: "com.masterconcept.audiorecorder/start", binaryMessenger: registrar.messenger())
    let stopRecordChannel = FlutterMethodChannel(
      name: "com.masterconcept.audiorecorder/stop", binaryMessenger: registrar.messenger())
    let samplesRecordChannel = FlutterEventChannel(
      name: "com.masterconcept.audiorecorder/samples", binaryMessenger: registrar.messenger())
    
    let instance = SwiftAudioRecorderMcPlugin()
    
    registrar.addMethodCallDelegate(instance, channel: setupChannel)
    registrar.addMethodCallDelegate(instance, channel: startRecordChannel)
    registrar.addMethodCallDelegate(instance, channel: stopRecordChannel)
    samplesRecordChannel.setStreamHandler(instance)
  }
  
  
  // sampleFormat is 0,1,2 for 8bit, 16bit, 32bit respectively
  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "com.masterconcept.audiorecorder/setup" {
      if let args = call.arguments as? Dictionary<String, Any> {
        let sampleRate = args["sampleRate"] as? Int
        if sampleRate != nil { recorder.setRate(sampleRate!) }
        
        let sampleFormat = args["sampleFormat"] as? Int
        var bits : Int = 8
        switch sampleFormat ?? 0 {
          case 0:
            bits = 8
          case 1:
            bits = 16
          case 2:
            bits = 32
          default:
            bits = 16
        }
        recorder.setBits(bits)
        
        // result("iOS - MC Audio Recording is Ready. RATE: \(recorder.sampleRate) BITS: \(bits)")
        result(recorder.getBufferSize())
      }
    } else if call.method == "com.masterconcept.audiorecorder/start" {
      recorder.delegate = self
      recorder.startRecording()
      result("iOS - MC Audio Record Started")
    } else if call.method == "com.masterconcept.audiorecorder/stop" {
      recorder.delegate = nil
      recorder.stopRecording()
      result("iOS - MC Audio Record Stopped")
    } else {
      result(FlutterMethodNotImplemented)
    }
  }
}

extension SwiftAudioRecorderMcPlugin: MCAudioRecorderFloatDelegate {
  func buffer(_ samples: [Float]) {
    if eventSink != nil {
      eventSink!(samples)
    }
  }
}

extension SwiftAudioRecorderMcPlugin: MCAudioRecorderInt16Delegate {
  func buffer(_ samples: [Int16]) {
    if eventSink != nil {
      eventSink!(samples)
    }
  }
}

extension SwiftAudioRecorderMcPlugin: FlutterStreamHandler {
  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }
  
  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }
}


