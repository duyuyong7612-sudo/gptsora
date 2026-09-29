// AduPerceptionManager.swift
// ChatAGI-阿杜 感知模块 — 按需调用式
// ────────────────────────────────────────────────
// 设计理念：不后台轮询，LLM 需要时才读传感器
// 用户问"你在哪" → LLM tool call → iOS 读 GPS/指南针/运动/摄像头 → 返回结果
// ────────────────────────────────────────────────

// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-c18f1c7b3a2ebe349f280260e0b1dabadf3603c91d7d262a22d6fcb7a496e543"
// Source-SHA256: "14b9354e2db7f607e94a844a5f734f92fce953401d0e3bcdaa4e41cd8080b747"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation
import Combine
import CoreLocation
import CoreMotion
import AVFoundation
import UIKit

// MARK: - 感知快照

struct PerceptionSnapshot: Codable {
    let timestamp: String
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let speed: Double
    let horizontalAccuracy: Double
    let country: String?
    let city: String?
    let district: String?
    let street: String?
    let streetNumber: String?
    let poiName: String?
    let fullAddress: String?
    let heading: Double
    let headingDescription: String
    let motionState: String
    let sceneDescription: String?  // V2: 摄像头 VLM 分析结果
    let geocodeSource: String?     // "Apple" / "Google" / "none" — 门牌号数据来源
}


// MARK: - 感知管理器（按需调用式）

class AduPerceptionManager: NSObject, ObservableObject {
    static let shared = AduPerceptionManager()
    
    @Published var lastSnapshot: PerceptionSnapshot?
    @Published var isReading = false
    
    private let locationManager = CLLocationManager()
    private let motionManager = CMMotionActivityManager()
    private let geocoder = CLGeocoder()
    
    // Google Geocoding fallback（API Key 从 Info.plist 读取，不硬编码）
    private var googleGeoAPIKey: String {
        Bundle.main.object(forInfoDictionaryKey: "GOOGLE_MAPS_API_KEY") as? String ?? ""
    }
    
    // 单次读取的临时状态
    private var readCompletion: ((PerceptionSnapshot?) -> Void)?
    private var pendingLocation: CLLocation?
    private var pendingHeading: CLHeading?
    private var pendingMotion: String = "未知"
    private var readTimeout: DispatchWorkItem?
    private var isFinishing = false  // 防止重复完成
    
