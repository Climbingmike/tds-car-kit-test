import UIKit
import NetworkExtension
import CoreLocation

final class ReceiverViewController: UIViewController, CLLocationManagerDelegate {
    private let receiver = NativeReceiver()
    private let bluetooth = BLEBootstrap()
    private let sameDevice = SameDeviceProbe()
    private let controlBrowser = CarPlayControlBrowser()
    private let receiverBrowser = TDSCarKitReceiverBrowser()
    private let receiverPicker = UIButton(type: .system)
    private var remoteTarget: TDSCarKitReceiverBrowser.Target?
    private let modeControl = UISegmentedControl(items: ["Receive", "This iPhone", "Send to iPad"])
    private var networkFields: [UIView] = []
    private let nameField = UITextField()
    private let ipField = UITextField()
    private let ssidField = UITextField()
    private let passwordField = UITextField()
    private let channelField = UITextField()
    private let openNetworkSwitch = UISwitch()
    private let audioSwitch = UISwitch()
    private let driveControl = UISegmentedControl(items: ["Left-hand drive", "Right-hand drive"])
    private var driveRow: UIView!
    private let networkButton = UIButton(type: .system)
    private let networkSummary = UILabel()
    private let hotspotNote = UILabel()
    private let locationManager = CLLocationManager()
    private var awaitingNetworkPermission = false
    private var fetchingNetwork = false
    private var canDetectWiFiName: Bool { (Bundle.main.object(forInfoDictionaryKey: "TDSWiFiNameDetection") as? String) == "YES" }
    private var settingsStack: UIStackView!
    private var settingsVisible = false
    private let diagnosticsButton = UIButton(type: .system)
    private var diagnosticsStack: UIStackView!
    private let orientationControl = UISegmentedControl(items: ["Landscape", "Portrait"])
    private var orientationRow: UIView!
    private let bluetoothSetupSwitch = UISwitch()
    private var bluetoothSetupRow: UIView!
    private var needsNetworkDetails: Bool { modeControl.selectedSegmentIndex != 0 || bluetoothSetupSwitch.isOn }
    private let startButton = UIButton(type: .system)
    private let heading = UILabel()
    private let explanation = UILabel()
    private let statusLabel = UILabel()
    private let connectionHelp = UILabel()
    private let logView = UITextView()
    private let videoSurface = H264Surface()
    private let fullscreenButton = UIButton(type: .system)
    private let forgetPasswordButton = UIButton(type: .system)
    private let passwordStatus = UILabel()
    private var contentStack: UIStackView!
    private var videoHeight: NSLayoutConstraint!
    private var fullscreenContainer: UIView?
    private var fullscreenConstraints: [NSLayoutConstraint] = []
    override var prefersStatusBarHidden: Bool { fullscreenContainer != nil }
    override var prefersHomeIndicatorAutoHidden: Bool { fullscreenContainer != nil }
    private var displayedVideo = false
    private var identity: AccessoryIdentity?
    private var running = false
    private var lines: [String] = []
    private var launchedTransportTest = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !running { modeChanged() }
        #if DEBUG
        if !launchedTransportTest, ProcessInfo.processInfo.arguments.contains("--test-local-transport") {
            launchedTransportTest = true
            modeControl.selectedSegmentIndex = 1; modeChanged(); toggleReceiver()
        }
        #endif
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "TDS Car Kit"
        view.backgroundColor = .systemGroupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "gearshape"), style: .plain, target: self, action: #selector(toggleSettings))
        navigationItem.rightBarButtonItem?.accessibilityLabel = "Settings"
        locationManager.delegate = self
        heading.font = .preferredFont(forTextStyle: .largeTitle)
        heading.numberOfLines = 0

        explanation.font = .preferredFont(forTextStyle: .body); explanation.textColor = .secondaryLabel; explanation.numberOfLines = 0
        [heading, explanation, statusLabel, connectionHelp, networkSummary].forEach { $0.adjustsFontForContentSizeCategory = true; $0.lineBreakMode = .byWordWrapping }
        statusLabel.font = .preferredFont(forTextStyle: .headline); statusLabel.numberOfLines = 0
        nameField.text = UserDefaults.standard.string(forKey: "receiverName") ?? "TDS Car Kit"
        ipField.text = ReceiverConfiguration.localIPv4Addresses().first
        ssidField.text = UserDefaults.standard.string(forKey: "wifiSSID")
        ssidField.addTarget(self, action: #selector(networkNameChanged), for: .editingChanged)
        ssidField.addTarget(self, action: #selector(loadWiFiPassword), for: .editingDidEnd)
        channelField.text = String(UserDefaults.standard.object(forKey: "wifiChannel") as? Int ?? 36)
        channelField.keyboardType = .numberPad
        networkFields = [field(nameField, title: "Receiver name"), field(ipField, title: "This device’s Wi-Fi IP address"),
            field(ssidField, title: "Connected Wi-Fi network name"), field(passwordField, title: "Wi-Fi password"),
            field(channelField, title: "Wi-Fi channel")]
        let openLabel = UILabel(); openLabel.text = "Open network (no password)"; openLabel.font = .preferredFont(forTextStyle: .footnote)
        let openRow = UIStackView(arrangedSubviews: [openLabel, openNetworkSwitch]); openRow.spacing = 12
        networkFields.append(openRow)
        audioSwitch.isOn = UserDefaults.standard.object(forKey: "speakerAudio") as? Bool ?? true
        let audioLabel = UILabel(); audioLabel.text = "Play audio on this device"; audioLabel.font = .preferredFont(forTextStyle: .footnote)
        let audioRow = UIStackView(arrangedSubviews: [audioLabel, audioSwitch]); audioRow.spacing = 12
        networkFields.append(audioRow)
        let bluetoothLabel = UILabel(); bluetoothLabel.text = "Bluetooth setup (experimental)"; bluetoothLabel.font = .preferredFont(forTextStyle: .footnote)
        bluetoothSetupSwitch.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        bluetoothSetupRow = UIStackView(arrangedSubviews: [bluetoothLabel, bluetoothSetupSwitch])
        (bluetoothSetupRow as? UIStackView)?.spacing = 12
        let storedMode = UserDefaults.standard.object(forKey: "connectionMode") as? Int ?? 2
        modeControl.selectedSegmentIndex = UIDevice.current.userInterfaceIdiom == .phone ? min(2, max(0, storedMode)) : 0
        modeControl.isHidden = UIDevice.current.userInterfaceIdiom == .pad
        modeControl.setEnabled(UIDevice.current.userInterfaceIdiom == .phone, forSegmentAt: 1)
        modeControl.setEnabled(UIDevice.current.userInterfaceIdiom == .phone, forSegmentAt: 2)
        if UIDevice.current.userInterfaceIdiom == .phone, UserDefaults.standard.bool(forKey: "sendToReceiver") {
            modeControl.selectedSegmentIndex = 2
        }
        modeControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        connectionHelp.font = .preferredFont(forTextStyle: .body)
        connectionHelp.textColor = .secondaryLabel; connectionHelp.numberOfLines = 0
        receiverPicker.configuration = .bordered(); receiverPicker.showsMenuAsPrimaryAction = true
        let stack = UIStackView(arrangedSubviews: [heading, explanation, statusLabel, connectionHelp, receiverPicker])
        settingsStack = UIStackView(arrangedSubviews: [modeControl, bluetoothSetupRow!] + networkFields)
        settingsStack.axis = .vertical; settingsStack.spacing = 16
        settingsStack.isLayoutMarginsRelativeArrangement = true
        settingsStack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 20, leading: 16, bottom: 20, trailing: 16)
        settingsStack.backgroundColor = .secondarySystemGroupedBackground; settingsStack.layer.cornerRadius = 20
        settingsStack.isHidden = true
        driveControl.selectedSegmentIndex = (UserDefaults.standard.object(forKey: "rightHandDrive") as? Bool ?? true) ? 1 : 0
        driveControl.addTarget(self, action: #selector(driveChanged), for: .valueChanged)
        let driveLabel = UILabel(); driveLabel.text = "Driver’s seat"
        let driveStack = UIStackView(arrangedSubviews: [driveLabel, driveControl]); driveStack.axis = .vertical; driveStack.spacing = 8
        driveRow = driveStack; settingsStack.insertArrangedSubview(driveStack, at: 1)
        networkButton.setTitle("Detect current Wi-Fi", for: .normal)
        networkButton.addTarget(self, action: #selector(detectNetwork), for: .touchUpInside)
        settingsStack.insertArrangedSubview(networkButton, at: 2)
        networkSummary.font = .preferredFont(forTextStyle: .footnote); networkSummary.textColor = .secondaryLabel; networkSummary.numberOfLines = 0
        stack.addArrangedSubview(networkSummary)
        hotspotNote.font = .preferredFont(forTextStyle: .footnote); hotspotNote.textColor = .secondaryLabel; hotspotNote.numberOfLines = 0
        hotspotNote.text = "For iPhone hotspot: enable Personal Hotspot in Settings and connect the iPad to it. Keep a Wi-Fi profile saved here for the CarPlay handshake. Hotspot passwords are managed by iOS."
        settingsStack.addArrangedSubview(hotspotNote)
        contentStack = stack
        orientationControl.selectedSegmentIndex = UserDefaults.standard.bool(forKey: "portraitDisplay") ? 1 : 0
        orientationControl.addTarget(self, action: #selector(orientationChanged), for: .valueChanged)
        let orientationLabel = UILabel(); orientationLabel.text = "CarPlay orientation"
        let orientationNote = UILabel(); orientationNote.text = "Choose before connecting. Stop and reconnect to change the CarPlay layout."; orientationNote.numberOfLines = 0
        orientationNote.font = .preferredFont(forTextStyle: .footnote); orientationNote.textColor = .secondaryLabel
        let orientationStack = UIStackView(arrangedSubviews: [orientationLabel, orientationControl, orientationNote])
        orientationStack.axis = .vertical; orientationStack.spacing = 8
        orientationRow = orientationStack; settingsStack.insertArrangedSubview(orientationStack, at: 2)
        passwordField.isSecureTextEntry = true
        ipField.keyboardType = .decimalPad
        let note = UILabel(); note.numberOfLines = 0; note.font = .preferredFont(forTextStyle: .footnote); note.textColor = .secondaryLabel
        note.text = "The Wi-Fi password is saved securely in this device’s Keychain when you start. It is never included in logs."
        settingsStack.addArrangedSubview(note)
        networkFields.append(note)
        passwordStatus.font = .preferredFont(forTextStyle: .footnote); passwordStatus.numberOfLines = 0
        passwordStatus.textColor = .secondaryLabel
        forgetPasswordButton.setTitle("Forget saved Wi-Fi password", for: .normal)
        forgetPasswordButton.addTarget(self, action: #selector(forgetWiFiPassword), for: .touchUpInside)
        settingsStack.addArrangedSubview(passwordStatus); settingsStack.addArrangedSubview(forgetPasswordButton)
        startButton.configuration = .filled(); startButton.setTitle("Start receiver", for: .normal)
        startButton.addTarget(self, action: #selector(toggleReceiver), for: .touchUpInside)
        startButton.configuration?.cornerStyle = .large
        startButton.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 18, leading: 24, bottom: 18, trailing: 24)
        stack.addArrangedSubview(startButton)
        stack.addArrangedSubview(settingsStack)
        videoSurface.isHidden = true
        videoHeight = videoSurface.heightAnchor.constraint(equalTo: videoSurface.widthAnchor, multiplier: displayAspectHeight)
        videoHeight.priority = .defaultLow
        videoHeight.isActive = true
        stack.addArrangedSubview(videoSurface)
        fullscreenButton.setTitle("Show CarPlay full screen", for: .normal)
        fullscreenButton.addTarget(self, action: #selector(showFullscreen), for: .touchUpInside)
        fullscreenButton.isHidden = true; stack.addArrangedSubview(fullscreenButton)
        logView.isEditable = false; logView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        logView.backgroundColor = .secondarySystemBackground; logView.layer.cornerRadius = 12
        logView.heightAnchor.constraint(equalToConstant: 220).isActive = true
        diagnosticsButton.setTitle("Show diagnostics", for: .normal)
        diagnosticsButton.addTarget(self, action: #selector(toggleDiagnostics), for: .touchUpInside)
        let copyButton = UIButton(type: .system); copyButton.setTitle("Copy log", for: .normal)
        copyButton.addTarget(self, action: #selector(copyLog), for: .touchUpInside)
        diagnosticsStack = UIStackView(arrangedSubviews: [logView, copyButton]); diagnosticsStack.axis = .vertical; diagnosticsStack.spacing = 8
        diagnosticsStack.isHidden = true
        settingsStack.addArrangedSubview(diagnosticsButton); settingsStack.addArrangedSubview(diagnosticsStack)
        stack.axis = .vertical; stack.spacing = 16; stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UIScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll); scroll.addSubview(stack)
        let preferredWidth = stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -48)
        preferredWidth.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.centerXAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerXAnchor),
            preferredWidth, stack.widthAnchor.constraint(lessThanOrEqualTo: scroll.frameLayoutGuide.widthAnchor, constant: -48),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 720)
        ])
        receiver.onLog = { [weak self] in self?.log($0) }; bluetooth.onLog = { [weak self] in self?.log($0) }
        receiver.onControlConnected = { [weak self] in self?.sameDevice.didConnectControl() }
        receiver.onVideo = { [weak self] data in
            guard let self, self.running else { return }
            do {
                try self.videoSurface.enqueue(accessUnit: data)
                self.videoSurface.isHidden = false
                if !self.displayedVideo {
                    self.displayedVideo = true; self.statusLabel.text = "Receiving CarPlay video"
                    self.fullscreenButton.isHidden = false
                    self.log("Video data delivered to the native display layer")
                    if UIDevice.current.userInterfaceIdiom == .pad { self.showFullscreen() }
                }
            } catch { self.log("Video display error: \(error)") }
        }
        videoSurface.onLog = { [weak self] in self?.log($0) }
        videoSurface.onTouch = { [weak self] point, down in
            self?.receiver.touch(x: UInt16(clamping: Int(point.x)), y: UInt16(clamping: Int(point.y)), down: down)
        }
        receiver.onFailure = { [weak self] in self?.stop() }
        bluetooth.onFailure = { [weak self] message in
            self?.stop()
            self?.statusLabel.text = message
        }
        bluetooth.onAdvertising = { [weak self] in
            guard let self, self.running else { return }
            self.statusLabel.text = "Bluetooth advertising · waiting for iPhone"
        }
        controlBrowser.onLog = { [weak self] in self?.log($0) }
        receiverBrowser.onLog = { [weak self] in self?.log($0) }
        receiverBrowser.onTargets = { [weak self] targets in
            guard let self, !self.running, self.modeControl.selectedSegmentIndex == 2 else { return }
            if let selected = self.remoteTarget, !targets.contains(selected) { self.remoteTarget = nil }
            self.receiverPicker.isEnabled = !targets.isEmpty
            self.receiverPicker.setTitle(self.remoteTarget.map { "\($0.name) · \($0.address)" }
                ?? (targets.isEmpty ? "Searching for iPad receivers…" : "Choose iPad receiver"), for: .normal)
            self.receiverPicker.menu = UIMenu(children: targets.map { target in
                UIAction(title: target.name, subtitle: "\(target.address):\(target.port)") { [weak self] _ in
                    self?.remoteTarget = target
                    self?.receiverPicker.setTitle("\(target.name) · \(target.address)", for: .normal)
                }
            })
        }
        sameDevice.onStage = { [weak self] message in
            guard let self else { return }
            if self.modeControl.selectedSegmentIndex == 2 {
                self.statusLabel.text = message.contains("requested")
                    ? "Connection requested · keep this app open" : "Connecting to your iPad…"
            } else { self.statusLabel.text = "Connecting CarPlay…" }
        }
        sameDevice.onLog = { [weak self] in self?.log($0) }
        sameDevice.onFinished = { [weak self] message in
            self?.stop()
            self?.statusLabel.text = message
        }
        loadIdentity()
        loadWiFiPassword()
        modeChanged()
        #if targetEnvironment(macCatalyst)
        log("Running the native UIKit target on Mac Catalyst; no external receiver process")
        #elseif targetEnvironment(simulator)
        log("Simulator: Bluetooth hardware connections are not validated here")
        #else
        log("Running native iPad/iPhone target")
        #endif
        NotificationCenter.default.addObserver(self, selector: #selector(foregrounded), name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(backgrounded), name: UIApplication.didEnterBackgroundNotification, object: nil)
    }
    private func field(_ input: UITextField, title: String) -> UIView {
        let label = UILabel(); label.text = title; label.font = .preferredFont(forTextStyle: .caption1)
        input.borderStyle = .roundedRect; input.autocorrectionType = .no; input.autocapitalizationType = .none
        let stack = UIStackView(arrangedSubviews: [label, input]); stack.axis = .vertical; stack.spacing = 5
        return stack
    }
    private var displayAspectHeight: CGFloat {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return 720.0 / 1280.0 }
        let size = view.window?.windowScene?.screen.bounds.size ?? UIScreen.main.bounds.size
        let landscape = min(size.width, size.height) / max(size.width, size.height)
        return orientationControl.selectedSegmentIndex == 1 ? 1 / landscape : landscape
    }
    private func configureDisplay(_ config: inout ReceiverConfiguration) {
        let portrait = UIDevice.current.userInterfaceIdiom == .pad && orientationControl.selectedSegmentIndex == 1
        let aspect = displayAspectHeight
        config.rightHandDrive = driveControl.selectedSegmentIndex == 1
        config.width = portrait ? Int((1280 / aspect / 16).rounded()) * 16 : 1280
        config.height = portrait ? 1280 : Int((1280 * aspect / 16).rounded()) * 16
    }
    @objc private func toggleSettings() {
        settingsVisible.toggle(); settingsStack.isHidden = !settingsVisible
        navigationItem.rightBarButtonItem?.image = UIImage(systemName: settingsVisible ? "xmark" : "gearshape")
        navigationItem.rightBarButtonItem?.accessibilityLabel = settingsVisible ? "Close settings" : "Settings"
        if !settingsVisible { view.endEditing(true) }
    }
    private func revealSettings() { if !settingsVisible { toggleSettings() } }
    @objc private func toggleDiagnostics() {
        diagnosticsStack.isHidden.toggle()
        diagnosticsButton.setTitle(diagnosticsStack.isHidden ? "Show diagnostics" : "Hide diagnostics", for: .normal)
        if !diagnosticsStack.isHidden { logView.text = lines.joined(separator: "\n") }
    }
    @objc private func driveChanged() {
        UserDefaults.standard.set(driveControl.selectedSegmentIndex == 1, forKey: "rightHandDrive")
    }
    @objc private func orientationChanged() {
        guard !running else { return }
        UserDefaults.standard.set(orientationControl.selectedSegmentIndex == 1, forKey: "portraitDisplay")
        videoHeight.isActive = false
        videoHeight = videoSurface.heightAnchor.constraint(equalTo: videoSurface.widthAnchor, multiplier: displayAspectHeight)
        videoHeight.priority = .defaultLow
        videoHeight.isActive = true
    }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        guard fullscreenContainer != nil, UIDevice.current.userInterfaceIdiom == .pad else { return .all }
        return orientationControl.selectedSegmentIndex == 1 ? .portrait : .landscape
    }
    @objc private func showFullscreen() {
        guard displayedVideo, fullscreenContainer == nil else { return }
        view.endEditing(true)
        contentStack.removeArrangedSubview(videoSurface); videoSurface.removeFromSuperview(); videoHeight.isActive = false
        let container = UIView(); container.backgroundColor = .black; container.translatesAutoresizingMaskIntoConstraints = false
        fullscreenContainer = container; view.addSubview(container); container.addSubview(videoSurface)
        videoSurface.translatesAutoresizingMaskIntoConstraints = false
        let settings = UIButton(type: .system); settings.configuration = .filled()
        settings.setImage(UIImage(systemName: "gearshape.fill"), for: .normal)
        settings.accessibilityLabel = "TDS Car Kit settings"
        settings.addTarget(self, action: #selector(showConnectionSettings), for: .touchUpInside)
        settings.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(settings)
        fullscreenConstraints = [container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor), container.topAnchor.constraint(equalTo: view.topAnchor),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor), videoSurface.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            videoSurface.trailingAnchor.constraint(equalTo: container.trailingAnchor), videoSurface.topAnchor.constraint(equalTo: container.topAnchor),
            videoSurface.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            settings.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 8),
            settings.trailingAnchor.constraint(equalTo: container.safeAreaLayoutGuide.trailingAnchor, constant: -8)]
        NSLayoutConstraint.activate(fullscreenConstraints)
        navigationController?.setNavigationBarHidden(true, animated: false)
        setNeedsStatusBarAppearanceUpdate(); setNeedsUpdateOfHomeIndicatorAutoHidden()
        if UIDevice.current.userInterfaceIdiom == .pad {
            setNeedsUpdateOfSupportedInterfaceOrientations()
            view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: supportedInterfaceOrientations)) { [weak self] _ in
                self?.log("Rotate the iPad to the selected orientation for the full-screen display")
            }
        }
    }
    @objc private func showConnectionSettings() { hideFullscreen(); revealSettings() }
    @objc private func hideFullscreen() {
        guard let container = fullscreenContainer else { return }
        NSLayoutConstraint.deactivate(fullscreenConstraints); fullscreenConstraints = []
        videoSurface.removeFromSuperview(); container.removeFromSuperview(); fullscreenContainer = nil
        let index = contentStack.arrangedSubviews.firstIndex(of: fullscreenButton) ?? contentStack.arrangedSubviews.count
        contentStack.insertArrangedSubview(videoSurface, at: index); videoHeight.isActive = true
        navigationController?.setNavigationBarHidden(false, animated: false)
        setNeedsUpdateOfSupportedInterfaceOrientations()
        setNeedsStatusBarAppearanceUpdate(); setNeedsUpdateOfHomeIndicatorAutoHidden()
    }
    @objc private func networkNameChanged() {
        passwordField.text = ""; openNetworkSwitch.isOn = false; passwordStatus.text = ""
        refreshNetworkSummary()
    }
    @objc private func loadWiFiPassword() {
        do {
            if let saved = try WiFiCredentials.password(for: ssidField.text ?? "") {
                passwordField.text = saved; openNetworkSwitch.isOn = saved.isEmpty
                passwordStatus.text = "Saved Wi-Fi details loaded from Keychain"
            }
        } catch { passwordStatus.text = "Could not read saved Wi-Fi password. Enter it below." }
    }
    private func refreshNetworkSummary() {
        if UIDevice.current.userInterfaceIdiom == .phone, ReceiverConfiguration.personalHotspotAddress() != nil {
            let saved = !(ssidField.text ?? "").isEmpty && (!(passwordField.text ?? "").isEmpty || openNetworkSwitch.isOn)
            networkSummary.text = saved ? "Personal Hotspot detected · saved CarPlay profile ready" : "Personal Hotspot detected · save a Wi-Fi profile in Settings first"
        } else if needsNetworkDetails, let ssid = ssidField.text, !ssid.isEmpty {
            networkSummary.text = "CarPlay network: \(ssid)"
        } else { networkSummary.text = "Your iPhone will find this display as “\(nameField.text ?? "TDS Car Kit")”." }
    }
    @objc private func detectNetwork() { refreshCurrentNetwork(requestPermission: true) }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard awaitingNetworkPermission else { return }
        awaitingNetworkPermission = false
        refreshCurrentNetwork(requestPermission: false)
    }
    private func refreshCurrentNetwork(requestPermission: Bool) {
        guard canDetectWiFiName, !running, !fetchingNetwork, needsNetworkDetails else { return }
        if UIDevice.current.userInterfaceIdiom == .phone, ReceiverConfiguration.personalHotspotAddress() != nil {
            loadWiFiPassword(); refreshNetworkSummary(); return
        }
        let authorization = locationManager.authorizationStatus
        if authorization == .notDetermined, requestPermission {
            awaitingNetworkPermission = true; locationManager.requestWhenInUseAuthorization(); return
        }
        guard authorization == .authorizedWhenInUse || authorization == .authorizedAlways else {
            if requestPermission { networkSummary.text = "Allow Location access in Settings to detect Wi-Fi, or enter the network manually." }
            return
        }
        fetchingNetwork = true
        let previousSSID = ssidField.text
        NEHotspotNetwork.fetchCurrent { [weak self] network in
            DispatchQueue.main.async {
                guard let self else { return }; self.fetchingNetwork = false
                guard !self.running, self.ssidField.text == previousSSID else { return }
                guard let network else {
                    if requestPermission { self.networkSummary.text = "Wi-Fi name unavailable. Keep the saved profile or enter it manually." }
                    return
                }
                if self.ssidField.text != network.ssid {
                    self.ssidField.text = network.ssid; self.networkNameChanged(); self.loadWiFiPassword()
                }
                self.refreshNetworkSummary()
            }
        }
    }
    @objc private func forgetWiFiPassword() {
        do {
            try WiFiCredentials.forget(ssidField.text ?? ""); passwordField.text = ""
            passwordStatus.text = "Saved password removed from this device"
        } catch { passwordStatus.text = "Could not remove the saved password." }
    }
    private func saveSettings(_ config: ReceiverConfiguration) -> Bool {
        do { if needsNetworkDetails { try WiFiCredentials.save(config.password, for: config.ssid) } }
        catch { statusLabel.text = "Could not save the Wi-Fi password securely. Please retry."; return false }
        if needsNetworkDetails {
            passwordStatus.text = "Wi-Fi password saved in Keychain"
            UserDefaults.standard.set(config.ssid, forKey: "wifiSSID")
            UserDefaults.standard.set(Int(config.wifiChannel), forKey: "wifiChannel")
        }
        UserDefaults.standard.set(audioSwitch.isOn, forKey: "speakerAudio")
        if modeControl.selectedSegmentIndex != 2 { UserDefaults.standard.set(config.name, forKey: "receiverName") }
        return true
    }
    private func loadIdentity() {
        do {
            guard let folder = Bundle.main.resourceURL?.appendingPathComponent("Identity") else { return }
            identity = try AccessoryIdentity(certificateChain: Data(contentsOf: folder.appendingPathComponent("certificate.p7b")),
                leafCertificate: Data(contentsOf: folder.appendingPathComponent("leaf.cer")),
                privateKeyX963: Data(contentsOf: folder.appendingPathComponent("private.x963")))
            statusLabel.text = "Ready to connect"
            log("Certificate and private key match; ECDSA challenge self-test passed")
        } catch {
            statusLabel.text = "Local identity missing or invalid"; startButton.isEnabled = false
            log("Add accessory authentication files to .local/Identity before building. Identity error: \(error.localizedDescription)")
        }
    }
    @objc private func toggleReceiver() {
        if running { stop(); return }
        if !running, modeControl.selectedSegmentIndex != 2 {
            ipField.text = ReceiverConfiguration.personalHotspotAddress() ?? ReceiverConfiguration.localIPv4Addresses().first
        }
        guard let channel = needsNetworkDetails ? UInt8(channelField.text ?? "") : UInt8(36), (1...196).contains(channel) else {
            revealSettings(); statusLabel.text = "Enter a Wi-Fi channel between 1 and 196."; return
        }
        guard !needsNetworkDetails || openNetworkSwitch.isOn || !(passwordField.text ?? "").isEmpty else {
            statusLabel.text = "Enter the Wi-Fi password, or select Open network if it has no password."
            revealSettings(); passwordField.becomeFirstResponder(); return
        }
        let password = !needsNetworkDetails || openNetworkSwitch.isOn ? "" : (passwordField.text ?? "")
        if modeControl.selectedSegmentIndex == 2 {
            guard let identity, let target = remoteTarget else {
                statusLabel.text = "Choose the iPad receiver first. Keep both devices on the same Wi-Fi."; return
            }
            let config = ReceiverConfiguration(name: target.name, address: target.address,
                ssid: ssidField.text ?? "", password: password, port: target.port,
                wifiChannel: channel, audioEnabled: false, deviceID: target.deviceID)
            do { try config.validate(requiresLocalAddress: false) } catch {
                revealSettings(); statusLabel.text = error.localizedDescription; return
            }
            guard saveSettings(config) else { return }
            view.endEditing(true); running = true; modeControl.isEnabled = false; setEditing(false)
            receiverPicker.isEnabled = false; receiverBrowser.stop()
            UIApplication.shared.isIdleTimerDisabled = true
            startButton.setTitle("Stop iPad connection", for: .normal)
            log("Requesting this iPhone’s CarPlay on \(target.name) at \(target.address):\(target.port)")
            sameDevice.start(configuration: config, identity: identity, expectsLocalControl: false)
            return
        }
        if modeControl.selectedSegmentIndex == 1 {
            guard let identity else { return }
            var config = ReceiverConfiguration(name: nameField.text ?? "TDS Car Kit", address: ReceiverConfiguration.personalHotspotAddress() ?? ReceiverConfiguration.localIPv4Addresses().first ?? "127.0.0.1",
                ssid: ssidField.text ?? "", password: password, wifiChannel: channel, audioEnabled: audioSwitch.isOn,
                deviceID: ReceiverConfiguration.persistentDeviceID())
            configureDisplay(&config)
            do { try config.validate() } catch {
                revealSettings(); statusLabel.text = error.localizedDescription; return
            }
            guard saveSettings(config) else { return }
            view.endEditing(true)
            running = true; modeControl.isEnabled = false; setEditing(false)
            startButton.setTitle("Stop receiver", for: .normal)
            statusLabel.text = "Starting local CarPlay receiver…"
            UIApplication.shared.isIdleTimerDisabled = true
            receiver.onListening = { [weak self] port in
                guard let self, self.running else { return }
                var live = config; live.port = port
                self.controlBrowser.start()
                self.sameDevice.start(configuration: live, identity: identity)
            }
            receiver.start(configuration: config, identity: identity)
            return
        }
        guard let identity else { return }
        var config = ReceiverConfiguration(name: nameField.text ?? "TDS Car Kit", address: ipField.text ?? "",
            ssid: ssidField.text ?? "", password: password, wifiChannel: channel, audioEnabled: audioSwitch.isOn, deviceID: ReceiverConfiguration.persistentDeviceID())
        configureDisplay(&config)
        do { try config.validate(requiresWiFiCredentials: needsNetworkDetails) } catch {
            statusLabel.text = error.localizedDescription
            log("Cannot start: \(error.localizedDescription)")
            revealSettings(); if config.ssid.isEmpty { ssidField.becomeFirstResponder() }
            return
        }
        guard saveSettings(config) else { return }
        view.endEditing(true)
        running = true; modeControl.isEnabled = false; setEditing(false); startButton.setTitle("Stop receiver", for: .normal)
        UIApplication.shared.isIdleTimerDisabled = true; statusLabel.text = "Starting native listener…"
        receiver.onListening = { [weak self] port in
            guard let self, self.running else { return }
            var live = config; live.port = port
            self.statusLabel.text = "Waiting for your iPhone"
            if self.bluetoothSetupSwitch.isOn { self.bluetooth.start(configuration: live) }
        }
        receiver.start(configuration: config, identity: identity)
    }
    private func stop() {
        hideFullscreen(); fullscreenButton.isHidden = true
        displayedVideo = false; videoSurface.reset(); videoSurface.isHidden = true
        running = false; receiver.onListening = nil; bluetooth.stop(); sameDevice.stop(); controlBrowser.stop(); receiver.stop()
        receiverBrowser.stop()
        modeControl.isEnabled = true
        UIApplication.shared.isIdleTimerDisabled = false; setEditing(true)
        modeChanged()
        statusLabel.text = identity == nil ? "Setup required" : "Disconnected"
        log("Receiver stopped")
    }
    @objc private func modeChanged() {
        UserDefaults.standard.set(modeControl.selectedSegmentIndex, forKey: "connectionMode")
        let local = modeControl.selectedSegmentIndex == 1
        let remote = modeControl.selectedSegmentIndex == 2
        receiverBrowser.stop(); remoteTarget = nil
        receiverPicker.isHidden = !remote
        if remote {
            receiverPicker.menu = nil; receiverPicker.isEnabled = false
            receiverPicker.setTitle("Searching for iPad receivers…", for: .normal)
            receiverBrowser.start()
        }
        heading.text = remote ? "Connect to iPad" : local ? "CarPlay on this iPhone" : "Your CarPlay display"
        explanation.text = remote ? "Choose your iPad and send CarPlay to its screen."
            : local ? "Display CarPlay on this device." : "Navigation, music and touch control from your iPhone."
        connectionHelp.text = remote
            ? "Use the same Wi-Fi, or connect the iPad to this iPhone’s Personal Hotspot."
            : local ? "Start CarPlay on this iPhone. Keep the app open while connected."
            : "Start the display here, then open TDS Car Kit on your iPhone to connect."
        driveRow.isHidden = remote
        hotspotNote.isHidden = !needsNetworkDetails
        networkButton.isHidden = !needsNetworkDetails || !canDetectWiFiName
        refreshNetworkSummary()
        orientationRow.isHidden = remote || UIDevice.current.userInterfaceIdiom != .pad
        bluetoothSetupRow.isHidden = local || remote
        networkFields.enumerated().forEach { index, field in
            field.isHidden = ((local || remote) && index < 2) || (remote && index == 6)
                || (!needsNetworkDetails && ((2...5).contains(index) || index == 7))
        }
        passwordStatus.isHidden = !needsNetworkDetails; forgetPasswordButton.isHidden = !needsNetworkDetails
        startButton.isEnabled = identity != nil
        startButton.setTitle(remote ? "Connect to iPad" : local ? "Start on this iPhone" : "Start CarPlay display", for: .normal)
        statusLabel.text = identity == nil ? "Setup required" : remote ? "Choose your display" : "Ready"
        refreshCurrentNetwork(requestPermission: false)
    }
    private func setEditing(_ value: Bool) {
        [nameField, ipField, ssidField, passwordField, channelField].forEach { $0.isEnabled = value }
        openNetworkSwitch.isEnabled = value
        audioSwitch.isEnabled = value
        orientationControl.isEnabled = value
        driveControl.isEnabled = value
        networkButton.isEnabled = value
        bluetoothSetupSwitch.isEnabled = value
        forgetPasswordButton.isEnabled = value
    }
    @objc private func foregrounded() {
        guard !running else { return }
        ipField.text = ReceiverConfiguration.personalHotspotAddress() ?? ReceiverConfiguration.localIPv4Addresses().first
        modeChanged()
    }
    @objc private func backgrounded() { if running { stop() }; receiverBrowser.stop() }
    @objc private func copyLog() { UIPasteboard.general.string = lines.joined(separator: "\n") }
    private func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        lines.append("\(timestamp)  \(message)"); if lines.count > 200 { lines.removeFirst(lines.count - 200) }
        if diagnosticsStack != nil, !diagnosticsStack.isHidden, settingsVisible { logView.text = lines.joined(separator: "\n") }
        if diagnosticsStack != nil, !diagnosticsStack.isHidden, settingsVisible, !logView.text.isEmpty { logView.scrollRangeToVisible(NSRange(location: logView.text.utf16.count - 1, length: 1)) }
        NSLog("[TDSCarKit] %@", message)
    }
}
