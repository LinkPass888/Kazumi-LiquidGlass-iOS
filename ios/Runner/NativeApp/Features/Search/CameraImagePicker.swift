//
//  CameraImagePicker.swift
//  Kazumi
//
//  对应原版 image_picker 的 ImageSource.camera：UIKit 没有 SwiftUI 原生拍照控件，
//  这里用 UIImagePickerController 包一层。仅在真机可用，模拟器上按钮不会出现。
//

import SwiftUI
import UIKit

struct CameraImagePicker: UIViewControllerRepresentable {
    var onPicked: (PickedImage) -> Void

    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPicked: onPicked, onCancel: { dismiss() })
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onPicked: (PickedImage) -> Void
        private let onCancel: () -> Void

        init(onPicked: @escaping (PickedImage) -> Void, onCancel: @escaping () -> Void) {
            self.onPicked = onPicked
            self.onCancel = onCancel
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            let image = info[.originalImage] as? UIImage
            onCancel()
            if let image {
                onPicked(PickedImage(image: image, fileName: "camera"))
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }
    }
}
