// Reference adapter: compile with the unmodified S1Kit sources.
import Foundation

func page(_ value: [String: Any]) -> GrayPage {
    GrayPage(width: value["width"] as! Int, height: value["height"] as! Int,
             dpi: value["dpi"] as? Int ?? 203, pixels: (value["pixels"] as! [Int]).map { UInt8($0) })
}
func pageJSON(_ p: GrayPage) -> [String: Any] {
    ["width": p.width, "height": p.height, "dpi": p.dpi, "pixels": p.pixels.map(Int.init)]
}
func run(_ v: [String: Any]) throws -> [String: Any] {
    switch v["op"] as! String {
    case "page":
        let p = page(v["page"] as! [String: Any])
        let mode = DitherMode(rawValue: v["mode"] as? String ?? "auto")!
        let threshold = v["threshold"] as? Int ?? 150
        let bits = Dither.pack(p, mode: mode, threshold: threshold)
        let columns = p.inkColumns()
        let bounds = v["crop"] as! [Int]
        return ["scaled": pageJSON(p.scaled(toWidth: v["targetWidth"] as! Int)),
                "trimmed": pageJSON(p.trimmingVertical()),
                "collapsed": pageJSON(p.collapsingBlankRuns(maxRows: v["maxBlankRows"] as! Int)),
                "cropped": pageJSON(p.cropped(toColumns: bounds[0]...bounds[1])),
                "inkColumns": columns.map { [$0.lowerBound, $0.upperBound] } as Any? ?? NSNull(),
                "blank": p.isBlank(), "photo": Dither.hasPhotographicContent(p),
                "bitmap": ["widthBytes": bits.widthBytes, "height": bits.height, "rows": bits.rows.map(Int.init)]]
    case "job":
        let pages = (v["pages"] as! [[String: Any]]).map(page)
        let o = v["options"] as? [String: Any] ?? [:]
        var options = PrintOptions()
        options.headWidthBytes = o["headWidthBytes"] as? Int ?? options.headWidthBytes
        options.density = o["density"] as? Int ?? options.density
        options.dither = DitherMode(rawValue: o["dither"] as? String ?? "auto")!
        options.feedAfterPage = o["feedAfterPage"] as? Int ?? options.feedAfterPage
        options.labelPaper = o["labelPaper"] as? Bool ?? options.labelPaper
        options.trimBottom = o["trimBottom"] as? Bool ?? options.trimBottom
        options.maxBlankRows = o["maxBlankRows"] as? Int ?? options.maxBlankRows
        options.fitContentWidth = o["fitContentWidth"] as? Bool ?? options.fitContentWidth
        options.rowsPerBlock = o["rowsPerBlock"] as? Int ?? options.rowsPerBlock
        let chunks = S1JobBuilder.build(pages: pages, options: options)
        let crop = GrayPage.sharedInkColumns(of: pages)
        return ["chunks": chunks.map { Array($0).map(Int.init) },
                "sharedInkColumns": crop.map { [$0.lowerBound, $0.upperBound] } as Any? ?? NSNull()]
    case "decode":
        let data = Data((v["bytes"] as! [Int]).map { UInt8($0) })
        do { return ["isRaster": RasterDecoder.isRaster(data), "pages": try RasterDecoder.decode(data).map(pageJSON)] }
        catch { return ["isRaster": RasterDecoder.isRaster(data), "error": String(describing: error)] }
    case "status":
        let s = S1Status(raw: UInt8(v["raw"] as! Int))
        return ["printing": s.printing, "coverOpen": s.coverOpen, "outOfPaper": s.outOfPaper,
                "lowBattery": s.lowBattery, "overheated": s.overheated, "charging": s.charging,
                "ready": s.ready, "ippReasons": s.ippReasons, "description": s.description]
    case "commands":
        return ["density": Array(S1Command.density(v["density"] as! Int)).map(Int.init),
                "feed": Array(S1Command.feed(dots: v["dots"] as! Int)).map(Int.init),
                "fixed": [S1Command.getModel, S1Command.getFirmware, S1Command.getSerial,
                          S1Command.getBattery, S1Command.getStatus, S1Command.getShutdownMinutes,
                          S1Command.getAllInfo, S1Command.wake, S1Command.enable, S1Command.stop,
                          S1Command.formFeed].map { Array($0).map(Int.init) }]
    default: fatalError("unknown operation")
    }
}
while let line = readLine() {
    do {
        let input = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        let result = try run(input)
        let output = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print(String(data: output, encoding: .utf8)!)
    } catch { fputs("\(error)\n", stderr); exit(1) }
}
