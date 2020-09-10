//
//  McAudioRecorder.swift
//  mc_audio_recorder
//
//  Created by Diego Lopes on 23/04/20.
//

// JEFF: this code actually appears to be copied almost directly from
// https://gist.github.com/hotpaw2/ba815fc23b5d642705f2b1dedfaf0107
// original copyright notice is here:
//
//  Created by Ronald Nicholson on 10/21/16.
//  Copyright © 2017,2019 HotPaw Productions. All rights reserved.
//  http://www.nicholson.com/rhn/
//  Distribution permission: BSD 2-clause license
//


import Foundation
import AVFoundation
import AudioUnit

var gTmp0 = 0 //  temporary variable for debugger viewing

class MCAudioRecorder: NSObject {
  
  weak var delegateFloat: MCAudioRecorderFloatDelegate?
  weak var delegateInt16: MCAudioRecorderInt16Delegate?
  var delegate: Any?
  
  var sinkOnChanged: FlutterEventSink?
  var listeningOnChanged = false
  
  private var audioUnit:   AudioUnit?
  private var micPermission   =  false
  private var sessionActive   =  false
  private var isRecording     =  false
  private var interrupted     =  false     // for restart from audio interruption notification
  private var micPermissionDispatchToken = 0
  private let outputBus: UInt32   =  0
  private let inputBus : UInt32   =  1
  private var samples  :[Any?]    = []
  
  // Circular Buffer is not used
  // let circBuffSize = 32768              // lock-free circular fifo/buffer size
  // var circBuffer   = [Float](repeating: 0, count: circBuffSize)  // for incoming samples
  // var circInIdx  : Int =  0
  var requestedSampleRate : Double     = 44100.0     // default audio sample rate
  var deviceSampleRate : Double        = 44100.0     // default audio sample rate
  var sampleSizeInBytes : Int = 2           // default to 16 bit recording
  var numberOfChannels: Int   = 1           // default to mono recording
  var bufferSize : Int        = 1024        // 256 * numberOfChannels * sampleSizeInBytes
  var bufferDuration : Double = 0.0058      // 256 * 1 / (sampleRate * numberOfChannels)
  var formatFlags : AudioFormatFlags = kAudioFormatFlagIsSignedInteger
  
  func getBufferSize() -> Int {
    return bufferSize
  }
  
  func computeBufferSizes() {
    // we want a buffer of 512 samples
    bufferDuration = 512 * 1 / (deviceSampleRate * Double(numberOfChannels))
    bufferSize = 512 * numberOfChannels * sampleSizeInBytes
  }
  
  func setRate(_ sampleRate: Int) {
    requestedSampleRate = Double(sampleRate)
    deviceSampleRate = Double(sampleRate)
    print("Requested sample rate for recording: \(requestedSampleRate)")
    computeBufferSizes()
  }
  
  func setBits(_ bits: Int) {
    formatFlags = kAudioFormatFlagIsSignedInteger
    switch bits {
      case 32:
        sampleSizeInBytes = 4
        samples = [Float]()
        delegate = delegateFloat
        formatFlags = kAudioFormatFlagIsFloat
      default:
        sampleSizeInBytes = 2
        samples = [Int16]()
        delegate = delegateInt16
    }
    computeBufferSizes()
  }
  
  func stopRecording() {
    if (self.audioUnit != nil){
      AudioUnitUninitialize(self.audioUnit!)
    }
    isRecording = false
  }

  
  func startRecording() {
    if isRecording { return }
    startAudioSession()
    startAudioUnit()
  }
  
  func startAudioUnit() {
    var err: OSStatus = noErr
    samples.removeAll()
    
    if self.audioUnit == nil {
      setupAudioUnit()         // setup once
    }
    guard let au = self.audioUnit
      else { return }
    
    err = AudioUnitInitialize(au)
    gTmp0 = Int(err)
    if err != noErr { return }
    err = AudioOutputUnitStart(au)  // start
    
    gTmp0 = Int(err)
    if err == noErr {
      isRecording = true
    }
  }
  
