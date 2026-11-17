import AppKit

/// 通过 --self-test 执行的确定性回归检查，不启动应用会话，也不读取真实剪贴板或屏幕。
@MainActor
enum SelfTests {
    static func run() {
        var passed = 0
        var failed = 0
        func check(_ condition: Bool, _ name: String) {
            if condition { passed += 1; print("PASS \(name)") }
            else { failed += 1; print("FAIL \(name)") }
        }
        // 固定日期与时区，让自然日边界测试不受执行当天时间和系统设置影响。
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 10))!
        func entry(days: Int, bytes: Int64 = 100, favorite: Bool = false) -> ClipboardEntry {
            ClipboardEntry(createdAt: calendar.date(byAdding: .day, value: days, to: now)!, kind: .text, text: "测试", fingerprint: UUID().uuidString,
                           source: "test", bytes: bytes, favorite: favorite)
        }
        let today = entry(days: 0), yesterday = entry(days: -1), dayBefore = entry(days: -2), expired = entry(days: -3), pinned = entry(days: -20, favorite: true)
        let retained = ClipboardPolicy.retained([today, yesterday, dayBefore, expired, pinned], days: 3, capacity: 1000, now: now, calendar: calendar)
        check(Set(retained.map(\.id)) == Set([today.id, yesterday.id, dayBefore.id, pinned.id]), "自然日保留三天且保留过期收藏")
        let limited = ClipboardPolicy.retained([today, yesterday, dayBefore, pinned], days: 3, capacity: 250, now: now, calendar: calendar)
        check(Set(limited.map(\.id)) == Set([today.id, pinned.id]), "容量限制优先清理最旧的非收藏")
        let pinnedOnly = ClipboardPolicy.retained([pinned, today], days: 1, capacity: 1, now: now, calendar: calendar)
        check(pinnedOnly.map(\.id) == [pinned.id], "容量不足不删除收藏")
        let midnight = calendar.startOfDay(for: now)
        let boundary = ClipboardEntry(createdAt: calendar.date(byAdding: .day, value: -2, to: midnight)!, kind: .text, text: "边界", fingerprint: "boundary", source: "test", bytes: 1)
        check(ClipboardPolicy.retained([boundary], days: 3, capacity: 100, now: now, calendar: calendar).count == 1, "第三天零点包含在保留范围")
        check(FileKind.classify(URL(fileURLWithPath: "/tmp/a.SWIFT"), directory: false) == .code, "文件类型大小写识别")
        check(FileKind.classify(URL(fileURLWithPath: "/tmp/test.png"), directory: true) == .folder, "文件夹优先于扩展名")
        let shortcuts = Feature.allCases.compactMap { Shortcut.standard(for: $0) }
        check(Set(shortcuts.map { "\($0.keyCode)-\($0.modifiers)" }).count == shortcuts.count, "默认快捷键互不重复")
        let quartz = CGRect(x: -1400, y: -500, width: 800, height: 600)
        check(CaptureGeometry.appKitRect(fromQuartz: quartz, primaryTop: 900) == CGRect(x: -1400, y: 800, width: 800, height: 600), "窗口建议支持主屏左上方的副屏")
        let source = CGRect(x: 30, y: 80, width: 300, height: 200)
        let screen = CGRect(x: -1440, y: 900, width: 1440, height: 900)
        check(CaptureGeometry.globalRect(sourceRect: source, screenFrame: screen) == CGRect(x: -1410, y: 1520, width: 300, height: 200), "录制边框与副屏选区坐标一致")
        let front = WindowSuggestion(frame: CGRect(x: 100, y: 100, width: 200, height: 200), title: "前窗")
        let back = WindowSuggestion(frame: CGRect(x: 0, y: 0, width: 500, height: 500), title: "后窗")
        check(WindowSuggestion.hit(at: CGPoint(x: 150, y: 150), in: [front, back])?.title == "前窗", "重叠窗口优先建议最前面的窗口")
        check(WindowSuggestion.hit(at: CGPoint(x: 450, y: 450), in: [front, back])?.title == "后窗", "鼠标移动到后方窗口可见部分时切换建议")
        check(WindowSuggestion.hit(at: CGPoint(x: 700, y: 700), in: [front, back]) == nil, "窗口之外不自动确认无效区域")
        // 直接调用离屏选区视图的鼠标处理器，不派发系统输入、不读取或捕获真实屏幕。
        let selectionView = SelectionView(frame: CGRect(x: 0, y: 0, width: 1000, height: 700))
        selectionView.suggestions = [front, back]
        var chosenRegion: CGRect?
        selectionView.completed = { chosenRegion = $0 }
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        }
        selectionView.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 150, y: 150)))
        selectionView.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 150, y: 150)))
        check(chosenRegion == front.frame, "单击只采用当前建议窗口范围")
        chosenRegion = nil
        selectionView.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 150, y: 150)))
        selectionView.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 420, y: 350)))
        selectionView.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 420, y: 350)))
        check(chosenRegion == CGRect(x: 150, y: 150, width: 270, height: 200), "从建议窗口内按住拖动可切换为自定义范围")
        chosenRegion = nil
        selectionView.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 420, y: 350)))
        selectionView.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 150, y: 150)))
        selectionView.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 150, y: 150)))
        check(chosenRegion == CGRect(x: 150, y: 150, width: 270, height: 200), "自定义范围支持反向拖动")
        chosenRegion = nil
        selectionView.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 150, y: 150)))
        selectionView.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 152, y: 151)))
        selectionView.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 152, y: 151)))
        check(chosenRegion == front.frame, "单击轻微抖动仍采用建议范围")
        check(VideoTimeline.validRange(start: 0.4, end: 2.4, duration: 3), "允许原录像内部裁剪")
        check(!VideoTimeline.validRange(start: 2, end: 1, duration: 3)
              && !VideoTimeline.validRange(start: -.infinity, end: 2, duration: 3)
              && !VideoTimeline.validRange(start: 0, end: 4, duration: 3), "拒绝反向、非有限与越界时间")
        do {
            let width = 192, fullHeight = 700, frameHeight = 320, shift = 103
            var pixels = [UInt8](repeating: 0, count: width * fullHeight * 4)
            // 固定种子生成可重复的纹理，再裁剪出已知位移的两帧验证接缝与图像方向。
            var state: UInt64 = 42
            for y in 0..<fullHeight {
                for x in 0..<width {
                    state = state &* 6364136223846793005 &+ 1
                    let index = (y * width + x) * 4
                    pixels[index] = UInt8((state >> 32) % 256)
                    pixels[index + 1] = UInt8((x * 11 + y * 7) % 256)
                    pixels[index + 2] = UInt8((y * 17 + x * 3) % 256)
                    pixels[index + 3] = 255
                }
            }
            let provider = CGDataProvider(data: Data(pixels) as CFData)!
            let full = CGImage(width: width, height: fullHeight, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            let first = full.cropping(to: CGRect(x: 0, y: 0, width: width, height: frameHeight))!
            // 选区内部也必须写入不透明像素，防止真实窗口系统将点击穿透给下面的应用。
            let opaqueView = SelectionView(frame: CGRect(x: 0, y: 0, width: width, height: frameHeight))
            opaqueView.backgroundImage = first
            opaqueView.suggestions = [WindowSuggestion(frame: CGRect(x: 20, y: 20, width: 100, height: 100), title: "测试窗口")]
            opaqueView.suggest(at: CGPoint(x: 50, y: 50))
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: frameHeight, bitsPerSample: 8,
                                          samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            opaqueView.draw(opaqueView.bounds)
            NSGraphicsContext.restoreGraphicsState()
            check(bitmap.colorAt(x: 50, y: frameHeight - 50)?.alphaComponent == 1, "建议选区保持不透明，避免鼠标穿透")
            check(bitmap.colorAt(x: 5, y: 5)?.alphaComponent == 1, "选区之外也保持不透明底图")
            let next = full.cropping(to: CGRect(x: 0, y: shift, width: width, height: frameHeight))!
            let match = try ImageStitcher.displacement(previous: first, next: next)
            check(match.addedRows == shift, "长图像素级位移匹配：\(match.addedRows) / \(shift)")
            check(try ImageStitcher.displacement(previous: next, next: first).addedRows == -shift, "向上滚动返回负位移")
            check(try ImageStitcher.displacement(previous: first, next: first).addedRows == 0, "静止画面不重复追加")
            let strip = next.cropping(to: CGRect(x: 0, y: frameHeight - shift, width: width, height: shift))!
            let assembled = try ImageStitcher.assemble([first, strip])
            let expected = full.cropping(to: CGRect(x: 0, y: 0, width: width, height: frameHeight + shift))!
            let actualBytes = try ImageStitcher.grayscale(assembled, width: width, height: frameHeight + shift)
            let expectedBytes = try ImageStitcher.grayscale(expected, width: width, height: frameHeight + shift)
            check(actualBytes == expectedBytes, "长图拼接无翻转、重复或接缝偏移")
            // 从正文中间开始，上下往返跨过首帧；比较整张输出，而不只检查最终高度。
            var extent = ScrollExtent(frameHeight: frameHeight)
            var current = full.cropping(to: CGRect(x: 0, y: 200, width: width, height: frameHeight))!
            var sections = [current]
            var lastOffset = 200
            for offset in [300, 250, 150, 50, 150, 300, 350] {
                let frame = full.cropping(to: CGRect(x: 0, y: offset, width: width, height: frameHeight))!
                let displacement = try ImageStitcher.displacement(previous: current, next: frame).addedRows
                guard displacement == offset - lastOffset else { throw AppFailure.message("往返滚动位移错误：\(displacement)") }
                let growth = extent.move(by: displacement)
                if growth.prepend > 0 {
                    sections.insert(frame.cropping(to: CGRect(x: 0, y: 0, width: width, height: growth.prepend))!, at: 0)
                }
                if growth.append > 0 {
                    sections.append(frame.cropping(to: CGRect(x: 0, y: frameHeight - growth.append, width: width, height: growth.append))!)
                }
                current = frame; lastOffset = offset
            }
            check(extent.height == 620, "上下往返只增加覆盖范围之外的内容")
            let bidirectional = try ImageStitcher.assemble(sections)
            let span = full.cropping(to: CGRect(x: 0, y: 50, width: width, height: 620))!
            check(try ImageStitcher.grayscale(bidirectional, width: width, height: 620) == ImageStitcher.grayscale(span, width: width, height: 620),
                  "双向拼接全图像素一致，无漏行与重复行")
            let document = AnnotationDocument(image: first)
            let identity = try document.rendered()
            check(try ImageStitcher.grayscale(identity, width: width, height: frameHeight) == ImageStitcher.grayscale(first, width: width, height: frameHeight), "编辑器未标注时保持原始方向")
            document.add(Annotation(tool: .mosaic, points: [CGPoint(x: 20, y: 30), CGPoint(x: 140, y: 120)], color: .red, width: 8, text: "", fontSize: 20))
            let edited = try document.rendered()
            check(try ImageStitcher.grayscale(edited, width: width, height: frameHeight) != ImageStitcher.grayscale(first, width: width, height: frameHeight), "马赛克实际写入导出图片")
            document.undo(); check(document.annotations.isEmpty && document.redoStack.count == 1, "标注撤销")
            document.redo(); check(document.annotations.count == 1 && document.redoStack.isEmpty, "标注重做")
            let png = try LocalFiles.png(edited)
            check(png.count > 0, "PNG 导出")
            // Retina 尺寸先缩小匹配，再恢复到原始像素；位移不取缩放倍数。
            let largeWidth = 768, largeHeight = 1600, viewport = 1000, movement = 411
            var large = [UInt8](repeating: 255, count: largeWidth * largeHeight)
            for y in 0..<largeHeight {
                for x in 0..<largeWidth where y % 31 < 11 && x % 23 < 14 && x > 40 && x < largeWidth - 40 {
                    large[y * largeWidth + x] = UInt8(((y / 31) * 43 + (x / 23) * 17) % 150)
                }
            }
            let largeImage = CGImage(width: largeWidth, height: largeHeight, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: largeWidth,
                                     space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: CGDataProvider(data: Data(large) as CFData)!,
                                     decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            let largeFirst = largeImage.cropping(to: CGRect(x: 0, y: 0, width: largeWidth, height: viewport))!
            let largeNext = largeImage.cropping(to: CGRect(x: 0, y: movement, width: largeWidth, height: viewport))!
            let largeMatch = try ImageStitcher.displacement(previous: largeFirst, next: largeNext)
            check(largeMatch.addedRows == movement, "Retina 缩小匹配后恢复精确位移：\(largeMatch.addedRows) / \(movement)")
            check(try ImageStitcher.displacement(previous: largeNext, next: largeFirst).addedRows == -movement, "Retina 向上滚动恢复精确位移")
            var dynamic = pixels
            for y in 0..<fullHeight {
                for x in 60..<85 { dynamic[(y * width + x) * 4] = 255; dynamic[(y * width + x) * 4 + 1] = 0 }
            }
            let changed = CGImage(width: width, height: fullHeight, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: CGDataProvider(data: Data(dynamic) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            let changedFrame = changed.cropping(to: CGRect(x: 0, y: shift, width: width, height: frameHeight))!
            check(try ImageStitcher.displacement(previous: first, next: changedFrame).addedRows == shift, "局部画面变化不阻断可靠重叠匹配")
            let unrelated = full.cropping(to: CGRect(x: 0, y: 380, width: width, height: frameHeight))!
            do {
                _ = try ImageStitcher.displacement(previous: first, next: unrelated)
                check(false, "拒绝无重叠画面")
            } catch { check(true, "拒绝无重叠画面") }
            let fixtureDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/UITestArtifacts")
            try LocalFiles.ensure(fixtureDirectory)
            try LocalFiles.png(largeFirst).write(to: fixtureDirectory.appendingPathComponent("screenshot-fixture.png"))
        } catch { check(false, "图像算法：\(error.localizedDescription)") }
        MemeSelfTests.run(check: check)
        SettingsSelfTests.run(check: check)
        print("RESULT \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
