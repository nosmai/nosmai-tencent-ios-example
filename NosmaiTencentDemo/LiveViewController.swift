import UIKit
import AVFoundation
import TXLiteAVSDK_TRTC

/// Host:     Nosmai owns the camera -> filtered CVPixelBuffers -> Tencent RTC custom video capture.
/// Audience: plain Tencent RTC viewer rendering the host's stream.
final class LiveViewController: UIViewController {
    enum Role { case host, audience }

    private let role: Role
    private let config: DemoConfig
    private let userID: String
    private let userSig: String
    private var isHost: Bool { role == .host }

    private var trtc: TRTCCloud?
    /// Audience: the host whose video is currently on screen.
    private var watchedUserID: String?
    private let frameQueue = DispatchQueue(label: "com.nosmai.tencent.demo.frames")
    private var cameraRunning = false
    private var stopped = false
    /// Read from Nosmai's processing thread and the frame queue.
    private let pushLock = NSLock()
    private var _pushing = false
    private var pushing: Bool {
        get { pushLock.lock(); defer { pushLock.unlock() }; return _pushing }
        set { pushLock.lock(); _pushing = newValue; pushLock.unlock() }
    }

    private var liveStatus = "Preparing…"
    private var toastToken = 0

    private let videoView = UIView()
    private let statusLabel = PaddedLabel()
    private let fpsLabel = PaddedLabel()
    /// Host: frames handed to Tencent RTC since the last tick. Guarded by pushLock.
    private var framesSinceTick = 0
    private var fpsTimer: Timer?
    private let controls = UIStackView()
    private let effectsPanel = EffectsPanelView()

    init(role: Role, config: DemoConfig, userID: String, userSig: String) {
        self.role = role
        self.config = config
        self.userID = userID
        self.userSig = userSig
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = isHost ? "Live" : "Watching"
        view.backgroundColor = .black
        buildUI()
        setUpTencent()
        if isHost {
            requestPermissions { [weak self] in self?.startNosmaiCamera() }
        } else {
            enterRoom()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        UIApplication.shared.isIdleTimerDisabled = true
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        UIApplication.shared.isIdleTimerDisabled = false
        if isMovingFromParent || isBeingDismissed { stopSession() }
    }

    // MARK: - UI

    private func buildUI() {
        videoView.backgroundColor = .black
        videoView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(videoView)

        statusLabel.text = "Preparing…"
        statusLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        statusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        statusLabel.layer.cornerRadius = 10
        statusLabel.clipsToBounds = true
        statusLabel.numberOfLines = 2
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        fpsLabel.text = "-- FPS"
        fpsLabel.textColor = .systemGreen
        fpsLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .bold)
        fpsLabel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        fpsLabel.layer.cornerRadius = 10
        fpsLabel.clipsToBounds = true
        fpsLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(fpsLabel)

        controls.axis = .vertical
        controls.spacing = 10
        controls.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controls)

        if isHost {
            effectsPanel.onStatus = { [weak self] text in self?.showToast(text) }
            controls.addArrangedSubview(effectsPanel)
        }

        let buttons = UIStackView()
        buttons.axis = .horizontal
        buttons.spacing = 12
        buttons.distribution = .fillEqually
        if isHost {
            buttons.addArrangedSubview(makeButton(title: "Flip", color: .darkGray, action: #selector(flipCamera)))
            buttons.addArrangedSubview(makeButton(title: "Effects", color: .systemPink, action: #selector(toggleEffects)))
        }
        buttons.addArrangedSubview(makeButton(title: isHost ? "End Live" : "Leave", color: .systemRed, action: #selector(close)))
        buttons.heightAnchor.constraint(equalToConstant: 48).isActive = true
        controls.addArrangedSubview(buttons)

        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            videoView.topAnchor.constraint(equalTo: view.topAnchor),
            videoView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            videoView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            statusLabel.topAnchor.constraint(equalTo: safe.topAnchor, constant: 10),
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            fpsLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 6),
            fpsLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),

            controls.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            controls.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            controls.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -12),
        ])
    }

