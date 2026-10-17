import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

enum PixDonation {
    static let developerName = "Tales Lima (Sem Crânio)"
    static let displayKey = "11 96649-0787"
    static let pixKey = "+5511966490787"

    static let payload: String = {
        let merchantAccount = field("00", "BR.GOV.BCB.PIX")
            + field("01", pixKey)
            + field("02", "APOIO WHATSCRANIO")
        let additionalData = field("05", "***")
        let payloadWithoutCRC = field("00", "01")
            + field("01", "11")
            + field("26", merchantAccount)
            + field("52", "0000")
            + field("53", "986")
            + field("58", "BR")
            + field("59", "TALES LIMA")
            + field("60", "SAO PAULO")
            + field("62", additionalData)
            + "6304"
        return payloadWithoutCRC + crc16(payloadWithoutCRC)
    }()

    static func field(_ id: String, _ value: String) -> String {
        id + String(format: "%02d", value.utf8.count) + value
    }

    static func crc16(_ value: String) -> String {
        var crc: UInt16 = 0xFFFF
        for byte in value.utf8 {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }
        return String(format: "%04X", crc)
    }

    static func qrCodeImage(scale: CGFloat = 12) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }

        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let representation = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}

struct DonationView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var copiedItem: CopiedItem?

    private enum CopiedItem {
        case key
        case code
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.02, green: 0.09, blue: 0.23), Color(red: 0.34, green: 0.03, blue: 0.48)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 16) {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.72))
                    .help("Fechar")
                }

                Image(systemName: "heart.circle.fill")
                    .font(.system(size: 54))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.pink, .white)

                Text("Apoie o WhatsCrânio")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)

                Text("Se o app facilita seu atendimento, você pode incentivar a continuidade do projeto com uma contribuição via Pix.")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.82))
                    .frame(maxWidth: 430)

                if let image = PixDonation.qrCodeImage() {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 260, height: 260)
                        .padding(14)
                        .background(.white, in: RoundedRectangle(cornerRadius: 18))
                        .accessibilityLabel("QR Code Pix para apoiar Tales Lima")
                }

                VStack(spacing: 5) {
                    Text(PixDonation.developerName)
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("Chave Pix celular: \(PixDonation.displayKey)")
                        .font(.system(.body, design: .monospaced, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                }

                HStack(spacing: 12) {
                    Button {
                        copy(PixDonation.pixKey, item: .key)
                    } label: {
                        Label(copiedItem == .key ? "Chave copiada" : "Copiar chave", systemImage: copiedItem == .key ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.pink)

                    Button {
                        copy(PixDonation.payload, item: .code)
                    } label: {
                        Label(copiedItem == .code ? "Código copiado" : "Pix copia e cola", systemImage: copiedItem == .code ? "checkmark" : "qrcode")
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.large)
                .foregroundStyle(.white)

                Text("A contribuição é opcional. Obrigado por apoiar o desenvolvimento independente.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.62))
            }
            .padding(26)
        }
    }

    private func copy(_ value: String, item: CopiedItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copiedItem = item
    }
}
