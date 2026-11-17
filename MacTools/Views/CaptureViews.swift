import SwiftUI

struct CaptureTargetView: View {
    @ObservedObject var controller: CaptureController
    @ObservedObject var settings = SettingsStore.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("捕获范围", selection: $controller.mode) {
                Text("选取区域").tag(0); Text("整个屏幕").tag(1); Text("指定窗口").tag(2)
            }.pickerStyle(.segmented)
            if controller.mode == 0 {
                Toggle("指定输出像素尺寸", isOn: $controller.exactSize)
                if controller.exactSize {
                    HStack {
                        TextField("宽", text: $controller.width).frame(width: 85)
                        Text("×").foregroundStyle(.secondary)
                        TextField("高", text: $controller.height).frame(width: 85)
                        Text("px").foregroundStyle(.secondary)
                        Spacer()
                        Menu("常用尺寸") {
                            ForEach(settings.presets, id: \.self) { preset in
                                Button(preset) {
                                    let parts = preset.components(separatedBy: " × ")
                                    if parts.count == 2 { controller.width = parts[0]; controller.height = parts[1] }
                                }
                            }
                        }
                        Button { controller.savePreset() } label: { Image(systemName: "plus") }.help("保存当前尺寸")
                    }.textFieldStyle(.roundedBorder)
                }
                Text("单击截取建议窗口；按住左键拖动自定义区域，松开完成。指定尺寸时点击放置。Esc 取消。").font(.caption).foregroundStyle(.secondary)
            } else if controller.mode == 1 {
                Picker("显示器", selection: $controller.screenIndex) {
                    ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { index, screen in Text(screen.localizedName).tag(index) }
                }
            } else {
                HStack {
                    Picker("窗口", selection: $controller.windowID) {
                        Text("请选择窗口").tag(CGWindowID(0))
                        ForEach(controller.windows, id: \.windowID) { window in
                            Text("\(window.owningApplication?.applicationName ?? "应用") · \(window.title ?? "未命名窗口")").tag(window.windowID)
                        }
                    }
                    Button("刷新") { Task { await controller.loadWindows() } }
                }
            }
        }
    }
}

struct CaptureView: View {
    let feature: Feature
    @ObservedObject var controller: CaptureController
    var body: some View {
        VStack(spacing: 0) {
            FeatureHeader(feature: feature)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if feature == .scrollshot {
                        Label("框选 → 开始滚动 → 结束 → 编辑", systemImage: "arrow.down.to.line.compact").font(.headline)
                        Text("选取滚动正文区域，可向上或向下滚动，往返内容自动去重。每次保留至少五分之一的重叠画面，尽量避开固定导航栏。")
                            .foregroundStyle(.secondary)
                        if controller.scrolling {
                            HStack(spacing: 28) {
                                Label("\(controller.frameCount) 段", systemImage: "photo.stack")
                                Text("\(controller.totalHeight) px").monospacedDigit()
                                ProgressView().controlSize(.small)
                            }.font(.title3).padding(.vertical, 20)
                        }
                    } else { CaptureTargetView(controller: controller) }
                    if feature == .ocr, !controller.recognizedText.isEmpty {
                        Text("识别结果").font(.headline)
                        TextEditor(text: $controller.recognizedText).font(.body).frame(minHeight: 180)
                            .padding(8).background(.background, in: RoundedRectangle(cornerRadius: 8))
                        Button("复制全部文字") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(controller.recognizedText, forType: .string)
                            controller.message = "已复制"
                        }
                    }
                    StatusLine(text: controller.message)
                    HStack {
                        if controller.busy { ProgressView().controlSize(.small) }
                        Spacer()
                        if feature == .scrollshot {
                            if controller.scrolling {
                                Button("取消") { controller.cancelScrolling() }.disabled(controller.busy)
                                Button("结束并编辑") { Task { await controller.finishScrolling() } }
                                    .buttonStyle(.borderedProminent).tint(.teal).disabled(controller.busy)
                            } else {
                                Button("选择区域并开始") { Task { await controller.startScrolling() } }
                                    .buttonStyle(.borderedProminent).tint(.teal).disabled(controller.busy)
                            }
                        } else {
                            Button(feature == .ocr ? "选取并识别" : "开始截图") { Task { await controller.capture(ocr: feature == .ocr) } }
                                .buttonStyle(.borderedProminent).tint(.teal).disabled(controller.busy)
                        }
                    }
                    HStack {
                        Image(systemName: "lock.shield").foregroundStyle(.secondary)
                        Text("首次使用需要屏幕录制权限").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("打开权限设置") { PermissionLinks.screen() }.buttonStyle(.link).font(.caption)
                    }
                }.padding(24)
            }
        }
    }
}