    private func makeButton(title: String, color: UIColor, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        button.backgroundColor = color
        button.layer.cornerRadius = 12
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    private func setStatus(_ text: String) {
        DispatchQueue.main.async {
            self.liveStatus = text
            self.statusLabel.text = text
        }
    }

    /// Briefly shows effect feedback in the status pill, then restores the live status.
    private func showToast(_ text: String) {
        toastToken += 1
        let token = toastToken
        statusLabel.text = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, self.toastToken == token else { return }
            self.statusLabel.text = self.liveStatus
        }
    }

    // MARK: - Tencent RTC

    private func setUpTencent() {
        TRTCCloud.setConsoleEnabled(false)
        TRTCCloud.setLogLevel(.none)
        let trtc = TRTCCloud.sharedInstance()
        trtc.addDelegate(self)
        if isHost {
            // Nosmai owns the camera, so Tencent RTC must take frames from us.
            trtc.enableCustomVideoCapture(.big, enable: true)

            let encoder = TRTCVideoEncParam()
            encoder.videoResolution = ._1280_720
            encoder.resMode = .portrait
            encoder.videoFps = 30
            encoder.videoBitrate = 1800
            trtc.setVideoEncoderParam(encoder)
        }
        self.trtc = trtc
    }

    private func enterRoom() {
        guard let trtc else { return }
        let params = TRTCParams()
        params.sdkAppId = config.tencentSDKAppID
        params.userId = userID
        params.userSig = userSig
        params.strRoomId = config.roomID
        params.role = isHost ? .anchor : .audience
        trtc.enterRoom(params, appScene: .LIVE)
        if isHost { trtc.startLocalAudio(.default) }
        setStatus("Joining \(config.roomID)…")
    }

    // MARK: - Nosmai (host only)

    private func requestPermissions(then start: @escaping () -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] camera in
            guard camera else { self?.setStatus("Camera permission denied"); return }
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] mic in
                guard mic else { self?.setStatus("Microphone permission denied"); return }
                DispatchQueue.main.async(execute: start)
            }
        }
    }

    private func startNosmaiCamera() {
        guard !stopped else { return }
        setStatus("Starting Nosmai…")
        NosmaiCore.shared().initialize(withAPIKey: config.nosmaiAPIKey) { [weak self] success, error in
            DispatchQueue.main.async {
                guard let self, !self.stopped else { return }
                guard success else {
                    self.setStatus("Nosmai init failed: \(error?.localizedDescription ?? "unknown")")
                    return
                }
                guard let camera = NosmaiCore.shared().camera else {
                    self.setStatus("Nosmai camera unavailable")
                    return
                }
                let cameraConfig = NosmaiCameraConfig()
                cameraConfig.position = .front
                cameraConfig.sessionPreset = AVCaptureSession.Preset.hd1280x720.rawValue
                cameraConfig.frameRate = 30
                camera.updateConfiguration(cameraConfig)
                camera.attach(to: self.videoView)

                guard camera.startCapture() else {
                    self.setStatus("Nosmai camera failed to start")
                    return
                }
                // Required for beauty / filters to render.
                NosmaiSDK.sharedInstance()?.startProcessing()
                self.cameraRunning = true
                self.effectsPanel.nosmaiReady()
                self.enterRoom()
            }
        }
    }

    /// Forward every filtered frame from Nosmai to Tencent RTC.
    private func startPushingFrames() {
        guard cameraRunning, !pushing, !stopped else { return }
        pushing = true
        // Host FPS = filtered frames Nosmai actually delivers to Tencent RTC each second.
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.pushLock.lock()
            let frames = self.framesSinceTick
            self.framesSinceTick = 0
            self.pushLock.unlock()
            self.fpsLabel.text = "\(frames) FPS"
        }
        NosmaiCore.shared().liveFrameStreamCallback = { [weak self] pixelBuffer, timestamp in
            guard let self, self.pushing else { return }
            self.pushLock.lock()
            self.framesSinceTick += 1
            self.pushLock.unlock()
            // Swift retains the buffer for the lifetime of the closure below.
            self.frameQueue.async {
                guard self.pushing, let trtc = self.trtc else { return }
                let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
                let frame = TRTCVideoFrame()
                frame.pixelFormat = format == kCVPixelFormatType_32BGRA ? ._32BGRA : ._NV12
                frame.bufferType = .pixelBuffer
                frame.pixelBuffer = pixelBuffer
                frame.timestamp = 0 // let the SDK timestamp the frame with its own clock
                trtc.sendCustomVideoData(.big, frame: frame)
            }
        }
    }

    // MARK: - Actions

    @objc private func toggleEffects() {
        UIView.animate(withDuration: 0.2) {
            self.effectsPanel.isHidden.toggle()
            self.effectsPanel.alpha = self.effectsPanel.isHidden ? 0 : 1
        }
    }

    private func stopPushingFrames() {
        pushing = false
        fpsTimer?.invalidate()
        fpsTimer = nil
    }

    @objc private func flipCamera() {
        guard cameraRunning else { return }
        _ = NosmaiCore.shared().camera?.switch()
    }

    @objc private func close() {
        navigationController?.popViewController(animated: true)
    }

    private func stopSession() {
        guard !stopped else { return }
        stopped = true
        stopPushingFrames()
        if isHost {
            NosmaiCore.shared().liveFrameStreamCallback = nil
            frameQueue.sync {} // drain frames already queued before leaving the room
            trtc?.stopLocalAudio()
            trtc?.enableCustomVideoCapture(.big, enable: false)
        } else if let watchedUserID {
            trtc?.stopRemoteView(watchedUserID, streamType: .big)
        }
        trtc?.exitRoom()
        trtc?.removeDelegate(self)
        trtc = nil
        TRTCCloud.destroySharedInstance()

        if cameraRunning {
            cameraRunning = false
            let core = NosmaiCore.shared()
            core.effects?.clearAll() // the SDK is a singleton; don't leak effects into the next session
            core.camera?.stopCapture()
            core.camera?.detachFromView()
            core.cleanup()
        }
    }
}

