//
//  ZoneMapView.swift
//  InsiderGeofence
//
//  Created by lgsbrandao.
//  Copyright (c) lgsbrandao. All rights reserved.

import SwiftUI
import MapKit

/// Map that draws the zone the way the test actually sees it: the real radius
/// as a filled circle, the out-and-back route, and the live position.
///
/// SwiftUI's `Map` cannot render a circle sized in metres before iOS 17, and a
/// circle is the whole point here — you need to see where the boundary is.
struct ZoneMapView: UIViewRepresentable {
    var zone: InsiderZone?
    var startCoordinate: CLLocationCoordinate2D?

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.userTrackingMode = .follow   // until a zone is chosen
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        map.removeOverlays(map.overlays)
        map.removeAnnotations(map.annotations.filter { !($0 is MKUserLocation) })

        guard let zone = zone else {
            map.userTrackingMode = .follow
            context.coordinator.shownZoneID = nil
            return
        }
        map.userTrackingMode = .none

        map.addOverlay(MKCircle(center: zone.coordinate, radius: zone.radius))

        let centre = MKPointAnnotation()
        centre.coordinate = zone.coordinate
        centre.title = zone.identifier
        map.addAnnotation(centre)

        if let start = startCoordinate {
            let pin = MKPointAnnotation()
            pin.coordinate = start
            pin.title = "Start"
            map.addAnnotation(pin)
            map.addOverlay(MKPolyline(coordinates: [start, zone.coordinate], count: 2))
        }

        // Only recentre when the zone itself changes, so panning is not fought.
        if context.coordinator.shownZoneID != zone.id {
            context.coordinator.shownZoneID = zone.id
            let span = zone.radius * 4
            map.setRegion(MKCoordinateRegion(center: zone.coordinate,
                                             latitudinalMeters: span,
                                             longitudinalMeters: span),
                          animated: true)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, MKMapViewDelegate {
        var shownZoneID: Int?

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let circle = overlay as? MKCircle {
                let renderer = MKCircleRenderer(circle: circle)
                renderer.fillColor = UIColor.systemBlue.withAlphaComponent(0.18)
                renderer.strokeColor = UIColor.systemBlue
                renderer.lineWidth = 2
                return renderer
            }
            if let line = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: line)
                renderer.strokeColor = UIColor.systemOrange
                renderer.lineWidth = 3
                renderer.lineDashPattern = [4, 6]
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard !(annotation is MKUserLocation) else { return nil }
            let view = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "zone")
            let isStart = annotation.title == "Start"
            view.markerTintColor = isStart ? .systemGreen : .systemRed
            view.glyphImage = UIImage(systemName: isStart ? "figure.walk" : "mappin")
            view.displayPriority = .required
            return view
        }
    }
}
