import Foundation
import Photos
import Combine

// MARK: - RegisteredPerson

struct RegisteredPerson: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var photoIDs: [String]   // PHAsset.localIdentifier のリスト

    init(id: UUID = UUID(), name: String, photoIDs: [String] = []) {
        self.id = id
        self.name = name
        self.photoIDs = photoIDs
    }
}

// MARK: - PersonRegistry

final class PersonRegistry: ObservableObject {
    static let shared = PersonRegistry()

    @Published private(set) var persons: [RegisteredPerson] = []

    private let udKey = "photoCurator.registeredPersons"

    private init() { load() }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: udKey),
              let decoded = try? JSONDecoder().decode([RegisteredPerson].self, from: data)
        else { return }
        persons = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(persons) {
            UserDefaults.standard.set(data, forKey: udKey)
        }
    }

    // MARK: - Person CRUD

    @discardableResult
    func addPerson(name: String) -> RegisteredPerson {
        let person = RegisteredPerson(name: name)
        persons.append(person)
        save()
        return person
    }

    func renamePerson(id: UUID, newName: String) {
        guard let i = persons.firstIndex(where: { $0.id == id }) else { return }
        persons[i].name = newName
        save()
    }

    func deletePerson(id: UUID) {
        persons.removeAll { $0.id == id }
        save()
    }

    // MARK: - Tagging

    func tagPhoto(assetID: String, personID: UUID) {
        guard let i = persons.firstIndex(where: { $0.id == personID }) else { return }
        guard !persons[i].photoIDs.contains(assetID) else { return }
        persons[i].photoIDs.append(assetID)
        save()
    }

    func untagPhoto(assetID: String, personID: UUID) {
        guard let i = persons.firstIndex(where: { $0.id == personID }) else { return }
        persons[i].photoIDs.removeAll { $0 == assetID }
        save()
    }

    func isTagged(assetID: String, personID: UUID) -> Bool {
        persons.first(where: { $0.id == personID })?.photoIDs.contains(assetID) ?? false
    }

    func taggedPersons(for assetID: String) -> [RegisteredPerson] {
        persons.filter { $0.photoIDs.contains(assetID) }
    }
}
