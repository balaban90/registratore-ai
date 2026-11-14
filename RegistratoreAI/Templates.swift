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

    static let icons = ["star", "bolt", "person.3", "person.2", "graduationcap", "mic", "phone", "lightbulb",
                        "doc.text", "note.text", "briefcase", "cross.case", "house", "cart", "book",
                        "calendar", "envelope", "list.bullet.clipboard", "heart", "airplane", "hammer", "music.note"]

    static let commonRules = """
    Scrivi sempre in italiano, in modo chiaro e sintetico.
    Usa solo informazioni presenti nella trascrizione: non inventare nomi, numeri, date o impegni.
    Se un'informazione manca o non è chiara, scrivi "non specificato".
    La trascrizione è automatica e può contenere errori di riconoscimento: correggi solo quelli evidenti.
    Ometti le sezioni per cui la registrazione non contiene nulla.
    """

    static let all: [SummaryTemplate] = [
        SummaryTemplate(
            id: "sintesi",
            name: "Sintesi veloce",
            icon: "bolt",
            instructions: """
            Fai una sintesi veloce:
            1. In una frase: di cosa si parla
            2. I 5 punti più importanti (elenco puntato)
            3. Cose da fare o da ricordare, se ce ne sono
            """
        ),
        SummaryTemplate(
            id: "riunione",
            name: "Riunione",
            icon: "person.3",
            instructions: """
            Riassumi una riunione con queste sezioni:
            1. In sintesi (3-5 righe)
            2. Argomenti discussi (un punto per tema)
            3. Decisioni prese
            4. Questioni aperte
            5. Azioni da fare: cosa, chi, entro quando (se detti)
            """
        ),
        SummaryTemplate(
            id: "lezione",
            name: "Lezione o corso",
            icon: "graduationcap",
            instructions: """
            Trasforma una lezione o un corso in appunti di studio:
            1. Argomento e obiettivi
            2. Concetti chiave, ciascuno spiegato in 2-3 righe
            3. Definizioni, formule, date o dati importanti
            4. Esempi citati
            5. Possibili domande d'esame o di verifica
            6. Punti da approfondire
            """
        ),
        SummaryTemplate(
            id: "intervista",
            name: "Intervista",
            icon: "mic",
            instructions: """
            Riassumi un'intervista:
            1. Chi viene intervistato e su che tema (se detto)
            2. Domande principali con la sintesi delle risposte
            3. Frasi significative riportate testualmente tra virgolette
            4. Temi e conclusioni emersi
            """
        ),
        SummaryTemplate(
            id: "colloquio",
            name: "Colloquio o consulenza",
            icon: "person.2",
            instructions: """
            Riassumi un colloquio, un appuntamento o una consulenza (es. medico, avvocato, banca, scuola, lavoro):
            1. Motivo dell'incontro
            2. Situazione descritta (fatti, date, persone)
            3. Informazioni, indicazioni o consigli ricevuti
            4. Decisioni prese
            5. Documenti, scadenze e prossimi passi
            """
        ),
        SummaryTemplate(
            id: "telefonata",
            name: "Telefonata",
            icon: "phone",
            instructions: """
            Riassumi una telefonata:
            1. Con chi e per cosa
            2. Cosa ci si è detti (punti principali)
            3. Cosa è stato concordato
            4. Prossimi passi, numeri, date e riferimenti da annotare
            """
        ),
        SummaryTemplate(
            id: "brainstorming",
            name: "Idee e brainstorming",
            icon: "lightbulb",
            instructions: """
            Organizza un brainstorming o una sessione di idee:
            1. Obiettivo o problema di partenza
            2. Idee emerse, raggruppate per tema
            3. Pro e contro emersi per le idee principali
            4. Idee più promettenti da sviluppare
            5. Prossimi passi
            """
        ),
        SummaryTemplate(
            id: "verbale",
            name: "Verbale formale",
            icon: "doc.text",
            instructions: """
            Redigi un verbale formale in terza persona:
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
            4. Cose da fare
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
