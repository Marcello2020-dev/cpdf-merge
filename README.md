# vision-ocr-pdf-toolkit

macOS-App zum Bearbeiten von PDFs mit Apple-Bordmitteln (`PDFKit`, `Vision`, `CoreGraphics`) ohne externe CLI-Tools.

## Funktionen

- `Merge`:
  - Mehrere PDFs zusammenführen (Drag & Drop Reihenfolge)
  - Bestehende Quell-Bookmarks optional unverändert übernehmen
  - Neue Merge-Bookmarks pro Quelle setzen
- `OCR`:
  - OCR mit Apple Vision
  - Unsichtbarer, durchsuchbarer Textlayer in die PDF schreiben
  - Vorschau vor dem Speichern, danach In-Place speichern (atomar)
- `Seiten`:
  - Seitenvorschau als Grid
  - Seiten per Drag & Drop oder Buttons verschieben
  - Seiten drehen, löschen, extrahieren, splitten, einfügen
  - Änderungen erst bei `Speichern` auf Originaldatei übernehmen (über Temp-Arbeitskopie + atomarer Replace)

## Technik

- SwiftUI Desktop App (macOS)
- Kernframeworks:
  - `PDFKit` für PDF-Struktur/Rendering/Outline
  - `Vision` für OCR
  - `CoreImage` / `Accelerate` für Bildvorverarbeitung im OCR-Pfad

## Build & Run

1. Projekt in Xcode öffnen:
   - `vision-ocr-pdf-toolkit.xcodeproj`
2. Scheme wählen:
   - `vision-ocr-pdf-toolkit`
3. `Run` ausführen.

Alternativ per CLI:

```bash
xcodebuild -project vision-ocr-pdf-toolkit.xcodeproj -scheme vision-ocr-pdf-toolkit -configuration Debug build
```

## Lizenz

MIT, siehe `LICENSE`.
