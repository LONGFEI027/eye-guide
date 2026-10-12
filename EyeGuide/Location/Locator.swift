import CoreLocation

/// 定位：只取"城市·街区"级别的粗位置，注入对话上下文，回答"我现在在哪"。
/// 精确坐标不进提示词、不存储。
final class Locator: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var place = ""            // 例如"上海·武康路街区"

    private let manager = CLLocationManager()

    func request() {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        manager.requestWhenInUseAuthorization()
        manager.requestLocation()
    }

    func locationManager(_ m: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        if status == .authorizedWhenInUse || status == .authorizedAlways { m.requestLocation() }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let loc = locs.last else { return }
        CLGeocoder().reverseGeocodeLocation(loc) { placemarks, _ in
            guard let p = placemarks?.first else { return }
            let text = [p.locality, p.subLocality].compactMap { $0 }.joined(separator: "·")
            DispatchQueue.main.async { self.place = text }
        }
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {}
}
