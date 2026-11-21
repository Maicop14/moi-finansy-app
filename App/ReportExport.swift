import SwiftUI
import UniformTypeIdentifiers
import CoreText
import zlib

struct ReportFile: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf, OriginalBudget.type] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let bytes = configuration.file.regularFileContents else { throw BackupError.incomplete }
        data = bytes
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

enum ReportExport {
    static func pdf(_ report: ReportTable) throws -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0,y: 0,width: 700,height: 595)
        guard let sink = CGDataConsumer(data: data), let ctx = CGContext(consumer: sink, mediaBox: &box, nil) else { throw BackupError.incomplete }
        ctx.beginPDFPage(nil)
        func line(_ text: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat) {
            let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
            let string = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String):font])
            ctx.textPosition = CGPoint(x: x,y: y); CTLineDraw(CTLineCreateWithAttributedString(string), ctx)
        }
        line("Мои Финансы", 30, 545, 22)
        line(report.title + (report.partial ? " · предварительно" : ""), 30, 505, 17)
        line("Показатель", 30, 450, 13); line(report.title, 345, 450, 13); line(report.previous, 515, 450, 13)
        for (i,label) in PeriodValues.labels.enumerated() {
            let y = CGFloat(413 - 35*i)
            line(label, 30, y, 13)
            line(report.currentValues.values[i].map(money) ?? "Нет данных", 345, y, 13)
            line(report.previousValues.values[i].map(money) ?? "Нет данных", 515, y, 13)
        }
        line("Обороты рассчитаны по внесённым операциям.", 30, 102, 11)
        ctx.endPDFPage(); ctx.closePDF()
        return data as Data
    }
    static func xlsx(_ report: ReportTable) -> Data {
        let ns = "http://schemas.openxmlformats.org/"
        func text(_ address: String, _ value: String) -> String {
            "<c r=\""+address+"\" t=\"inlineStr\"><is><t>"+value.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;")+"</t></is></c>"
        }
        func cell(_ address: String, _ value: Int64?) -> String {
            guard let value else { return text(address,"Нет данных") }
            return "<c r=\""+address+"\"><v>"+NSDecimalNumber(decimal: Decimal(value)/100).stringValue+"</v></c>"
        }
        let header = text("A1","Показатель, ₽") + text("B1",report.title) + text("C1",report.previous)
        var rows = "<row r=\"1\">"+header+"</row>"
        for i in PeriodValues.labels.indices {
            let n = String(i+2)
            rows += "<row r=\""+n+"\">" + text("A"+n,PeriodValues.labels[i]) + cell("B"+n,report.currentValues.values[i]) + cell("C"+n,report.previousValues.values[i]) + "</row>"
        }
        rows += "<row r=\"10\">"+text("A10",report.partial ? "Предварительно · по внесённым операциям" : "По внесённым операциям")+"</row>"
        let rel = ns+"package/2006/relationships"
        func relationships(_ type: String,_ target: String) -> String {
            "<Relationships xmlns=\""+rel+"\"><Relationship Id=\"rId1\" Type=\""+ns+"officeDocument/2006/relationships/"+type+"\" Target=\""+target+"\"/></Relationships>"
        }
        let main = ns+"spreadsheetml/2006/main"
        return zip([
            ("[Content_Types].xml","<Types xmlns=\""+ns+"package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/><Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/></Types>"),
            ("_rels/.rels",relationships("officeDocument","xl/workbook.xml")),
            ("xl/workbook.xml","<workbook xmlns=\""+main+"\" xmlns:r=\""+ns+"officeDocument/2006/relationships\"><sheets><sheet name=\"Отчёт\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>"),
            ("xl/_rels/workbook.xml.rels",relationships("worksheet","worksheets/sheet1.xml")),
            ("xl/worksheets/sheet1.xml","<worksheet xmlns=\""+main+"\"><cols><col min=\"1\" max=\"1\" width=\"43\" customWidth=\"1\"/><col min=\"2\" max=\"3\" width=\"25\" customWidth=\"1\"/></cols><sheetData>"+rows+"</sheetData></worksheet>")])
    }
    // Small, uncompressed ZIP with a central directory, containing only the generated OOXML parts.
    private static func zip(_ files: [(String,String)]) -> Data {
        var body = Data(), directory = Data()
        for (path,xml) in files {
            let name = Data(path.utf8), bytes = Data(xml.utf8), offset = UInt32(body.count)
            let crc = bytes.withUnsafeBytes { UInt32(crc32(0,$0.bindMemory(to: UInt8.self).baseAddress,UInt32(bytes.count))) }
            var info = Data()
            for v: UInt16 in [20,0,0,0,33] { info.le(v) }
            info.le(crc); info.le(UInt32(bytes.count)); info.le(UInt32(bytes.count))
            info.le(UInt16(name.count)); info.le(UInt16(0))
            body.le(UInt32(0x04034b50)); body.append(info); body.append(name); body.append(bytes)
            directory.le(UInt32(0x02014b50)); directory.le(UInt16(20)); directory.append(info)
            for _ in 0..<3 { directory.le(UInt16(0)) }
            directory.le(UInt32(0)); directory.le(offset); directory.append(name)
        }
        let offset = UInt32(body.count)
        body.append(directory); body.le(UInt32(0x06054b50)); body.le(UInt32(0))
        body.le(UInt16(files.count)); body.le(UInt16(files.count)); body.le(UInt32(directory.count)); body.le(offset); body.le(UInt16(0))
        return body
    }
}
private extension Data {
    mutating func le<T: FixedWidthInteger>(_ n: T) { var v = n.littleEndian; Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) } }
}
