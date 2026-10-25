//
//  ScanPhotoButton.swift
//  Donguri
//
//  Read text from a photo or screenshot (OCR) and look words up in it, as
//  MaruReader's photo scanner does: pick an image, or use the one on the
//  clipboard, and it opens in the gallery with text recognition on.
//

import SwiftUI
import PhotosUI

struct ScanPhotoButton: View {
    @State private var pickerItem: PhotosPickerItem?
    @State private var showsPicker = false

    var body: some View {
        Menu {
            Button {
                showsPicker = true
            } label: {
                Label("写真から読み取る", systemImage: "photo.on.rectangle")
            }
            Button {
                if let image = UIPasteboard.general.image {
                    AppNavigator.shared.scan(image)
                }
            } label: {
                Label("コピーした画像から読み取る", systemImage: "doc.on.clipboard")
            }
            .disabled(!UIPasteboard.general.hasImages)
        } label: {
            Image(systemName: "text.viewfinder")
        }
        .accessibilityLabel(Text("画像の文字を読み取る"))
        .photosPicker(isPresented: $showsPicker, selection: $pickerItem, matching: .images)
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            pickerItem = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    AppNavigator.shared.scan(image)
                }
            }
        }
    }
}
