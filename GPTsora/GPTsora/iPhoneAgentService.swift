// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-7370783a8650b523f60a957674e6ff7b92deb1f68afcd505b87d2e7324ed0812"
// Source-SHA256: "0c2204439ec2d1a533b99677dfad99f3cee0a6a63cf064666fabee5cd4c17563"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation
import UIKit
import Combine
import Contacts
import EventKit
import Photos
import CoreLocation
import AVFoundation
import UserNotifications

// MARK: - iPhone Local Agent Service
// 纯本地，不走网络，直接调 iOS SDK 控制手机

final class iPhoneAgentService: NSObject, ObservableObject {
    static let shared = iPhoneAgentService()

    private let contactStore = CNContactStore()
    private let eventStore = EKEventStore()
    private let locationManager = CLLocationManager()
    private let fm = FileManager.default

    @Published var lastLocation: CLLocation?

    override init() {
        super.init()
        locationManager.delegate = self
    }

    // MARK: - ═══ 📱 设备信息 ═══

    func deviceInfo() -> [String: String] {
        let device = UIDevice.current
        let battery = device.batteryLevel
        device.isBatteryMonitoringEnabled = true

        let processInfo = ProcessInfo.processInfo

        // 存储空间
        var totalSpace: String = "未知"
        var freeSpace: String = "未知"
        if let attrs = try? fm.attributesOfFileSystem(forPath: NSHomeDirectory()) {
            if let total = attrs[.systemSize] as? Int64 {
                totalSpace = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
            }
            if let free = attrs[.systemFreeSize] as? Int64 {
                freeSpace = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
            }
        }

        return [
            "model": device.model,
            "name": device.name,
            "system": "\(device.systemName) \(device.systemVersion)",
            "battery": battery >= 0 ? "\(Int(battery * 100))%" : "未知",
            "batteryState": batteryStateString(device.batteryState),
            "storage_total": totalSpace,
            "storage_free": freeSpace,
            "memory_total": "\(processInfo.physicalMemory / 1024 / 1024 / 1024) GB",
            "processor_count": "\(processInfo.processorCount) 核",
            "screen": "\(Int(UIScreen.main.bounds.width))×\(Int(UIScreen.main.bounds.height)) @\(Int(UIScreen.main.scale))x",
        ]
    }

    private func batteryStateString(_ state: UIDevice.BatteryState) -> String {
        switch state {
        case .charging: return "充电中"
        case .full: return "已充满"
        case .unplugged: return "未充电"
        default: return "未知"
        }
    }

    // MARK: - ═══ 👤 通讯录 ═══

