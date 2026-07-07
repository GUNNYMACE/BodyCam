//
//  BodyCamTelemetry.swift
//  BodyCam
//

import CoreLocation
import Foundation
import Observation

@Observable
final class BodyCamTelemetry: NSObject, CLLocationManagerDelegate {
    private(set) var currentDate = Date()
    private(set) var coordinate: CLLocationCoordinate2D?
    private(set) var locationStatusMessage = "Locating"

    @ObservationIgnored private let locationManager = CLLocationManager()

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func start() {
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()
    }

    func refreshClock() {
        currentDate = Date()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            locationStatusMessage = "Location active"
            manager.startUpdatingLocation()
        case .denied, .restricted:
            locationStatusMessage = "Location unavailable"
            coordinate = nil
        case .notDetermined:
            locationStatusMessage = "Locating"
        @unknown default:
            locationStatusMessage = "Location unavailable"
            coordinate = nil
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        coordinate = location.coordinate
        locationStatusMessage = "Location active"
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        locationStatusMessage = "Location unavailable"
    }
}
