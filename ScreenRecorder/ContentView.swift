//
//  ContentView.swift
//  ScreenRecorder
//
//  Created by devlink on 2025/8/28.
//

import SwiftUI
import ScreenCaptureKit
import AVFoundation

struct ContentView: View {
    @StateObject private var recorder = ScreenRecorder()
    
    var body: some View {
        VStack(spacing: 20) {
            if recorder.isRecording {
                Text("正在录制中...")
                    .foregroundColor(.red)
                Button("停止录制") {
                    recorder.stopRecording()
                }
            } else {
                Button("开始录制") {
                    Task {
                        await recorder.startRecording()
                    }
                }
            }
        }
        .padding()
    }
}

#Preview {
    ContentView()
}


@MainActor
class ScreenRecorder: NSObject, ObservableObject, SCStreamDelegate {
    @Published var isRecording = false
    
    private var stream: SCStream?
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    
    private var startTime: CMTime?
    private var audioCaptureSession: AVCaptureSession?
    
    /// 开始录制
    func startRecording() async {
        do {
            // 获取可捕捉内容
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else {
                print("没有找到显示器")
                return
            }
            
            // 设置输出路径
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy_MM_dd_HH_mm_ss"
            let fileName = "屏幕录制_\(formatter.string(from: Date())).mp4"
            let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
            let fileURL = desktopURL.appendingPathComponent(fileName)
            
            // 删除旧文件
            try? FileManager.default.removeItem(at: fileURL)
            
            // 配置 AVAssetWriter
            assetWriter = try AVAssetWriter(outputURL: fileURL, fileType: .mp4)
            
            // 视频配置
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: display.width,
                AVVideoHeightKey: display.height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 6_000_000,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                ]
            ]
            videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoInput?.expectsMediaDataInRealTime = true
            
            // 像素缓冲区适配器
            if let videoInput = videoInput, let assetWriter = assetWriter {
                adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: nil)
                if assetWriter.canAdd(videoInput) {
                    assetWriter.add(videoInput)
                }
            }
            
            // 音频配置（麦克风）
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 44100,
                AVEncoderBitRateKey: 128_000
            ]
            audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioInput?.expectsMediaDataInRealTime = true
            if let audioInput = audioInput, let assetWriter = assetWriter {
                if assetWriter.canAdd(audioInput) {
                    assetWriter.add(audioInput)
                }
            }
            
            assetWriter?.startWriting()
            
            // 配置 SCStream
            let config = SCStreamConfiguration()
            config.width = display.width
            config.height = display.height
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.minimumFrameInterval = CMTime(value: 1, timescale: 60) // 30fps
            
            stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                              configuration: config,
                              delegate: self)
            
            try stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "screen.capture"))
            try await stream?.startCapture()
            
            // 启动音频捕获（麦克风）
            setupAudioCapture()
            
            isRecording = true
            print("开始录制：\(fileURL.path)")
            
        } catch {
            print("录制启动失败: \(error)")
        }
    }
    
    /// 停止录制
    func stopRecording() {
        stream?.stopCapture { error in
            if let error = error {
                print("停止录制失败: \(error)")
            }
        }
        audioCaptureSession?.stopRunning()
        
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        assetWriter?.finishWriting {
            print("录制完成")
        }
        
        stream = nil
        assetWriter = nil
        videoInput = nil
        audioInput = nil
        adaptor = nil
        startTime = nil
        audioCaptureSession = nil
        
        isRecording = false
    }
    
    /// 配置麦克风音频捕获
    private func setupAudioCapture() {
        let session = AVCaptureSession()
        guard let device = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: device) else {
            print("找不到麦克风")
            return
        }
        
        session.addInput(input)
        
        let output = AVCaptureAudioDataOutput()
        let queue = DispatchQueue(label: "audio.capture")
        output.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(output)
        
        session.startRunning()
        audioCaptureSession = session
    }
}

extension ScreenRecorder: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen,
              let pixelBuffer = sampleBuffer.imageBuffer,
              let assetWriter = assetWriter,
              let videoInput = videoInput,
              let adaptor = adaptor else { return }
        
        guard assetWriter.status == .writing || assetWriter.status == .unknown else { return }
        
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if startTime == nil {
            startTime = pts
            assetWriter.startSession(atSourceTime: pts)
        }
        
        if videoInput.isReadyForMoreMediaData {
            adaptor.append(pixelBuffer, withPresentationTime: pts)
        }
    }
}

extension ScreenRecorder: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let assetWriter = assetWriter,
              let audioInput = audioInput else { return }
        
        guard assetWriter.status == .writing || assetWriter.status == .unknown else { return }
        
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if startTime == nil {
            startTime = pts
            assetWriter.startSession(atSourceTime: pts)
        }
        
        if audioInput.isReadyForMoreMediaData {
            audioInput.append(sampleBuffer)
        }
    }
}
