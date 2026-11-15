# Registratore AI

App per iPhone che fa quello che fa Plaud Note usando il microfono del telefono, o un microfono USB-C.
Tutto avviene sul telefono e non costa nulla: la trascrizione con SpeechAnalyzer di Apple, i elaborazioni con il modello Apple sul dispositivo.
Per i elaborazioni più accurati puoi inviare il testo all'app Claude.

**Requisiti:** iPhone con iOS 26 e Apple Intelligence (iPhone 15 Pro o successivi).

## Cosa fa (versione 0.9)

- Registra in background, anche a schermo bloccato.
- Va in pausa durante una chiamata e riprende da sola quando finisce.
- Sceglie il microfono, mostra il livello del segnale e passa da solo a quello USB-C appena lo colleghi.
- Segna i momenti importanti con la bandierina.
- Importa file audio da File o da altre app.
- Trascrive sul telefono, con gli orari: tocchi una frase e l'audio parte da lì.
- Crea elaborazioni con 9 modelli pronti: Sintesi veloce, Riunione, Lezione o corso, Intervista, Colloquio o consulenza, Telefonata, Idee e brainstorming, Verbale formale, Appunto vocale. Puoi aggiungere i tuoi.
- Trascrive in italiano, inglese, francese, tedesco, spagnolo e portoghese (lingua da scegliere in Impostazioni).
- Separa i parlanti sul telefono (Persona 1, Persona 2…), con nomi modificabili e profili vocali per riconoscere le persone nelle registrazioni successive.
- Glossario con correzioni automatiche e revisione della trascrizione con Claude.
- **Parlanti più precisi:** le voci vengono assegnate parola per parola, quindi una frase in cui parlano due persone viene divisa.
- **Parole incerte evidenziate:** le parole su cui il riconoscimento era poco sicuro sono colorate, così le controlli subito.
- **"Migliora con l'AI" in un solo passaggio economico:** corregge le parole sbagliate (soprattutto quelle incerte), rimette punteggiatura ed elenchi, sistema chi parla in base al contenuto e propone i nomi o i ruoli dei parlanti (li confermi tu con "Applica").
- **Claude dentro l'app** (con chiave API, in Impostazioni ⚙︎): elaborazione con Claude e "Chiedi a Claude" sulla registrazione (domande, mail, comunicati). A Claude va solo il testo.
- **Modelli personalizzati**: crea, modifica o duplica i modelli di elaborazione (Impostazioni > Modelli di elaborazione).
- **Invia all'app Claude:** prepara il testo con il modello scelto e lo condivide con l'app Claude (lo copia anche negli appunti).
- Esporta in PDF, RTF (si apre con Word e Pages), testo o audio.

## Prima installazione (una volta sola)

### 1. Caricare il codice su GitHub
1. Su github.com crea un nuovo repository **privato** chiamato `registratore-ai`.
2. Premi **Add file > Upload files** e trascina dentro il contenuto della cartella `registratore-ai`: la cartella `RegistratoreAI`, `project.yml` e `README.md`. Poi premi **Commit changes**.
3. Il Mac nasconde la cartella `.github`, quindi il file che avvia la compilazione va creato a mano:
   **Add file > Create new file**. Come nome scrivi esattamente `.github/workflows/build.yml` e incolla il contenuto di `COPIA-workflow-build.yml`. Poi premi **Commit changes**.
   (Se colleghi GitHub a Claude nelle impostazioni di claude.ai, carica tutto lui.)

### 2. Far compilare l'app a GitHub
1. Nel repository apri la scheda **Actions**.
2. La compilazione **Compila app iPhone** parte da sola a ogni modifica. Puoi anche avviarla a mano con **Run workflow**.
3. Dopo circa 5–10 minuti, quando compare la spunta verde, apri la compilazione e scarica **RegistratoreAI-ipa** in fondo alla pagina.
   È uno .zip: aprilo e dentro trovi `RegistratoreAI.ipa`.
4. Se compare una X rossa, scarica **log-compilazione** e mandalo a Claude.

### 3. Installare l'app sull'iPhone con Sideloadly (dal Mac mini)
1. Scarica Sideloadly da sideloadly.io e installalo sul Mac.
2. Collega l'iPhone al Mac con il cavo. Sull'iPhone tocca **Autorizza** e inserisci il codice.
3. Trascina `RegistratoreAI.ipa` in Sideloadly, inserisci il tuo Apple ID e premi **Start**.
   Conviene un Apple ID secondario, creato apposta.
4. Sull'iPhone:
   - Vai in **Impostazioni > Privacy e sicurezza > Modalità sviluppatore**, attivala e riavvia.
   - Vai in **Impostazioni > Generali > VPN e gestione dispositivi** e tocca **Autorizza** sul tuo Apple ID.
5. La prima volta che registri, consenti l'accesso al microfono.
6. Controlla che **Apple Intelligence** sia attiva (Impostazioni > Apple Intelligence e Siri), altrimenti i elaborazioni sul telefono non funzionano.

### Ogni 7 giorni
Con l'Apple ID gratuito l'app scade dopo 7 giorni. Le registrazioni restano, ma l'app non si apre finché non la reinstalli.
Per reinstallarla collega l'iPhone al Mac e ripeti il punto 3.3 con lo stesso file.

## Aggiornamenti
Quando Claude modifica il codice, GitHub ricompila da solo. Scarichi il nuovo .ipa e lo reinstalli con Sideloadly: le registrazioni restano.

## Dove sono i file
Gli audio sono in **File > Sul mio iPhone > Registratore AI > Registrazioni**.

## Prossime versioni
- **v2:** widget e Live Activity, note e foto durante la registrazione, note e foto.
- **v3:** ricerca in tutto l'archivio, mappa mentale, copia su iCloud Drive.
