# Registratore AI — istruzioni per Claude

App iPhone (SwiftUI, iOS 26) che replica Plaud Note con il microfono del telefono.
L'utente (Pasquale) non programma: parla in italiano semplice, niente gergo tecnico nelle risposte.

## Come si compila e si pubblica
- Nessun Mac di sviluppo: il progetto si genera con XcodeGen (`project.yml`) e si compila su GitHub Actions
  (`.github/workflows/build.yml`) a ogni push su `main`. Qui non c'è il compilatore Swift: controlla sempre
  l'esito con `gh run list` / `gh run watch` e, se fallisce, leggi gli errori con `gh run view --log-failed`.
- Una nuova versione viene **pubblicata come Release** (ed è proposta nell'app con "Aggiorna", via SideStore)
  solo se aumenti `CURRENT_PROJECT_VERSION` in `project.yml`. Aumenta anche `MARKETING_VERSION`
  (0.15.0 → 0.15.1 per correzioni, 0.16.0 per novità) e aggiorna il numero nel README.
- `NOTE-VERSIONE.md` diventa il testo della Release mostrato nell'app: 1–2 frasi in italiano semplice,
  rivolte all'utente, su cosa cambia. Riscrivilo a ogni versione.
- Tieni `COPIA-workflow-build.yml` identico a `.github/workflows/build.yml`.

## Diagnostica
- L'app scrive un registro (`DiagnosticLog.swift`) e, a ogni errore o crash, invia un rapporto al repository
  privato `balaban90/registratore-ai-diagnostica` nella cartella `diagnostica/` (`DiagnosticUploader.swift`).
- Dopo aver analizzato un rapporto, spostalo in `elaborati/` (nello stesso repository) così non viene
  rianalizzato.
- I rapporti non contengono audio, testi delle trascrizioni o chiavi: non aggiungere mai al registro
  contenuti delle registrazioni o segreti.
- Distingui i bug dell'app dai problemi esterni (credito API esaurito, niente rete, permesso microfono negato,
  spazio pieno): per questi ultimi non si cambia il codice, si avvisa l'utente.

## Regole dell'interfaccia
- Nell'interfaccia mai "Claude": solo "AI" / "AI avanzata". "Elaborazioni", non "Riassunti".
- Testi brevi e professionali, stile Apple. L'app decide da sola; le scelte manuali stanno in Impostazioni.