struct AnnotationEditorView: View {
    @ObservedObject var document: AnnotationDocument
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ForEach(AnnotationTool.allCases) { tool in
                    Button { document.tool = tool } label: {
                        Image(systemName: tool.icon).frame(width: 25, height: 25)
                            .background(document.tool == tool ? Color.teal.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain).help(tool.rawValue).accessibilityLabel(tool.rawValue)
                }
                Divider().frame(height: 24)
                ColorPicker("颜色", selection: Binding(get: { Color(nsColor: document.color) }, set: { document.color = NSColor($0) })).labelsHidden()
                Slider(value: $document.lineWidth, in: 2...20).frame(width: 75).help("笔画粗细／马赛克块大小")
                Spacer()
                Button { document.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(document.annotations.isEmpty).keyboardShortcut("z", modifiers: .command).help("撤销")
                Button { document.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(document.redoStack.isEmpty).keyboardShortcut("z", modifiers: [.command, .shift]).help("重做")
            }.padding(14)
            if document.tool == .text {
                HStack {
                    EditorInput(text: $document.text, placeholder: "输入文字，再点击图片放置").frame(height: 26)
                    Text("字号")
                    Slider(value: $document.fontSize, in: 14...100).frame(width: 120)
                    Text("\(Int(document.fontSize))").monospacedDigit().frame(width: 32)
                }.padding(.horizontal, 16).padding(.bottom, 12)
            }
            Divider()
            ScrollView([.horizontal, .vertical]) {
                AnnotationCanvas(document: document)
                    .frame(width: CGFloat(document.image.width) * document.zoom, height: CGFloat(document.image.height) * document.zoom)
                    .padding(24)
            }.background(Color(nsColor: .underPageBackgroundColor))
            Divider()
            HStack(spacing: 12) {
                Text("\(document.image.width) × \(document.image.height)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Slider(value: $document.zoom, in: 0.1...2).frame(width: 90)
                Text("\(Int(document.zoom * 100))%").font(.caption.monospacedDigit()).frame(width: 38)
                Spacer()
                Button("置顶") {
                    do { WindowCoordinator.shared.pin(try document.rendered()) }
                    catch { document.message = error.localizedDescription }
                }
                Button("复制") { document.export(copy: true, save: false) }.keyboardShortcut("c", modifiers: .command)
                Button("保存") { document.export(copy: false, save: true) }.keyboardShortcut("s", modifiers: .command)
                Button("复制并保存") { document.export(copy: true, save: true) }.buttonStyle(.borderedProminent).tint(.teal)
            }.padding(14)
            if !document.message.isEmpty { Text(document.message).font(.caption).textSelection(.enabled).padding(.horizontal, 14).padding(.bottom, 10) }
        }
    }
}

struct RecordingView: View {
    @ObservedObject var controller = RecordingController.shared
    var body: some View {
        VStack(spacing: 0) {
            FeatureHeader(feature: .recording)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    CaptureTargetView(controller: controller.capture).disabled(controller.isRecording || controller.busy)
                    HStack(spacing: 30) {
                        Toggle("系统声音", isOn: $controller.systemAudio)
                        Toggle("麦克风", isOn: $controller.microphone)
                    }.toggleStyle(.switch).disabled(controller.isRecording || controller.busy)
                    HStack {
                        Picker("帧率", selection: $controller.fps) { Text("30 fps").tag(30); Text("60 fps").tag(60) }
                        Picker("倒计时", selection: $controller.countdown) { Text("无").tag(0); Text("3 秒").tag(3); Text("5 秒").tag(5) }
                    }.disabled(controller.isRecording || controller.busy)
                    if !controller.phase.isEmpty {
                        HStack {
                            Image(systemName: "record.circle.fill").foregroundStyle(.red)
                            Text(controller.phase).font(.headline)
                            Spacer()
                            if controller.isRecording, let start = controller.startedAt { Text(start, style: .timer).monospacedDigit().font(.title2) }
                        }.padding(16).background(.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    }
                    StatusLine(text: controller.message.isEmpty ? controller.capture.message : controller.message)
                    HStack {
                        if let url = controller.lastURL {
                            Button("预览与编辑上次录像") { WindowCoordinator.shared.editVideo(url) }
                            Button("在 Finder 中查看") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        }
                        Spacer()
                        if controller.busy { ProgressView().controlSize(.small) }
                        if controller.isRecording {
                            Button("停止并编辑") { Task { await controller.stop() } }.buttonStyle(.borderedProminent).tint(.red).disabled(controller.busy)
                        } else {
                            Button("开始录制") { Task { await controller.start() } }.buttonStyle(.borderedProminent).tint(.teal).disabled(controller.busy)
                        }
                    }
                    Text("快捷键按上次模式直接开始采集。选定范围后显示红色边框，点击悬浮控制条停止；完成后自动打开预览编辑。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(24)
            }
        }
    }
}

@MainActor
enum PermissionLinks {
    static func screen() { open("Privacy_ScreenCapture") }
    static func microphone() { open("Privacy_Microphone") }
    static func files() { open("Privacy_AllFiles") }
    private static func open(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") { NSWorkspace.shared.open(url) }
    }
}
