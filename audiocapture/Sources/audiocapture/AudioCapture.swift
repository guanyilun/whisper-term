import AVFoundation
import CoreAudio
import Foundation

final class AudioCapture {
    private let stderrHandle = FileHandle.standardError
    private let stdoutHandle = FileHandle.standardOutput
    private let sampleRate: Int

    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var procID: AudioDeviceIOProcID?
    private var tapDescription: CATapDescription?

    init(sampleRate: Int = 16000) {
        self.sampleRate = sampleRate
    }

    func startCapture(pid: pid_t) throws {
        // 1. Translate PID to audio object ID
        var processObjectID = AudioObjectID(kAudioObjectUnknown)
        var pidVar = pid
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size), &pidVar,
            &size, &processObjectID
        )
        guard err == noErr, processObjectID != kAudioObjectUnknown else {
            throw CaptureError.pidNotFound(pid, err)
        }
        stderrHandle.write("Process audio object ID: \(processObjectID)\n".data(using: .utf8)!)

        // 2. Create process tap
        let desc = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        desc.uuid = UUID()
        desc.muteBehavior = .unmuted
        self.tapDescription = desc

        var tapIDVar = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateProcessTap(desc, &tapIDVar)
        guard err == noErr else {
            throw CaptureError.tapCreationFailed(err)
        }
        self.tapID = tapIDVar
        stderrHandle.write("Created tap: \(tapID)\n".data(using: .utf8)!)

        // 3. Get default output device UID
        let outputDeviceID = try getDefaultOutputDevice()
        let outputUID = try getDeviceUID(outputDeviceID)
        stderrHandle.write("Output device: \(outputUID)\n".data(using: .utf8)!)

        // 4. Create aggregate device with tap
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "WhisperTermTap",
            kAudioAggregateDeviceUIDKey as String: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey as String: outputUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: outputUID]
            ],
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: desc.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey as String: true
                ]
            ]
        ]

        var aggDeviceID = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggDeviceID)
        guard err == noErr else {
            throw CaptureError.aggregateDeviceFailed(err)
        }
        self.aggregateDeviceID = aggDeviceID
        stderrHandle.write("Created aggregate device: \(aggregateDeviceID)\n".data(using: .utf8)!)

        // 5. Get tap audio format
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var tapFormat = AudioStreamBasicDescription()
        var tapAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        err = AudioObjectGetPropertyData(tapID, &tapAddress, 0, nil, &formatSize, &tapFormat)
        guard err == noErr else {
            throw CaptureError.formatError(err)
        }
        stderrHandle.write("Tap format: sr=\(tapFormat.mSampleRate) ch=\(tapFormat.mChannelsPerFrame) bps=\(tapFormat.mBitsPerChannel)\n".data(using: .utf8)!)

        guard let avFormat = AVAudioFormat(streamDescription: &tapFormat) else {
            throw CaptureError.formatError(-1)
        }

        // 6. Set up IOProc to receive audio
        let outputSampleRate = Double(sampleRate)
        let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outputSampleRate, channels: 1, interleaved: false)!
        let converter = AVAudioConverter(from: avFormat, to: outputFormat)

        let capture = self
        var ioProcID: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateDeviceID, nil) {
            inNow, inInputData, inInputTime, outOutputData, inOutputTime in

            guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: avFormat,
                bufferListNoCopy: inInputData, deallocator: nil) else { return }

            if let converter = converter {
                let outputFrameCapacity = AVAudioFrameCount(
                    Double(inputBuffer.frameLength) * outputSampleRate / tapFormat.mSampleRate
                )
                guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat,
                    frameCapacity: max(outputFrameCapacity, 1)) else { return }

                var error: NSError?
                converter.convert(to: outputBuffer, error: &error) { inNumPackets, outStatus in
                    outStatus.pointee = .haveData
                    return inputBuffer
                }
                if error == nil, outputBuffer.frameLength > 0 {
                    let byteCount = Int(outputBuffer.frameLength) * MemoryLayout<Float>.size
                    let data = Data(bytes: outputBuffer.floatChannelData![0], count: byteCount)
                    capture.stdoutHandle.write(data)
                }
            } else {
                // No conversion needed — write directly
                let byteCount = Int(inputBuffer.frameLength) * Int(tapFormat.mBitsPerChannel / 8) * Int(tapFormat.mChannelsPerFrame)
                if let ptr = inInputData.pointee.mBuffers.mData {
                    let data = Data(bytes: ptr, count: byteCount)
                    capture.stdoutHandle.write(data)
                }
            }
        }
        guard err == noErr, let procID = ioProcID else {
            throw CaptureError.ioProcFailed(err)
        }
        self.procID = procID

        // 7. Start
        err = AudioDeviceStart(aggregateDeviceID, procID)
        guard err == noErr else {
            throw CaptureError.startFailed(err)
        }
        stderrHandle.write("Capturing audio (outputting 16kHz mono float32 PCM)...\nPress Ctrl+C to stop.\n".data(using: .utf8)!)
    }

    func stop() {
        if let procID = procID {
            AudioDeviceStop(aggregateDeviceID, procID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
        }
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
    }

    // MARK: - Helpers

    private func getDefaultOutputDevice() throws -> AudioObjectID {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        guard err == noErr else { throw CaptureError.noOutputDevice(err) }
        return deviceID
    }

    private func getDeviceUID(_ deviceID: AudioObjectID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let err = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid)
        guard err == noErr, let cfStr = uid?.takeRetainedValue() else {
            throw CaptureError.noOutputDevice(err)
        }
        return cfStr as String
    }
}

enum CaptureError: LocalizedError {
    case pidNotFound(pid_t, OSStatus)
    case tapCreationFailed(OSStatus)
    case aggregateDeviceFailed(OSStatus)
    case formatError(OSStatus)
    case ioProcFailed(OSStatus)
    case startFailed(OSStatus)
    case noOutputDevice(OSStatus)

    var errorDescription: String? {
        switch self {
        case .pidNotFound(let pid, let err): return "Process \(pid) not found (error \(err))"
        case .tapCreationFailed(let err): return "Failed to create process tap (error \(err))"
        case .aggregateDeviceFailed(let err): return "Failed to create aggregate device (error \(err))"
        case .formatError(let err): return "Failed to get tap audio format (error \(err))"
        case .ioProcFailed(let err): return "Failed to create IOProc (error \(err))"
        case .startFailed(let err): return "Failed to start audio capture (error \(err))"
        case .noOutputDevice(let err): return "No output device found (error \(err))"
        }
    }
}
