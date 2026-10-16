import MapKit
import SwiftUI

/// Address search backed by MapKit's completer. Also understands pasted "lat, lon" pairs.
struct SearchField: View {
    var onPick: (CLLocationCoordinate2D, String) -> Void
    @State private var query = ""
    @State private var completer = Completer()
    @State private var searching = false
    /// Set when the field text is replaced by a picked suggestion, so that change does not
    /// start a new completion round and reopen the list.
    @State private var suppressNextUpdate = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(String(localized: "Search a place or paste coordinates"), text: $query)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { submit() }
                    .onChange(of: query) { _, new in
                        if suppressNextUpdate { suppressNextUpdate = false; return }
                        completer.update(new)
                    }
                if searching {
                    ProgressView().controlSize(.small)
                } else if !query.isEmpty {
                    Button { query = ""; completer.results = [] } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            if focused && !completer.results.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(completer.results.prefix(6), id: \.self) { item in
                        Button {
                            resolve(item)
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title).font(.callout).lineLimit(1)
                                if !item.subtitle.isEmpty {
                                    Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    private func submit() {
        if let c = Geo.parseCoordinate(query) {
            onPick(c, query)
            completer.results = []
            focused = false
            return
        }
        if let first = completer.results.first {
            resolve(first)
            return
        }
        searching = true
        Task {
            defer { searching = false }
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            if let item = try? await MKLocalSearch(request: request).start().mapItems.first {
                onPick(item.placemark.coordinate, item.name ?? query)
                completer.results = []
                focused = false
            }
        }
    }

    private func resolve(_ completion: MKLocalSearchCompletion) {
        searching = true
        Task {
            defer { searching = false }
            let request = MKLocalSearch.Request(completion: completion)
            if let item = try? await MKLocalSearch(request: request).start().mapItems.first {
                suppressNextUpdate = true
                query = completion.title
                completer.results = []
                focused = false
                onPick(item.placemark.coordinate, completion.title)
            }
        }
    }
}

@MainActor
@Observable
final class Completer: NSObject, MKLocalSearchCompleterDelegate {
    var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest, .query]
    }

    func update(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.count < 2 || Geo.parseCoordinate(trimmed) != nil {
            results = []
            return
        }
        completer.queryFragment = trimmed
    }

    // MKLocalSearchCompleter calls back on the main thread; its results are not Sendable,
    // so hop isolation synchronously instead of through a Task.
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        nonisolated(unsafe) let items = completer.results
        MainActor.assumeIsolated { self.results = items }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        MainActor.assumeIsolated { self.results = [] }
    }
}