    private override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation  // 最高精度：GPS+WiFi+蜂窝
    }
    
    // MARK: - 权限
    
    func requestPermissionIfNeeded() {
        let status = locationManager.authorizationStatus
        if status == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
    }
    
    var hasPermission: Bool {
        let status = locationManager.authorizationStatus
        return status == .authorizedWhenInUse || status == .authorizedAlways
    }
    
    // MARK: - 核心：按需读取一次感知
    
    /// 被 LLM tool call 触发，读取所有传感器，反向地理编码，返回完整快照
    /// 超时 8 秒自动返回已有数据
    func readOnce(completion: @escaping (PerceptionSnapshot?) -> Void) {
        guard hasPermission else {
            print("[Perception] 无定位权限")
            completion(nil)
            return
        }
        
        // 防止并发调用
        if isReading {
            print("[Perception] 正在读取中，忽略重复调用")
            completion(nil)
            return
        }
        
        isReading = true
        isFinishing = false
        readCompletion = completion
        pendingLocation = nil
        pendingHeading = nil
        pendingMotion = "未知"
        
        // 启动传感器
        locationManager.startUpdatingLocation()
        locationManager.startUpdatingHeading()
        
        // 运动状态（需要 Motion 权限，未授权时跳过不崩溃）
        if CMMotionActivityManager.isActivityAvailable() {
            var motionAllowed = true
            if #available(iOS 11.0, *) {
                motionAllowed = (CMMotionActivityManager.authorizationStatus() == .authorized)
            }
            if motionAllowed {
                motionManager.startActivityUpdates(to: .main) { [weak self] activity in
                    guard let activity = activity else { return }
                    self?.pendingMotion = Self.describeActivity(activity)
                    self?.motionManager.stopActivityUpdates()
                }
            } else {
                print("[Perception] Motion 权限未授予，跳过运动检测")
            }
        }
        
        // 超时保护：8 秒后强制返回
        let timeout = DispatchWorkItem { [weak self] in
            print("[Perception] 超时，强制返回")
            self?.finishReading()
        }
        readTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
    }
    
    /// async/await 版本
    func readOnceAsync() async -> PerceptionSnapshot? {
        await withCheckedContinuation { cont in
            readOnce { snapshot in
                cont.resume(returning: snapshot)
            }
        }
    }
    
    // MARK: - 完成读取
    
    private func finishReading() {
        guard !isFinishing else { return }
        isFinishing = true
        
        // 停止传感器
        locationManager.stopUpdatingLocation()
        locationManager.stopUpdatingHeading()
        readTimeout?.cancel()
        readTimeout = nil
        
        guard let loc = pendingLocation else {
            print("[Perception] 未获取到位置")
            DispatchQueue.main.async {
                self.isReading = false
                self.readCompletion?(nil)
                self.readCompletion = nil
            }
            return
        }
        
        // Step 1: Apple 反向地理编码
        geocoder.reverseGeocodeLocation(loc) { [weak self] placemarks, error in
            guard let self = self else { return }
            
            if let error = error {
                print("[Perception] Apple地理编码失败: \(error.localizedDescription)")
            }
            
            let pm = placemarks?.first
            
            print("[Perception] Apple: country=\(pm?.country ?? "nil") city=\(pm?.locality ?? "nil") street=\(pm?.thoroughfare ?? "nil") number=\(pm?.subThoroughfare ?? "nil") name=\(pm?.name ?? "nil") accuracy=\(loc.horizontalAccuracy)m")
            
            // Step 2: Apple 没拿到门牌号 → Google Geocoding fallback
            let appleHasStreetNumber = (pm?.subThoroughfare != nil)
            
            if !appleHasStreetNumber && !self.googleGeoAPIKey.isEmpty {
                print("[Perception] Apple无门牌号，触发Google Geocoding fallback...")
                self.googleReverseGeocode(lat: loc.coordinate.latitude,
                                          lng: loc.coordinate.longitude) { googleResult in
                    let finalSnapshot = self.buildSnapshot(
                        location: loc,
                        applePlacemark: pm,
                        googleResult: googleResult
                    )
                    self.deliverSnapshot(finalSnapshot, location: loc)
                }
            } else {
                if self.googleGeoAPIKey.isEmpty && !appleHasStreetNumber {
                    print("[Perception] ⚠️ Google API Key 未配置，跳过 fallback（请在 Info.plist 添加 GOOGLE_MAPS_API_KEY）")
                }
                let snapshot = self.buildSnapshot(
                    location: loc,
                    applePlacemark: pm,
                    googleResult: nil
                )
                self.deliverSnapshot(snapshot, location: loc)
            }
        }
    }
    
    // MARK: - Google Geocoding Fallback
    
    private struct GoogleGeoResult {
        let streetNumber: String?
        let route: String?           // 街道名
        let formattedAddress: String?
    }
    
    private func googleReverseGeocode(
        lat: Double, lng: Double,
        completion: @escaping (GoogleGeoResult?) -> Void
    ) {
        let urlStr = "https://maps.googleapis.com/maps/api/geocode/json?latlng=\(lat),\(lng)&key=\(googleGeoAPIKey)&language=zh-CN&result_type=street_address"
        
        guard let url = URL(string: urlStr) else {
            print("[Perception] Google URL 无效")
            completion(nil)
            return
        }
        
        let task = URLSession.shared.dataTask(with: url) { data, response, error in
            guard let data = data, error == nil else {
                print("[Perception] Google请求失败: \(error?.localizedDescription ?? "unknown")")
                completion(nil)
                return
            }
            
            do {
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let results = json["results"] as? [[String: Any]],
                      let first = results.first else {
                    let status = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["status"] as? String
                    print("[Perception] Google无结果, status=\(status ?? "unknown")")
                    completion(nil)
                    return
                }
                
                let formatted = first["formatted_address"] as? String
                var streetNumber: String?
                var route: String?
                
                if let components = first["address_components"] as? [[String: Any]] {
                    for comp in components {
                        guard let types = comp["types"] as? [String],
                              let longName = comp["long_name"] as? String else { continue }
                        if types.contains("street_number") {
                            streetNumber = longName
                        }
                        if types.contains("route") {
                            route = longName
                        }
                    }
                }
                
                print("[Perception] Google✅: number=\(streetNumber ?? "nil") route=\(route ?? "nil") addr=\(formatted ?? "nil")")
                completion(GoogleGeoResult(
                    streetNumber: streetNumber,
                    route: route,
                    formattedAddress: formatted
                ))
                
            } catch {
                print("[Perception] Google JSON解析失败: \(error)")
                completion(nil)
            }
        }
        task.resume()
    }
    
    // MARK: - 构建快照（合并 Apple + Google 结果）
    
    private func buildSnapshot(
        location loc: CLLocation,
        applePlacemark pm: CLPlacemark?,
        googleResult: GoogleGeoResult?
    ) -> PerceptionSnapshot {
        // 门牌号：Apple 优先，不行用 Google
        let streetNumber = pm?.subThoroughfare ?? googleResult?.streetNumber
        // 街道：Apple 优先
        let street = pm?.thoroughfare ?? googleResult?.route
        // 完整地址：Apple 有门牌就用 Apple 拼的，否则用 Google 的
        let fullAddress: String?
        if pm?.subThoroughfare != nil {
            fullAddress = self.formatAddress(pm)
        } else if let gAddr = googleResult?.formattedAddress {
            fullAddress = gAddr
        } else {
            fullAddress = self.formatAddress(pm)
        }
        
        let source = (pm?.subThoroughfare != nil) ? "Apple" : (googleResult?.streetNumber != nil ? "Google" : "none")
        
        return PerceptionSnapshot(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            latitude: loc.coordinate.latitude,
            longitude: loc.coordinate.longitude,
            altitude: loc.altitude,
            speed: max(loc.speed, 0),
            horizontalAccuracy: loc.horizontalAccuracy,
            country: pm?.country,
            city: pm?.locality,
            district: pm?.subLocality,
            street: street,
            streetNumber: streetNumber,
            poiName: pm?.name,
            fullAddress: fullAddress,
            heading: self.pendingHeading?.magneticHeading ?? -1,
            headingDescription: Self.describeHeading(
                self.pendingHeading?.magneticHeading ?? -1
            ),
            motionState: self.pendingMotion,
            sceneDescription: nil,
            geocodeSource: source       // 新增：标记地址数据来源
        )
    }
    
    // MARK: - 交付快照
    
    private func deliverSnapshot(_ snapshot: PerceptionSnapshot, location loc: CLLocation) {
        DispatchQueue.main.async {
            self.lastSnapshot = snapshot
            self.isReading = false
            self.readCompletion?(snapshot)
            self.readCompletion = nil
            print("[Perception] ✅ 完成[\(snapshot.geocodeSource ?? "?")]: \(snapshot.fullAddress ?? "坐标") #\(snapshot.streetNumber ?? "无门牌") 精度\(String(format:"%.1f", loc.horizontalAccuracy))m 朝\(snapshot.headingDescription)")
        }
    }
    
    // MARK: - 工具函数
    
    private func formatAddress(_ pm: CLPlacemark?) -> String? {
        guard let pm = pm else { return nil }
        
        // Apple 的 name 经常是最完整的（如 "38245 15th St E"）
        // 如果 name 包含数字，很可能就是门牌号+街道，优先用它
        if let name = pm.name, name.contains(where: { $0.isNumber }),
           let city = pm.locality {
            var parts: [String] = []
            if let country = pm.country { parts.append(country) }
            if let state = pm.administrativeArea { parts.append(state) }
            parts.append(city)
            if let district = pm.subLocality { parts.append(district) }
            parts.append(name)  // 用 name 替代 street + number
            return parts.joined(separator: " ")
        }
        
        // 标准拼接
        var parts: [String] = []
        if let country = pm.country { parts.append(country) }
        if let state = pm.administrativeArea { parts.append(state) }
        if let city = pm.locality { parts.append(city) }
        if let district = pm.subLocality { parts.append(district) }
        if let street = pm.thoroughfare { parts.append(street) }
        if let number = pm.subThoroughfare { parts.append(number) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
    
    static func describeHeading(_ degrees: Double) -> String {
        guard degrees >= 0 else { return "未知" }
        let dirs = ["北", "东北", "东", "东南", "南", "西南", "西", "西北"]
        let idx = Int((degrees + 22.5).truncatingRemainder(dividingBy: 360) / 45)
        return dirs[idx % 8]
    }
    
    static func describeActivity(_ activity: CMMotionActivity) -> String {
        if activity.automotive { return "驾车" }
        if activity.cycling { return "骑行" }
        if activity.running { return "跑步" }
        if activity.walking { return "步行" }
        if activity.stationary { return "静止" }
        return "未知"
    }
}


// MARK: - CLLocationManagerDelegate

extension AduPerceptionManager: CLLocationManagerDelegate {
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last, isReading else { return }
        // 精度 < 100m 才接受
        if loc.horizontalAccuracy > 0 && loc.horizontalAccuracy < 100 {
            pendingLocation = loc
            // GPS + 朝向都拿到了（或设备不支持朝向），完成
            if pendingHeading != nil || !CLLocationManager.headingAvailable() {
                finishReading()
            }
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard isReading else { return }
        pendingHeading = newHeading
        if pendingLocation != nil {
            finishReading()
        }
    }
    
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // 不主动操作，等下次 readOnce
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("[Perception] 定位失败: \(error.localizedDescription)")
        finishReading()
    }
}


// MARK: - WebSocket tool call 桥接

extension AduPerceptionManager {
    
    /// 处理后端发来的 get_perception tool call
    /// 读传感器 → 返回 JSON → 后端注入 LLM 上下文
    func handlePerceptionToolCall(
        sendResult: @escaping (String) -> Void
    ) {
        readOnce { snapshot in
            guard let snapshot = snapshot else {
                sendResult("{\"error\": \"无法获取位置，请检查定位权限\"}")
                return
            }
            
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            guard let data = try? encoder.encode(snapshot),
                  let json = String(data: data, encoding: .utf8) else {
                sendResult("{\"error\": \"编码失败\"}")
                return
            }
            sendResult(json)
        }
    }
}
