import Foundation
import PDFKit

/// Joins invoices into one document for double-sided printing: an invoice with an odd number of pages gets a
/// blank page after it, so the next one always starts on a new sheet and two invoices never share a sheet.
public enum PrintBundle {
    public static func document(_ files: [URL]) -> PDFDocument? {
        let out = PDFDocument()
        for url in files {
            guard let doc = PDFDocument(url: url), doc.pageCount > 0 else { continue }
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i)?.copy() as? PDFPage { out.insert(page, at: out.pageCount) }
            }
            if doc.pageCount % 2 == 1, let last = doc.page(at: doc.pageCount - 1) {
                let blank = PDFPage()
                blank.setBounds(last.bounds(for: .mediaBox), for: .mediaBox)
                out.insert(blank, at: out.pageCount)
            }
        }
        return out.pageCount > 0 ? out : nil
    }
}
