import Foundation

struct SummaryTemplate: Identifiable, Hashable {
    let id: String
    let name: String
    let icon: String
    let instructions: String
    var isCustom: Bool = false

    /// Modelli predefiniti + quelli creati dall'utente.
    static func available(custom: [CustomTemplate]) -> [SummaryTemplate] {
        all + custom.sorted { $0.createdAt < $1.createdAt }.map(\.asTemplate)
    }

    static let icons = ["star", "person.3", "megaphone", "building.2", "person.2", "doc.text", "note.text",
                        "cross.case", "stethoscope", "calendar", "envelope", "list.bullet.clipboard",
                        "scalemass", "exclamationmark.bubble", "graduationcap", "phone"]

    static let commonRules = """
    Scrivi sempre in italiano, in modo chiaro e sintetico.
    Usa solo informazioni presenti nella trascrizione: non inventare nomi, numeri, date o impegni.
    Se un'informazione manca o non è chiara, scrivi "non specificato".
    La trascrizione è automatica e può contenere errori di riconoscimento: correggi solo quelli evidenti.
    Chiudi sempre con la sezione "Azioni da fare": elenco puntato con cosa, chi e quando (se detti).
    """

    static let all: [SummaryTemplate] = [
        SummaryTemplate(
            id: "riunione",
            name: "Riunione",
            icon: "person.3",
            instructions: """
            Riassumi una riunione di lavoro con queste sezioni:
            1. In sintesi (3-5 righe)
            2. Argomenti discussi (elenco puntato, uno per tema)
            3. Decisioni prese
            4. Questioni aperte
            5. Azioni da fare
            """
        ),
        SummaryTemplate(
            id: "assemblea",
            name: "Assemblea",
            icon: "megaphone",
            instructions: """
            Riassumi un'assemblea sindacale dei lavoratori con queste sezioni:
            1. In sintesi (3-5 righe)
            2. Temi presentati dai relatori
            3. Interventi dei lavoratori: problemi e richieste emersi (raggruppati per tema)
            4. Proposte e mandati votati o condivisi
            5. Questioni aperte
            6. Azioni da fare
            """
        ),
        SummaryTemplate(
            id: "trattativa",
            name: "Incontro con l'azienda",
            icon: "building.2",
            instructions: """
            Riassumi un incontro o una trattativa tra sindacato e azienda con queste sezioni:
            1. In sintesi (3-5 righe)
            2. Posizioni e richieste della parte sindacale
            3. Posizioni e risposte dell'azienda
            4. Punti di accordo raggiunti
            5. Punti di disaccordo o rinviati
            6. Prossimi passi e date
            7. Azioni da fare
            Riporta con precisione numeri, scadenze, riferimenti a contratti, leggi o accordi citati.
            """
        ),
        SummaryTemplate(
            id: "colloquio",
            name: "Colloquio individuale",
            icon: "person.2",
            instructions: """
            Riassumi un colloquio con un lavoratore o una lavoratrice con queste sezioni:
            1. Motivo del colloquio
            2. Situazione descritta (fatti, date, persone coinvolte)
            3. Richieste della persona
            4. Indicazioni e informazioni date
            5. Documenti da raccogliere o verificare
            6. Azioni da fare
            Mantieni un tono neutro e riservato.
            """
        ),
        SummaryTemplate(
            id: "verbale",
            name: "Verbale formale",
            icon: "doc.text",
            instructions: """
            Redigi un verbale formale in terza persona con queste sezioni:
            1. Oggetto dell'incontro
            2. Presenti (solo se nominati nella trascrizione)
            3. Svolgimento: punti trattati in ordine cronologico, con chi ha detto cosa quando è chiaro
            4. Decisioni e conclusioni
            5. Azioni da fare
            Stile sobrio e impersonale, adatto a essere archiviato o inviato.
            """
        ),
        SummaryTemplate(
            id: "appunto",
            name: "Appunto vocale",
            icon: "note.text",
            instructions: """
            Trasforma un appunto vocale dettato in note ordinate:
            1. Titolo breve
            2. Punti chiave (elenco puntato)
            3. Idee o promemoria
            4. Azioni da fare
            """
        )
    ]

    static func byID(_ id: String) -> SummaryTemplate {
        all.first { $0.id == id } ?? all[0]
    }

    /// Testo pronto da incollare/inviare all'app Claude.
    func claudePrompt(title: String, transcript: String) -> String {
        """
        Ti incollo la trascrizione automatica di una registrazione intitolata "\(title)".

        \(instructions)

        \(SummaryTemplate.commonRules)

        TRASCRIZIONE:
        \(transcript)
        """
    }
}
