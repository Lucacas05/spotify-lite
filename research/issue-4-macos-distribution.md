## Hallazgos: App Sandbox, `Process`, notarización y Homebrew Cask

### Respuesta corta

**Sí, pero no por defecto.** Una app macOS con App Sandbox no puede ejecutar libremente `/opt/homebrew/bin/librespot` solo por usar `Process`. El proceso hijo hereda la sandbox del padre y Apple indica que solo se pueden ejecutar binarios dentro de la *sandbox estática*; no existe una extensión dinámica equivalente para ejecutar cualquier binario que el usuario seleccione.

Para una app distribuida fuera del Mac App Store, Apple sí permite usar una excepción temporal de ruta absoluta para ampliar la sandbox estática. Eso puede hacer funcionar una instalación conocida de Homebrew, pero es frágil: hay prefijos arm64/Intel, symlinks de `bin` hacia `Cellar`, versiones y dependencias de librerías. Además, `librespot` sigue heredando el sandbox y sus operaciones de caché, red y sockets deben estar permitidas.

Fuentes: [Apple: `Process`](https://developer.apple.com/documentation/foundation/process), [Apple DTS: ejecutables desde una app sandboxeada](https://developer.apple.com/forums/thread/746478), [Apple DTS: permisos de archivos](https://developer.apple.com/forums/thread/678819), [excepciones temporales de App Sandbox](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/AppSandboxTemporaryExceptionEntitlements.html).

### Entitlements

Para probar una ruta fija en una build sandboxeada, el conjunto mínimo sería conceptualmente:

```xml
<key>com.apple.security.app-sandbox</key>
<true/>
<key>com.apple.security.network.client</key>
<true/>
<key>com.apple.security.temporary-exception.files.absolute-path.read-only</key>
<array>
    <string>/opt/homebrew/opt/librespot/</string>
    <string>/usr/local/opt/librespot/</string>
</array>
```

La excepción debe cubrir la ruta canónica que se ejecuta y las rutas que necesita el proceso; no conviene abrir todo `/opt/homebrew/`. Usa `network.server` solo si `librespot` realmente escucha conexiones entrantes.

Puntos que suelen confundirse:

- `com.apple.security.files.user-selected.read-only/read-write` da acceso dinámico a archivos elegidos, pero no concede acceso ejecutable.
- `com.apple.security.files.user-selected.executable` permite crear archivos ejecutables no cuarentenados; no es el permiso para lanzar un binario externo.
- `com.apple.security.inherit` no va en la app principal. Apple lo documenta para el target de un helper **embebido**, junto con `com.apple.security.app-sandbox`; ese helper debe llevar exactamente esos dos entitlements. Un hijo externo también hereda la sandbox del padre, así que `inherit` no amplía los permisos de `librespot`. Fuentes: [helper tool de Apple](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app) y [herencia de App Sandbox](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html).
- `com.apple.security.cs.disable-library-validation` no hace falta para lanzar un proceso separado. Solo aplica cuando el proceso host carga frameworks o plugins de terceros dentro de sí mismo.

### Sandbox, Hardened Runtime y notarización

- **App Sandbox:** limita archivos, red, hardware y otros recursos. Es obligatorio para publicar en el Mac App Store.
- **Hardened Runtime:** protege la integridad del proceso y Apple lo exige para notarizar una app macOS.
- **Notarización:** revisión automatizada sobre software firmado con Developer ID y emisión de un ticket para Gatekeeper. No es App Review y no activa App Sandbox.

Fuentes: [Apple: App Sandbox](https://developer.apple.com/documentation/security/app-sandbox), [Apple: Hardened Runtime](https://developer.apple.com/documentation/security/hardened-runtime) y [Apple: notarización](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

Por eso, una app sin App Sandbox **sí puede** distribuirse por un DMG notarizado. Firma con `Developer ID Application`, activa Hardened Runtime, firma todos los ejecutables que sí distribuyes, usa `notarytool`, grapa con `stapler` y valida con `codesign`/`spctl`. Si `librespot` es externo y lo instala el usuario, la notarización de SpotifyLite no cubre ese binario: hay que validar su firma, cuarentena, arquitectura y dependencias por separado.

### Homebrew Cask

Homebrew Cask no exige App Sandbox. Un cask instala artefactos precompilados, normalmente desde `.dmg` o `.zip`, y puede mover el `.app` a `/Applications`. Sus reglas sí exigen que la descarga venga del desarrollador o de una fuente respaldada por él y que no obligue a desactivar SIP o Gatekeeper. El audit actual del tap oficial comprueba firma y notarización de artefactos macOS: [Cask Cookbook](https://docs.brew.sh/Cask-Cookbook), [Acceptable Casks](https://docs.brew.sh/Acceptable-Casks) y [audit de Homebrew](https://github.com/Homebrew/brew/blob/main/Library/Homebrew/cask/audit.rb).

Un cask propio podría ser:

```ruby
cask "spotify-lite" do
  version "0.1.0"
  sha256 "<sha256-del-dmg>"
  url "https://github.com/Lucacas05/spotify-lite/releases/download/v#{version}/SpotifyLite-#{version}.dmg"
  name "Spotify Lite"
  desc "Lightweight native Spotify player for macOS"
  homepage "https://github.com/Lucacas05/spotify-lite"

  app "SpotifyLite.app"
end
```

El cask instala la app; no debería asumir que puede instalar o ejecutar una fórmula arbitraria. Para `librespot`, documenta `brew install librespot` como dependencia opcional o embebe una copia propia. Homebrew clasifica normalmente el software exclusivamente de línea de comandos como fórmula, no como cask.

### Recomendación concreta para SpotifyLite

1. Publica una build universal arm64 + x86_64 en GitHub Releases.
2. Para la build distribuida por GitHub + DMG + brew, **desactiva App Sandbox**; mantén Hardened Runtime + Developer ID + notarización.
3. En `PlayerEngine`, busca explícitamente `/opt/homebrew/bin/librespot` y `/usr/local/bin/librespot`, valida que sea ejecutable y muestra un error claro si falta. No dependas del `PATH` de una app GUI.
4. Para una experiencia reproducible, mi preferencia es embebir un `librespot` universal firmado como parte de la app y dejar el Homebrew del usuario como opción avanzada. Si quieres una build sandboxeada o futura versión para el Mac App Store, no dependas del binario externo: usa el helper embebido o limita la app al control remoto.

Trade-off: sin App Sandbox no puedes enviar esa misma build al Mac App Store y aumentas la superficie de daño si la app tiene una vulnerabilidad; a cambio, la integración con Homebrew es mucho más simple y estable frente a las restricciones del sandbox. Esto es la parte de distribución macOS; el riesgo de ToS de Spotify asociado a `librespot` es un tema separado.