  func startAudioSession() {
    if (sessionActive == false) {
      // set and activate Audio Session
      do {
        
        let audioSession = AVAudioSession.sharedInstance()
        
        if (micPermission == false) {
          if (micPermissionDispatchToken == 0) {
            micPermissionDispatchToken = 1
            audioSession.requestRecordPermission({(granted: Bool)-> Void in
              if granted {
                self.micPermission = true
                return
                // check for this flag and call from UI loop if needed
              } else {
                gTmp0 += 1
                // dispatch in main/UI thread an alert
                //   informing that mic permission is not switched on
              }
            })
          }
        }
        if micPermission == false { return }
        
        if #available(iOS 10, *) {
          try audioSession.setCategory(
            AVAudioSession.Category.record,
            mode: AVAudioSession.Mode.voiceChat,
            options: [
              AVAudioSession.CategoryOptions.allowBluetooth,
              AVAudioSession.CategoryOptions.allowBluetoothA2DP
            ]
          )
        } else {
          try audioSession.setCategory(AVAudioSession.Category.record,
                                       options: [.allowBluetooth])
          try audioSession.setMode(AVAudioSession.Mode.voiceChat)
        }
        if #available(iOS 13, *) {
          try audioSession.setAllowHapticsAndSystemSoundsDuringRecording(true)
        }
        
        NotificationCenter.default.addObserver(
          forName: AVAudioSession.interruptionNotification,
          object: nil,
          queue: nil,
          using: myAudioSessionInterruptionHandler )
        
        try audioSession.setActive(true)
        try audioSession.setPreferredSampleRate(requestedSampleRate)
        deviceSampleRate = audioSession.sampleRate
        print("Requested sample rate for recording: \(requestedSampleRate)")
        print("Actual sample rate for recording: \(deviceSampleRate)")
        
        computeBufferSizes()

        try audioSession.setPreferredIOBufferDuration(bufferDuration)
        try audioSession.setPreferredInputNumberOfChannels(numberOfChannels)

        sessionActive = true
      } catch /* let error as NSError */ {
        // handle error here
      }
    }
  }
  
  private func setupAudioUnit() {
    
    var componentDesc:  AudioComponentDescription
      = AudioComponentDescription(
        componentType:          OSType(kAudioUnitType_Output),
        componentSubType:       OSType(kAudioUnitSubType_RemoteIO),
        componentManufacturer:  OSType(kAudioUnitManufacturer_Apple),
        componentFlags:         UInt32(0),
        componentFlagsMask:     UInt32(0) )
    
    var osErr: OSStatus = noErr
    
    let component: AudioComponent! = AudioComponentFindNext(nil, &componentDesc)
    
    var tempAudioUnit: AudioUnit?
    osErr = AudioComponentInstanceNew(component, &tempAudioUnit)
    self.audioUnit = tempAudioUnit
    
    guard let au = self.audioUnit
      else { return }
    
    
    // Enable I/O for input.
    var one_ui32: UInt32 = 1
    osErr = AudioUnitSetProperty(au,
                                 kAudioOutputUnitProperty_EnableIO,
                                 kAudioUnitScope_Input,
                                 inputBus,
                                 &one_ui32,
                                 UInt32(MemoryLayout<UInt32>.size))
    
    // Set audio format
    var streamFormatDesc:AudioStreamBasicDescription = AudioStreamBasicDescription(
      mSampleRate:        deviceSampleRate,
      mFormatID:          kAudioFormatLinearPCM,
      mFormatFlags:       formatFlags,
      mBytesPerPacket:    UInt32(numberOfChannels * sampleSizeInBytes),
      mFramesPerPacket:   1,
      mBytesPerFrame:     UInt32(numberOfChannels * sampleSizeInBytes),
      mChannelsPerFrame:  UInt32(numberOfChannels),
      mBitsPerChannel:    UInt32(8 * sampleSizeInBytes),
      mReserved:          UInt32(0)
    )
    
    osErr = AudioUnitSetProperty(au,
                                 kAudioUnitProperty_StreamFormat,
                                 kAudioUnitScope_Input,
                                 outputBus,
                                 &streamFormatDesc,
                                 UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
    
    osErr = AudioUnitSetProperty(au,
                                 kAudioUnitProperty_StreamFormat,
                                 kAudioUnitScope_Output,
                                 inputBus,
                                 &streamFormatDesc,
                                 UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
    
    var inputCallbackStruct
      = AURenderCallbackStruct(inputProc: recordingCallback,
                               inputProcRefCon:
        UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
    
    osErr = AudioUnitSetProperty(au,
                                 AudioUnitPropertyID(kAudioOutputUnitProperty_SetInputCallback),
                                 AudioUnitScope(kAudioUnitScope_Global),
                                 inputBus,
                                 &inputCallbackStruct,
                                 UInt32(MemoryLayout<AURenderCallbackStruct>.size))
    
    // Ask CoreAudio to allocate buffers on render.
    osErr = AudioUnitSetProperty(au,
                                 AudioUnitPropertyID(kAudioUnitProperty_ShouldAllocateBuffer),
                                 AudioUnitScope(kAudioUnitScope_Output),
                                 inputBus,
                                 &one_ui32,
                                 UInt32(MemoryLayout<UInt32>.size))
    gTmp0 = Int(osErr)
  }
  
  let recordingCallback: AURenderCallback = { (
    inRefCon,
    ioActionFlags,
    inTimeStamp,
    inBusNumber,
    frameCount,
    ioData ) -> OSStatus in
    
    let audioObject = unsafeBitCast(inRefCon, to: MCAudioRecorder.self)
    var err: OSStatus = noErr
    
    // set mData to nil, AudioUnitRender() should be allocating buffers
    var bufferList = AudioBufferList(
      mNumberBuffers: 1,
      mBuffers: AudioBuffer(
        mNumberChannels: UInt32(2),
        mDataByteSize: 16,
        mData: nil))
    
    if let au = audioObject.audioUnit {
      err = AudioUnitRender(au,
                            ioActionFlags,
                            inTimeStamp,
                            inBusNumber,
                            frameCount,
                            &bufferList)
    }
    
    audioObject.processMicrophoneBuffer( inputDataList: &bufferList,
                                         frameCount: UInt32(frameCount) )
    return 0
  }
  
  func processMicrophoneBuffer(inputDataList : UnsafeMutablePointer<AudioBufferList>, frameCount : UInt32) {
    let inputDataPtr = UnsafeMutableAudioBufferListPointer(inputDataList)
    let mBuffers : AudioBuffer = inputDataPtr[0]
    let count = Int(frameCount)
    
    // the microphone might be recording at the wrong sample rate
    // to correct it, we compute a ratio of target sample rate over actual
    // then we do a modulo operation on the current frame number to decide
    // if we toss, keep, or duplicate the frame
    // we are doing no interpolation here
    let rateRatio: Float = Float(requestedSampleRate) / Float(deviceSampleRate)
    let bufferPointer = UnsafeMutableRawPointer(mBuffers.mData)
    if let bptr = bufferPointer {
      
      switch sampleSizeInBytes {
        case 32:
          let dataArray = bptr.assumingMemoryBound(to: Float.self)
          var finalArray = [Float]()
          for frameNumber in 0..<count {
            if rateRatio == 1 { finalArray.append(dataArray[frameNumber] ) }
            else {
              let selector = Float(frameNumber).truncatingRemainder(dividingBy: rateRatio)
              if selector > 0.1 { finalArray.append(dataArray[frameNumber] ) }
              if selector > 1 { finalArray.append(dataArray[frameNumber] ) }
            }
          }
          (delegate as? MCAudioRecorderFloatDelegate)?.buffer(finalArray)
        
        default:
          let dataArray = bptr.assumingMemoryBound(to: Int16.self)
          var finalArray = [Int16]()
          for frameNumber in 0..<count {
            if rateRatio == 1 { finalArray.append(dataArray[frameNumber] ) }
            else {
              let selector = Float(frameNumber).truncatingRemainder(dividingBy: rateRatio)
              if selector > 0.1 { finalArray.append(dataArray[frameNumber] ) }
              if selector > 1 { finalArray.append(dataArray[frameNumber] ) }
            }
          }
          (delegate as? MCAudioRecorderInt16Delegate)?.buffer(finalArray)
      }
    }
  }
  
  
  func myAudioSessionInterruptionHandler(notification: Notification) -> Void {
    let interuptionDict = notification.userInfo
    if let interuptionType = interuptionDict?[AVAudioSessionInterruptionTypeKey] {
      let interuptionVal = AVAudioSession.InterruptionType(
        rawValue: (interuptionType as AnyObject).uintValue )
      if (interuptionVal == AVAudioSession.InterruptionType.began) {
        if (isRecording) {
          stopRecording()
          isRecording = false
          let audioSession = AVAudioSession.sharedInstance()
          do {
            try audioSession.setActive(false)
            sessionActive = false
          } catch {
          }
          interrupted = true
        }
      } else if (interuptionVal == AVAudioSession.InterruptionType.ended) {
        if (interrupted) {
          // potentially restart here
        }
      }
    }
  }
}

extension MCAudioRecorder: FlutterStreamHandler {
  
  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    
    if let args = arguments as? Array<Any> {
      if args.count > 0 {
        if let eventName = args[0] as? String {
          if eventName == "on_changed" {
            self.sinkOnChanged  = events
            listeningOnChanged = true
          }
        }
      }
    }
    return nil
  }
  
  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    if let args = arguments as? Array<Any> {
      if args.count > 0 {
        if let eventName = args[0] as? String {
          if eventName == "on_changed" {
            listeningOnChanged = false
          }
        }
      }
    }
    return nil
  }
  
  public func onChanged(data: Data) {}
  
}

protocol MCAudioRecorderFloatDelegate: class {
  func buffer(_ samples: [Float])
}

protocol MCAudioRecorderInt16Delegate: class {
  func buffer(_ samples: [Int16])
}