    func requestContactsAccess() async -> Bool {
        if #available(iOS 18.0, *) {
            return (try? await contactStore.requestAccess(for: .contacts)) ?? false
        } else {
            return await withCheckedContinuation { cont in
                contactStore.requestAccess(for: .contacts) { ok, _ in cont.resume(returning: ok) }
            }
        }
    }

    func searchContacts(keyword: String, limit: Int = 20) async throws -> [ContactInfo] {
        guard await requestContactsAccess() else { throw PhoneAgentError.permissionDenied("通讯录") }

        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
        ]

        let req = CNContactFetchRequest(keysToFetch: keys)
        var results: [ContactInfo] = []
        let kw = keyword.lowercased()

        try contactStore.enumerateContacts(with: req) { contact, stop in
            let fullName = "\(contact.familyName)\(contact.givenName)"
            let org = contact.organizationName
            if kw.isEmpty || fullName.lowercased().contains(kw) || org.lowercased().contains(kw) {
                let phones = contact.phoneNumbers.map { $0.value.stringValue }
                let emails = contact.emailAddresses.map { $0.value as String }
                results.append(ContactInfo(
                    name: fullName.isEmpty ? "(无名)" : fullName,
                    organization: org,
                    phones: phones,
                    emails: emails
                ))
            }
            if results.count >= limit { stop.pointee = true }
        }
        return results
    }

    // MARK: - ═══ 📅 日历 ═══

    func requestCalendarAccess() async -> Bool {
        if #available(iOS 17.0, *) {
            return (try? await eventStore.requestFullAccessToEvents()) ?? false
        } else {
            return await withCheckedContinuation { cont in
                eventStore.requestAccess(to: .event) { ok, _ in cont.resume(returning: ok) }
            }
        }
    }

    func upcomingEvents(days: Int = 7, limit: Int = 20) async throws -> [EventInfo] {
        guard await requestCalendarAccess() else { throw PhoneAgentError.permissionDenied("日历") }

        let start = Date()
        let end = Calendar.current.date(byAdding: .day, value: days, to: start)!
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = eventStore.events(matching: predicate).prefix(limit)

        return events.map { ev in
            EventInfo(
                title: ev.title ?? "(无标题)",
                startDate: ev.startDate,
                endDate: ev.endDate,
                location: ev.location,
                isAllDay: ev.isAllDay,
                calendar: ev.calendar.title
            )
        }
    }

    func createEvent(title: String, startDate: Date, endDate: Date, location: String? = nil) async throws -> String {
        guard await requestCalendarAccess() else { throw PhoneAgentError.permissionDenied("日历") }

        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.startDate = startDate
        event.endDate = endDate
        event.location = location
        event.calendar = eventStore.defaultCalendarForNewEvents
        try eventStore.save(event, span: .thisEvent)
        return "✅ 已创建日历事件: \(title)"
    }

    // MARK: - ═══ ✅ 提醒事项 ═══

    func requestRemindersAccess() async -> Bool {
        if #available(iOS 17.0, *) {
            return (try? await eventStore.requestFullAccessToReminders()) ?? false
        } else {
            return await withCheckedContinuation { cont in
                eventStore.requestAccess(to: .reminder) { ok, _ in cont.resume(returning: ok) }
            }
        }
    }

    func reminders(limit: Int = 20) async throws -> [ReminderInfo] {
        guard await requestRemindersAccess() else { throw PhoneAgentError.permissionDenied("提醒事项") }

        let predicate = eventStore.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: nil, calendars: nil
        )
        let items = await withCheckedContinuation { (cont: CheckedContinuation<[EKReminder], Never>) in
            eventStore.fetchReminders(matching: predicate) { cont.resume(returning: $0 ?? []) }
        }

        return items.prefix(limit).map { r in
            ReminderInfo(
                title: r.title ?? "(无标题)",
                dueDate: r.dueDateComponents?.date,
                priority: r.priority,
                isCompleted: r.isCompleted,
                list: r.calendar.title
            )
        }
    }

    func createReminder(title: String, dueDate: Date? = nil) async throws -> String {
        guard await requestRemindersAccess() else { throw PhoneAgentError.permissionDenied("提醒事项") }

        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = title
        if let dueDate {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: dueDate
            )
        }
        reminder.calendar = eventStore.defaultCalendarForNewReminders()
        try eventStore.save(reminder, commit: true)
        return "✅ 已创建提醒: \(title)"
    }

    // MARK: - ═══ 📸 相册 ═══

    func photoLibraryStats() async throws -> PhotoStats {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw PhoneAgentError.permissionDenied("相册")
        }

        let allPhotos = PHAsset.fetchAssets(with: .image, options: nil)
        let allVideos = PHAsset.fetchAssets(with: .video, options: nil)

        return PhotoStats(photoCount: allPhotos.count, videoCount: allVideos.count)
    }

    // MARK: - ═══ 📋 剪贴板 ═══

    func clipboardRead() -> String {
        UIPasteboard.general.string ?? "(剪贴板为空)"
    }

    func clipboardWrite(_ text: String) {
        UIPasteboard.general.string = text
    }

    // MARK: - ═══ 📲 打开 App ═══

    @MainActor
    func openApp(_ scheme: String) -> Bool {
        guard let url = URL(string: scheme) else { return false }
        guard UIApplication.shared.canOpenURL(url) else { return false }
        UIApplication.shared.open(url)
        return true
    }

    /// 常用 App URL Schemes
    static let appSchemes: [(name: String, scheme: String, icon: String)] = [
        ("微信", "weixin://", "bubble.left"),
        ("支付宝", "alipay://", "yensign.circle"),
        ("淘宝", "taobao://", "bag"),
        ("抖音", "snssdk1128://", "play.rectangle"),
        ("Safari", "https://www.apple.com", "safari"),
        ("地图", "maps://", "map"),
        ("电话", "tel://", "phone"),
        ("短信", "sms://", "message"),
        ("邮件", "mailto:", "envelope"),
        ("设置", "App-prefs://", "gear"),
        ("相机", "camera://", "camera"),
        ("备忘录", "mobilenotes://", "note.text"),
    ]

    // MARK: - ═══ 📍 位置 ═══

    func requestLocation() {
        locationManager.requestWhenInUseAuthorization()
        locationManager.requestLocation()
    }

    func currentLocationString() -> String {
        guard let loc = lastLocation else { return "位置未获取（请先授权定位）" }
        return String(format: "纬度: %.6f, 经度: %.6f (±%.0fm)",
                       loc.coordinate.latitude, loc.coordinate.longitude, loc.horizontalAccuracy)
    }

    // MARK: - ═══ 🔦 手电筒 ═══

    func toggleFlashlight() -> Bool {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else { return false }
        do {
            try device.lockForConfiguration()
            device.torchMode = device.torchMode == .on ? .off : .on
            device.unlockForConfiguration()
            return true
        } catch { return false }
    }

    var isFlashlightOn: Bool {
        AVCaptureDevice.default(for: .video)?.torchMode == .on
    }

    // MARK: - ═══ 🔔 本地通知 ═══

    func scheduleNotification(title: String, body: String, seconds: TimeInterval = 5) async throws -> String {
        let center = UNUserNotificationCenter.current()
        let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        guard granted else { throw PhoneAgentError.permissionDenied("通知") }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, seconds), repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        try await center.add(request)
        return "✅ 通知已设置: \(Int(seconds))秒后提醒「\(title)」"
    }

    // MARK: - ═══ 📁 本地文件 ═══

    func listDocuments() -> [String] {
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let files = (try? fm.contentsOfDirectory(atPath: docs.path)) ?? []
        return files.sorted()
    }

    func readDocument(name: String) -> String? {
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = docs.appendingPathComponent(name)
        return try? String(contentsOf: url, encoding: .utf8)
    }

    func writeDocument(name: String, content: String) throws {
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = docs.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - ═══ 🔊 震动反馈 ═══

    func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    // MARK: - ═══ 🌐 屏幕亮度 ═══

    @MainActor
    func setBrightness(_ value: CGFloat) {
        UIScreen.main.brightness = max(0, min(1, value))
    }

    @MainActor
    var currentBrightness: CGFloat { UIScreen.main.brightness }
}

