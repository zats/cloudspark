import AppKit
import Foundation
import MapKit
import SwiftUI

struct RequestDistributionMapCard: View {
    let rows: [DashboardRequestDistributionRow]

    @State private var resolvedRows: [ResolvedRequestDistributionRow] = []
    @State private var isLoading = false

    var body: some View {
        Group {
            if rows.isEmpty {
                Text("No request distribution data")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 240)
            } else if resolvedRows.isEmpty && isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 240)
            } else if resolvedRows.isEmpty {
                Text("Unable to resolve colocation coordinates")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 240)
            } else {
                RequestDistributionMapRepresentable(rows: resolvedRows)
                    .frame(minHeight: 240)
            }
        }
        .task(id: rows.map(\.id).joined(separator: ",")) {
            await resolveRows()
        }
    }

    private func resolveRows() async {
        isLoading = true
        let resolved = await AirportCoordinateStore.shared.resolve(rows: Array(rows.prefix(20)))
        resolvedRows = resolved
        isLoading = false
    }
}

private struct ResolvedRequestDistributionRow: Identifiable {
    let id: String
    let coloCode: String
    let requests: Int
    let coordinate: CLLocationCoordinate2D
}

private struct RequestDistributionMapRepresentable: NSViewRepresentable {
    let rows: [ResolvedRequestDistributionRow]

    func makeNSView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.mapType = .mutedStandard
        mapView.isRotateEnabled = false
        mapView.showsZoomControls = true
        mapView.delegate = context.coordinator
        return mapView
    }

    func updateNSView(_ mapView: MKMapView, context: Context) {
        mapView.removeOverlays(mapView.overlays)
        let overlays = rows.map { row -> MKCircle in
            let circle = MKCircle(
                center: row.coordinate,
                radius: RequestDistributionMapMetrics.radius(for: row.requests, maxRequests: rows.map(\.requests).max() ?? row.requests)
            )
            circle.title = row.coloCode
            return circle
        }
        mapView.addOverlays(overlays)

        if let region = RequestDistributionMapMetrics.region(for: rows) {
            mapView.setRegion(region, animated: false)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
            guard let circle = overlay as? MKCircle else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let renderer = MKCircleRenderer(circle: circle)
            renderer.fillColor = NSColor.systemOrange.withAlphaComponent(0.28)
            renderer.strokeColor = NSColor.systemOrange.withAlphaComponent(0.5)
            renderer.lineWidth = 1
            return renderer
        }
    }
}

private enum RequestDistributionMapMetrics {
    static func region(for rows: [ResolvedRequestDistributionRow]) -> MKCoordinateRegion? {
        guard !rows.isEmpty else { return nil }
        let latitudes = rows.map(\.coordinate.latitude)
        let longitudes = rows.map(\.coordinate.longitude)
        guard let minLat = latitudes.min(),
              let maxLat = latitudes.max(),
              let minLon = longitudes.min(),
              let maxLon = longitudes.max()
        else {
            return nil
        }

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max(25, (maxLat - minLat) * 1.8),
            longitudeDelta: max(45, (maxLon - minLon) * 1.8)
        )
        return MKCoordinateRegion(center: center, span: span)
    }

    static func radius(for requests: Int, maxRequests: Int) -> CLLocationDistance {
        guard maxRequests > 0 else { return 40_000 }
        let normalized = sqrt(Double(requests) / Double(maxRequests))
        return 35_000 + normalized * 550_000
    }
}

private actor AirportCoordinateStore {
    static let shared = AirportCoordinateStore()

    private var coordinatesByIATA: [String: CLLocationCoordinate2D] = [:]
    private var hasLoaded = false

    func resolve(rows: [DashboardRequestDistributionRow]) async -> [ResolvedRequestDistributionRow] {
        await ensureLoaded()
        return rows.compactMap { row in
            guard let coordinate = coordinatesByIATA[row.coloCode.uppercased()] else {
                return nil
            }
            return ResolvedRequestDistributionRow(
                id: row.id,
                coloCode: row.coloCode,
                requests: row.requests,
                coordinate: coordinate
            )
        }
    }

    private func ensureLoaded() async {
        guard !hasLoaded else { return }
        hasLoaded = true

        guard let url = URL(string: "https://raw.githubusercontent.com/mwgg/Airports/master/airports.json") else {
            return
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else {
                return
            }
            var resolved: [String: CLLocationCoordinate2D] = [:]
            for airport in object.values {
                guard let iata = airport["iata"] as? String,
                      iata.count == 3,
                      let lat = airport["lat"] as? Double,
                      let lon = airport["lon"] as? Double
                else {
                    continue
                }
                resolved[iata.uppercased()] = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            }
            coordinatesByIATA = resolved
        } catch {
        }
    }
}
