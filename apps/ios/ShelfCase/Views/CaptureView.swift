import SwiftUI
import SwiftData
import ShelfCaseKit

#if os(iOS)
import AVFoundation
import UIKit
#endif
#if canImport(PhotosUI)
import PhotosUI
#endif

/// Capture a photo of a new collectible.
///
/// On a device this opens an `AVCaptureSession` preview; in the Simulator (which
/// has no camera) it falls back to `PhotosPicker`. Either path ends in
/// `LocalImageStore.save`, which returns the relative path stored on the item.
struct CaptureView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var title = ""
    @State private var setName = ""
    @State private var category: ItemCategory = .card
    @State private var grade: ConditionGrade = .nearMint
    @State private var purchasePrice = ""
    @State private var estimatedValue = ""
    @State private var notes = ""
    @State private var image: PlatformImage?
    @State private var imagePath: String?
    @State private var photoItem: Any?
    @State private var errorMessage: String?
    @State private var showingCamera = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Photo") {
                    HStack {
                        Spacer()
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.secondary.opacity(0.12))
                                .frame(width: 200, height: 200)
                            if let image {
                                Image(platformImage: image)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 200, height: 200)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            } else {
                                Image(systemName: "camera")
                                    .font(.system(size: 44))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                    }
                    .listRowBackground(Color.clear)

                    captureButtons
                }

                Section("Details") {
                    TextField("Title", text: $title)
                        .textInputAutocapitalization(.words)
                    TextField("Set / series", text: $setName)
                    Picker("Category", selection: $category) {
                        ForEach(ItemCategory.allCases, id: \.self) { value in
                            Text(value.rawValue.capitalized).tag(value)
                        }
                    }
                    Picker("Grade", selection: $grade) {
                        ForEach(ConditionGrade.allCases.sorted { $0.rank > $1.rank }, id: \.self) { value in
                            Text(value.displayName).tag(value)
                        }
                    }
                }

                Section("Money") {
                    TextField("Purchase price (cents)", text: $purchasePrice)
                        .keyboardType(.numberPad)
                    TextField("Estimated value (cents)", text: $estimatedValue)
                        .keyboardType(.numberPad)
                }

                Section("Notes") {
                    TextField("Condition notes", text: $notes, axis: .vertical)
                        .lineLimit(3...8)
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("Catalogue item")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .sheet(isPresented: $showingCamera) {
                #if os(iOS)
                CameraPicker { captured in
                    apply(image: captured)
                }
                .ignoresSafeArea()
                #endif
            }
        }
    }

    @ViewBuilder
    private var captureButtons: some View {
        #if os(iOS)
        Button {
            if CameraPicker.isAvailable {
                showingCamera = true
            }
        } label: {
            Label(
                CameraPicker.isAvailable ? "Take photo" : "Camera unavailable in Simulator",
                systemImage: "camera.fill")
        }
        .disabled(!CameraPicker.isAvailable)
        #endif

        #if canImport(PhotosUI)
        PhotosPicker(selection: photosPickerSelection, matching: .images) {
            Label("Choose from library", systemImage: "photo.on.rectangle")
        }
        #endif
    }

    #if canImport(PhotosUI)
    private var photosPickerSelection: Binding<PhotosPickerItem?> {
        Binding<PhotosPickerItem?>(
            get: { photoItem as? PhotosPickerItem },
            set: { newValue in
                photoItem = newValue
                guard let newValue else { return }
                Task { await load(pickerItem: newValue) }
            }
        )
    }

    private func load(pickerItem: PhotosPickerItem) async {
        guard let data = try? await pickerItem.loadTransferable(type: Data.self) else {
            errorMessage = "That image could not be read."
            return
        }
        #if canImport(UIKit)
        if let decoded = UIImage(data: data) { apply(image: decoded) }
        #elseif canImport(AppKit)
        if let decoded = NSImage(data: data) { apply(image: decoded) }
        #endif
    }
    #else
    private var photosPickerSelection: Binding<Any?> { .constant(nil) }
    #endif

    private func apply(image newImage: PlatformImage) {
        image = newImage
        // Write eagerly so a save that fails on disk fails visibly, while the
        // user is still on the capture screen.
        do {
            imagePath = try LocalImageStore.save(image: newImage)
            errorMessage = nil
        } catch {
            imagePath = nil
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            Task {
                await Telemetry.shared.record(
                    TelemetryEvent(
                        name: "capture.image_write_failed",
                        errorMessage: error.localizedDescription
                    ))
            }
        }
    }

    private func save() {
        let item = CollectibleItem(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            setName: setName.trimmingCharacters(in: .whitespacesAndNewlines),
            category: category,
            conditionGrade: grade,
            purchasePriceCents: Int(purchasePrice) ?? 0,
            estimatedValueCents: Int(estimatedValue) ?? 0,
            acquiredAt: Date(),
            notes: notes,
            imageLocalPath: imagePath,
            updatedAt: Date(),
            version: 1,
            syncState: .pendingCreate
        )

        modelContext.insert(ItemEntity(domain: item))
        try? modelContext.save()

        Task {
            await environment.refreshPendingCount()
            await environment.syncNow()
        }
        dismiss()
    }
}

extension Image {
    init(platformImage: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: platformImage)
        #elseif canImport(AppKit)
        self.init(nsImage: platformImage)
        #else
        self.init(systemName: "photo")
        #endif
    }
}

#if os(iOS)
/// Minimal `AVCaptureSession` wrapper. `isAvailable` is false in the Simulator,
/// which is why the UI falls back to `PhotosPicker`.
struct CameraPicker: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    static var isAvailable: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return AVCaptureDevice.default(for: .video) != nil
        #endif
    }

    func makeUIViewController(context: Context) -> CameraViewController {
        let controller = CameraViewController()
        controller.onCapture = { image in
            onCapture(image)
            dismiss()
        }
        controller.onCancel = { dismiss() }
        return controller
    }

    func updateUIViewController(_ uiViewController: CameraViewController, context: Context) {}
}

final class CameraViewController: UIViewController, AVCapturePhotoCaptureDelegate {
    var onCapture: ((UIImage) -> Void)?
    var onCancel: (() -> Void)?

    private let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private var previewLayer: AVCaptureVideoPreviewLayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()

        let cancel = UIButton(type: .system)
        cancel.setTitle("Cancel", for: .normal)
        cancel.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        cancel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cancel)

        let shutter = UIButton(type: .system)
        shutter.setTitle("Capture", for: .normal)
        shutter.addTarget(self, action: #selector(captureTapped), for: .touchUpInside)
        shutter.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(shutter)

        NSLayoutConstraint.activate([
            cancel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            cancel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            shutter.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            shutter.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.session.startRunning()
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning { session.stopRunning() }
    }

    private func configureSession() {
        guard let device = AVCaptureDevice.default(for: .video),
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input), session.canAddOutput(output)
        else { return }
        session.beginConfiguration()
        session.sessionPreset = .photo
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        previewLayer = layer
    }

    @objc private func captureTapped() {
        output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
    }

    @objc private func cancelTapped() {
        onCancel?()
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        guard error == nil, let data = photo.fileDataRepresentation(), let image = UIImage(data: data) else {
            return
        }
        onCapture?(image)
    }
}
#endif
