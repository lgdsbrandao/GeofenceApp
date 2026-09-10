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
    /// Where the route finishes. Further out than the start, and on the far
    /// side, because iOS only confirms an exit well beyond the boundary.
    var exitCoordinate: CLLocationCoordinate2D?
    /// The device's live position, or nil until the first fix lands.
    var userLocation: CLLocationCoordinate2D?
    /// Bumped whenever the app comes to the foreground. Each new value earns
    /// exactly one recentre on the user, so opening the app always lands on
    /// "where I am" without the map being yanked back mid-pan afterwards.
    var recenterToken: Int = 0

    /// How much ground the opening view covers, in metres.
    ///
    /// Wide enough to place yourself on a street grid, tight enough that a
    /// typical fence (50–500 m) would be visible if you were standing in one.
    private static let openingSpan = 800.0

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
            // No zone yet: the map belongs to the user's own position.
            //
            // `.follow` alone is not enough to promise it. It centres when a
            // fix first arrives, but does nothing for a map that already has a
            // region — coming back from a zone, or from the background — and
            // the user cancels it the moment they pan. So centre explicitly,
            // once per token, and only re-arm `.follow` at that same moment.
            context.coordinator.shownZoneID = nil
            if let here = userLocation,
               context.coordinator.centredForToken != recenterToken {
                context.coordinator.centredForToken = recenterToken
                map.setRegion(MKCoordinateRegion(center: here,
                                                 latitudinalMeters: Self.openingSpan,
                                                 longitudinalMeters: Self.openingSpan),
                              animated: true)
                map.userTrackingMode = .follow
            }
            return
        }
        map.userTrackingMode = .none
        // Leaving the zone behind should centre on the user again.
        context.coordinator.centredForToken = nil

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

            // The route runs in from the start, through the centre, and out
            // the far side — draw it that way rather than as a there-and-back
            // line, which would hide where the run actually ends.
            var line = [start, zone.coordinate]
            if let exit = exitCoordinate {
                line.append(exit)
                let endPin = MKPointAnnotation()
                endPin.coordinate = exit
                endPin.title = "End"
                map.addAnnotation(endPin)
            }
            map.addOverlay(MKPolyline(coordinates: line, count: line.count))
        }

        // Only recentre when the zone itself changes, so panning is not fought.
        if context.coordinator.shownZoneID != zone.id {
            context.coordinator.shownZoneID = zone.id
            // Fit the whole route, which now reaches further out one side
            // than the other, plus a margin so the pins are not on the edge.
            let reach = max(zone.startDistance, zone.exitDistance)
            let span = max(reach * 2.6, zone.radius * 4)
            map.setRegion(MKCoordinateRegion(center: zone.coordinate,
                                             latitudinalMeters: span,
                                             longitudinalMeters: span),
                          animated: true)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, MKMapViewDelegate {
        var shownZoneID: Int?
        /// The `recenterToken` this map has already centred for, so each
        /// foreground earns one recentre and no more.
        var centredForToken: Int?

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let circle = overlay as? MKCircle {
                let renderer = MKCircleRenderer(circle: circle)
                renderer.fillColor = UIColor.insiderPrimary.withAlphaComponent(0.16)
                renderer.strokeColor = UIColor.insiderPrimary
                renderer.lineWidth = 2
                return renderer
            }
            if let line = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: line)
                renderer.strokeColor = UIColor.insiderHitPink
                renderer.lineWidth = 3
                renderer.lineDashPattern = [4, 6]
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard !(annotation is MKUserLocation) else { return nil }
            let view = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "zone")
            let title = annotation.title ?? nil
            let isStart = title == "Start"
            let isEnd = title == "End"
            view.markerTintColor = (isStart || isEnd) ? .insiderHitPink : .insiderPrimary
            view.glyphImage = UIImage(systemName: isStart ? "figure.walk"
                                      : isEnd ? "flag.checkered" : "mappin")
            view.displayPriority = .required
            return view
        }
    }
}
