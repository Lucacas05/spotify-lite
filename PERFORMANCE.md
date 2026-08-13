# Perfil de rendimiento — Fase 3

Medición local del build `Release` en macOS, con la ventana oculta para activar `scenePhase != .active` y detener el polling:

```bash
xcodebuild -project SpotifyLite.xcodeproj -scheme SpotifyLite \
  -configuration Release -sdk macosx CODE_SIGNING_ALLOWED=NO build
open <DerivedData>/Build/Products/Release/SpotifyLite.app
osascript -e 'tell application "System Events" to set visible of process "SpotifyLite" to false'
top -l 2 -s 3 -pid "$(pgrep -x SpotifyLite)" -stats pid,cpu,mem,state
```

Resultado observado el 13 de agosto de 2026, después de 12 segundos en background:

```text
PID    %CPU MEM  STATE
12338  0.0  45M  sleeping
```

Decisiones aplicadas para cumplir el objetivo:

- El polling de playback se cancela cuando la escena deja de estar activa.
- El icono de menu bar es opt-in y está desactivado por defecto.
- La caché de carátulas reserva solo 2 MB de RAM y conserva 50 MB en disco.
- Las listas usan `LazyVStack`.

La medición debe repetirse con Instruments (Allocations + Time Profiler) en la máquina usada para preparar cada release; el consumo varía por versión de macOS y contenido cargado.