// MARK: - TRTCCloudDelegate

extension LiveViewController: TRTCCloudDelegate {
    /// `result` is the time taken to enter in ms, or a negative error code.
    func onEnterRoom(_ result: Int) {
        guard result > 0 else {
            setStatus("Tencent RTC enter failed (\(result)) — check the app ID, user ID and UserSig")
            return
        }
        if isHost {
            setStatus("Live in \(config.roomID)")
            startPushingFrames()
        } else if watchedUserID == nil {
            setStatus("Connected — waiting for host")
        }
    }

    /// Audience: the host started or stopped publishing video.
    func onUserVideoAvailable(_ userId: String, available: Bool) {
        guard !isHost, let trtc else { return }
        if available, watchedUserID == nil {
            let render = TRTCRenderParams()
            render.fillMode = .fill
            trtc.setRemoteRenderParams(userId, streamType: .big, params: render)
            trtc.startRemoteView(userId, streamType: .big, view: videoView)
            watchedUserID = userId
            setStatus("Watching host")
        } else if !available, watchedUserID == userId {
            trtc.stopRemoteView(userId, streamType: .big)
            watchedUserID = nil
            fpsLabel.text = "-- FPS"
            setStatus("Host left the stream")
        }
    }

    /// Audience FPS = frame rate of the host's video as received (reported every 2s).
    func onStatistics(_ statistics: TRTCStatistics) {
        guard !isHost, let watchedUserID,
              let remote = statistics.remoteStatistics.first(where: { $0.userId == watchedUserID }) else { return }
        fpsLabel.text = "\(remote.frameRate) FPS"
    }

    func onError(_ errCode: TXLiteAVError, errMsg: String?, extInfo: [AnyHashable: Any]?) {
        setStatus("Tencent RTC error \(errCode.rawValue): \(errMsg ?? "")")
    }

    func onConnectionLost() {
        setStatus("Reconnecting…")
    }

    func onConnectionRecovery() {
        if isHost {
            setStatus("Live in \(config.roomID)")
        } else {
            setStatus(watchedUserID == nil ? "Connected — waiting for host" : "Watching host")
        }
    }
}

private final class PaddedLabel: UILabel {
    private let insets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + insets.left + insets.right,
                      height: size.height + insets.top + insets.bottom)
    }
}