// MARK: - CLLocationManagerDelegate

extension iPhoneAgentService: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        lastLocation = locations.last
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("[Location] Error: \(error.localizedDescription)")
    }
}

// MARK: - Models

struct ContactInfo: Identifiable {
    let id = UUID()
    let name: String
    let organization: String
    let phones: [String]
    let emails: [String]

    var summary: String {
        var parts = [name]
        if !organization.isEmpty { parts.append(organization) }
        if let phone = phones.first { parts.append(phone) }
        return parts.joined(separator: " · ")
    }
}

struct EventInfo: Identifiable {
    let id = UUID()
    let title: String
    let startDate: Date
    let endDate: Date
    let location: String?
    let isAllDay: Bool
    let calendar: String

    var dateString: String {
        let f = DateFormatter()
        f.dateFormat = isAllDay ? "MM/dd" : "MM/dd HH:mm"
        return f.string(from: startDate)
    }
}

struct ReminderInfo: Identifiable {
    let id = UUID()
    let title: String
    let dueDate: Date?
    let priority: Int
    let isCompleted: Bool
    let list: String
}

struct PhotoStats {
    let photoCount: Int
    let videoCount: Int
}

enum PhoneAgentError: LocalizedError {
    case permissionDenied(String)
    case notSupported(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied(let what): return "未授权访问\(what)，请在设置中允许"
        case .notSupported(let what): return "\(what)不支持当前设备"
        }
    }
}

