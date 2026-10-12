import SwiftUI

/// Multi-select library filters over /Items/Filters values
/// (Fladder's filter chips, sheet form).
struct LibraryFilterSheet: View {
    @Bindable var model: LibraryGridModel
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                #if os(tvOS)
                // The TV has no toolbar to hang Sort or Done on: both live in
                // the form, where the remote can reach them. Menu also closes.
                Section {
                    Button("Done") { dismiss() }
                    Button("Clear All") { model.clearFilters() }
                        .disabled(model.activeFilterCount == 0)
                }
                Section("Sort") {
                    Picker("Sort by", selection: $model.sort) {
                        ForEach(LibraryGridModel.Sort.allCases) { sort in
                            Text(sort.label).tag(sort)
                        }
                    }
                    Picker("Order", selection: $model.ascending) {
                        Text("Ascending").tag(true)
                        Text("Descending").tag(false)
                    }
                }
                #endif

                Section {
                    Toggle("Favorites only", isOn: $model.favoritesOnly)
                    Toggle("Unwatched only", isOn: $model.unplayedOnly)
                }

                if let genres = model.availableFilters?.genres, !genres.isEmpty {
                    multiSelectSection(title: "Genres", values: genres, selection: $model.selectedGenres)
                }
                if let ratings = model.availableFilters?.officialRatings, !ratings.isEmpty {
                    multiSelectSection(title: "Parental Ratings", values: ratings, selection: $model.selectedRatings)
                }
                if let years = model.availableFilters?.years, !years.isEmpty {
                    yearsSection(years: years)
                }
                if let tags = model.availableFilters?.tags, !tags.isEmpty {
                    multiSelectSection(title: "Tags", values: tags, selection: $model.selectedTags)
                }

                if model.availableFilters == nil {
                    Section {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Loading filter values…")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(sheetTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            #if !os(tvOS)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear All") {
                        model.clearFilters()
                    }
                    .disabled(model.activeFilterCount == 0)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            #endif
            .task {
                guard let client = app.client else { return }
                await model.loadAvailableFilters(client: client)
            }
        }
    }

    private var sheetTitle: String {
        #if os(tvOS)
        "Sort & Filter"
        #else
        "Filters"
        #endif
    }

    private func multiSelectSection(
        title: String,
        values: [String],
        selection: Binding<Set<String>>
    ) -> some View {
        Section(title) {
            ForEach(values, id: \.self) { value in
                Button {
                    if selection.wrappedValue.contains(value) {
                        selection.wrappedValue.remove(value)
                    } else {
                        selection.wrappedValue.insert(value)
                    }
                } label: {
                    HStack {
                        Text(value)
                            .foregroundStyle(.primary)
                        Spacer()
                        if selection.wrappedValue.contains(value) {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func yearsSection(years: [Int]) -> some View {
        Section("Years") {
            ForEach(years.sorted(by: >), id: \.self) { year in
                Button {
                    if model.selectedYears.contains(year) {
                        model.selectedYears.remove(year)
                    } else {
                        model.selectedYears.insert(year)
                    }
                } label: {
                    HStack {
                        Text(String(year))
                            .foregroundStyle(.primary)
                        Spacer()
                        if model.selectedYears.contains(year) {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
