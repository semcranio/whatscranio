import AppKit
import Testing
import Vision
@testable import WhatsCranio

struct PixDonationTests {
    @Test("Payload Pix usa a chave de celular normalizada")
    func normalizedPhoneKey() {
        #expect(PixDonation.pixKey == "+5511966490787")
        #expect(PixDonation.payload.contains("+5511966490787"))
        #expect(PixDonation.payload.contains("TALES LIMA"))
    }

    @Test("Payload Pix contém CRC16 válido")
    func validCRC() {
        let payload = PixDonation.payload
        #expect(payload.count > 4)
        let crcStart = payload.index(payload.endIndex, offsetBy: -4)
        let body = String(payload[..<crcStart])
        let checksum = String(payload[crcStart...])
        #expect(body.hasSuffix("6304"))
        #expect(PixDonation.crc16(body) == checksum)
    }

    @Test("Campos EMV calculam tamanho em bytes")
    func byteLength() {
        #expect(PixDonation.field("59", "TALES LIMA") == "5910TALES LIMA")
        #expect(PixDonation.field("00", "BR.GOV.BCB.PIX") == "0014BR.GOV.BCB.PIX")
    }

    @Test("QR Code pode ser lido de volta com o payload Pix completo")
    func readableQRCode() throws {
        let image = try #require(PixDonation.qrCodeImage())
        var proposedRect = CGRect(origin: .zero, size: image.size)
        let cgImage = try #require(image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil))
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: cgImage).perform([request])
        let observation = try #require(request.results?.first)
        #expect(observation.payloadStringValue == PixDonation.payload)
    }
}
