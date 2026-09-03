import CoreLocation
import Foundation
import OSLog
import WeatherKit

/// セッション開始時に取れた環境の観測値。`Session` へ書き戻すための**値**。
///
/// `@Model` はどのアクターへも安全に渡せないので、取得側は Sendable な値だけを返し、
/// SwiftData への書き込みは呼び出し元（`ChronoService`、`@MainActor`）が行う。
struct EnvironmentSnapshot: Sendable {
    var temperatureC: Double?
    /// 相対湿度 0–1（WeatherKit と同じスケール）。
    var humidity: Double?
    var pressureHPa: Double?
    var conditionSymbol: String?
    var conditionText: String?
    var placeName: String?
    var latitude: Double?
    var longitude: Double?
    var fetchedAt: Date = Date()
}

/// 現在地の気象を 1 回だけ取ってくる。
///
/// 方針:
/// - **計測を絶対に待たせない。** 呼び出しは切り離したタスクから行い、ここが何秒
///   掛かっても、失敗しても、ショットの取り込みには影響しない。
/// - 失敗（未許可・オフライン・エンタイトルメント未反映）は `nil` を返すだけで、
///   ユーザーには何も出さない。debug レベルのログにだけ残す。
enum SessionEnvironmentService {
    private static let log = Logger(subsystem: "com.yhakamay.acechrono", category: "environment")

    /// 位置情報の待ち時間の上限。許可ダイアログを出したまま放置されても、
    /// 継続を宙吊りにしないための保険。
    private static let locationTimeout: Duration = .seconds(20)

    static func currentConditions() async -> EnvironmentSnapshot? {
        #if targetEnvironment(simulator)
        // シミュレータでは WeatherKit のエンタイトルメントが効かず、値が取れない。
        // UI を目で確かめられるように、**リプレイ（--replay-capture）のときだけ**
        // 見本の値を返す。実機のコードパスには一切入らない。
        if ReplaySupport.source == .capture {
            log.debug("simulator + --replay-capture: 見本の気象値を使う")
            return sampleSnapshot
        }
        #endif

        guard let location = await OneShotLocation().current(timeout: locationTimeout) else {
            log.debug("位置情報が取れなかったので気象は記録しない")
            return nil
        }

        var snapshot = EnvironmentSnapshot(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude
        )
        snapshot.placeName = await placeName(for: location)

        do {
            let current = try await WeatherService.shared.weather(for: location, including: .current)
            snapshot.temperatureC = current.temperature.converted(to: .celsius).value
            snapshot.humidity = current.humidity
            snapshot.pressureHPa = current.pressure.converted(to: .hectopascals).value
            snapshot.conditionSymbol = current.symbolName
            snapshot.conditionText = current.condition.description
        } catch {
            // エンタイトルメントの反映待ち・オフライン・レート制限などで普通に失敗する。
            // 位置と地名だけは取れているので、それだけ残す。
            log.debug("WeatherKit から取得できなかった: \(error.localizedDescription, privacy: .public)")
        }
        return snapshot
    }

    /// 逆ジオコーディングした地名。取れなくても構わないので失敗は握りつぶす。
    private static func placeName(for location: CLLocation) async -> String? {
        let placemarks = try? await CLGeocoder().reverseGeocodeLocation(location)
        guard let placemark = placemarks?.first else { return nil }
        return placemark.locality
            ?? placemark.subAdministrativeArea
            ?? placemark.administrativeArea
            ?? placemark.name
    }

    #if targetEnvironment(simulator)
    /// シミュレータ確認用の見本。**実機では絶対に使われない。**
    private static var sampleSnapshot: EnvironmentSnapshot {
        EnvironmentSnapshot(
            temperatureC: 23.4,
            humidity: 0.58,
            pressureHPa: 1013.2,
            conditionSymbol: "cloud.sun.fill",
            conditionText: String(localized: "晴れ時々くもり"),
            placeName: String(localized: "見本の場所"),
            latitude: 35.6812,
            longitude: 139.7671
        )
    }
    #endif
}

/// 位置を 1 回だけ取る小さなラッパ。
///
/// `CLLocationManager` はデリゲート方式なので、`async` から使うために継続で包む。
/// 生成もデリゲート受信もメインアクタ上に固定して、状態の共有を無くしている。
@MainActor
private final class OneShotLocation: NSObject {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation?, Never>?
    private var timeoutTask: Task<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
        // 気象を引くだけなので町 1 つ分の精度で足りる。GPS を起こさないほうが速く、電池も減らない。
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func current(timeout: Duration) async -> CLLocation? {
        switch manager.authorizationStatus {
        case .restricted, .denied:
            return nil
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        default:
            break
        }

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.finish(with: nil)
            }
            requestIfAuthorized()
        }
    }

    /// 許可済みなら測位を始める。未決定のうちは `locationManagerDidChangeAuthorization` を待つ。
    private func requestIfAuthorized() {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        case .restricted, .denied:
            finish(with: nil)
        default:
            break
        }
    }

    private func finish(with location: CLLocation?) {
        timeoutTask?.cancel()
        timeoutTask = nil
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: location)
    }
}

extension OneShotLocation: CLLocationManagerDelegate {
    // デリゲートは `CLLocationManager` を作ったスレッド（= メイン）で呼ばれる。
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated { finish(with: locations.last) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated { finish(with: nil) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated { requestIfAuthorized() }
    }
}
