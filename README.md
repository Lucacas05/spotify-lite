# SpotifyLite

Cliente nativo de Spotify para macOS (SwiftUI). Esta beta técnica se ejecuta desde el clon: control remoto de un dispositivo Spotify Connect activo, sin binario notarizado.

El login es OAuth 2.0 Authorization Code + PKCE. La contraseña se escribe solo en la página de Spotify. No hay Client Secret: no lo copies, no lo pegues y no lo subas al repositorio.

## Requisitos

| Requisito | Versión / detalle |
|---|---|
| macOS para **ejecutar** la app | 14.0 Sonoma o posterior (`project.yml`) |
| Xcode para **compilar** | 16 o posterior |
| [XcodeGen](https://github.com/yonaskolb/XcodeGen) | 2.x (`brew install xcodegen`) |
| Cuenta Spotify | **Premium** (ver [Premium](#premium)) |
| App en el [Spotify Developer Dashboard](https://developer.spotify.com/dashboard) | Client ID propio; sin secretos en el repo |

Homebrew hace falta solo para instalar XcodeGen. No hace falta cuenta de Apple Developer Program para esta beta: basta el equipo personal de Xcode o un build local sin firma.

## Clonar y generar el proyecto

`project.yml` es la fuente de verdad. El `.xcodeproj` se regenera con XcodeGen (incluye el scheme compartido `SpotifyLite`, necesario para `xcodebuild`).

```bash
git clone https://github.com/Lucacas05/spotify-lite.git
cd spotify-lite
brew install xcodegen
xcodegen generate
```

## App en el Spotify Developer Dashboard

1. Entra en [developer.spotify.com/dashboard](https://developer.spotify.com/dashboard) y crea una app.
2. Nombre y descripción libres. Marca **Web API**. Acepta los Developer Terms.
3. En Redirect URIs registra **exactamente** (copiar y pegar):

   ```text
   http://127.0.0.1:8888/callback
   ```

   La coincidencia es literal: `http` (no `https`), `127.0.0.1` (**no** `localhost`), puerto `8888` y path `/callback` sin barra final. Desde 2025 Spotify solo documenta como seguras las URI `https://` y loopback; `localhost` no está permitido.
4. Copia el **Client ID**. El Client Secret que muestra el dashboard **no se usa** (flujo PKCE). No lo guardes en el repo.
5. En Development Mode, el dueño de la app queda autorizado. Si entra otra cuenta, añádela en *User Management* (máximo 5 usuarios por app).

La URI y los scopes están fijos en `SpotifyAuthConfig` (`SpotifyLite/Auth/AuthManager.swift`). No hace falta cambiar código.

## Cómo configurar el Client ID

La app **no** lleva un Client ID de fábrica. Cada clon usa el suyo:

1. Arranca SpotifyLite.
2. En la pantalla de login, pega el Client ID en el campo.
3. Pulsa **Iniciar sesión con Spotify**.

`AuthManager` recorta espacios, rechaza el login si el campo está vacío y guarda el valor en `UserDefaults` con la clave `clientID`. Sobrevive a reinicios. Los tokens van al Keychain (`com.lucas.spotifylite`), nunca al disco plano.

No hay plantilla de secretos ni variable de entorno: el Client ID no es un secreto de OAuth, pero versionarlo compartiría la cuota de tu app. `.gitignore` ignora `.env` y `Secrets.xcconfig` por si alguien los crea por error.

## Scopes

La app pide exactamente:

```text
user-read-playback-state
user-modify-playback-state
user-read-currently-playing
playlist-read-private
playlist-read-collaborative
user-library-read
user-read-private
streaming
```

`streaming` queda para el playback local experimental (aún no está en esta beta). El control remoto usa los scopes `user-*-playback-state` y `user-read-currently-playing`.

## Premium

Hace falta una cuenta **Premium** en dos sitios:

- **Dueño de la app** en Development Mode (cambio de Spotify de febrero de 2026): si el Premium del dueño caduca, la app deja de funcionar.
- **Control de reproducción**: los endpoints Player (`play`, `pause`, `next`, seek, volumen, dispositivo) solo operan con Premium. Sin un dispositivo Connect activo, la API responde 404.

Navegar playlists y buscar puede funcionar con una cuenta Free, pero esta beta asume Premium porque cada usuario crea su propia app.

## Compilar y ejecutar

### Desde Xcode

```bash
xcodegen generate
open SpotifyLite.xcodeproj
```

Scheme `SpotifyLite`, destino *My Mac*. En *Signing & Capabilities* elige tu Team (el Personal Team vale). ⌘R.

### Desde la terminal (sin firma)

```bash
xcodegen generate
xcodebuild -project SpotifyLite.xcodeproj -scheme SpotifyLite \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO build
open build/Build/Products/Debug/SpotifyLite.app
```

Al abrir, macOS puede pedir confirmar una app sin firmar: clic derecho → Abrir.

Para usar el reproductor, deja un cliente oficial de Spotify (u otro dispositivo Connect) en marcha.

## Tests

No necesitan Client ID ni red:

```bash
xcodegen generate
xcodebuild test -project SpotifyLite.xcodeproj -scheme SpotifyLite \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Cubren PKCE, tokens, scopes de OAuth y los payloads principales de la Web API.

## Troubleshooting

| Síntoma | Qué comprobar |
|---|---|
| `INVALID_CLIENT: Invalid client` | Client ID mal pegado. Cópialo de nuevo del dashboard. |
| `Invalid redirect URI` / `Insecure redirect URI` | La URI en el dashboard debe ser exactamente `http://127.0.0.1:8888/callback`. No uses `localhost` ni custom schemes. |
| HTTP 403 *User not registered* | Añade esa cuenta en *User Management* de tu app. |
| HTTP 403 al controlar el player | Cuenta Premium y un dispositivo Connect activo. |
| HTTP 404 al reproducir | Abre Spotify en el teléfono, el escritorio u otro dispositivo. |
| *Configura tu Client ID…* | El campo de login está vacío. |
| El navegador no vuelve a la app / puerto en uso | Nada más debe escuchar `127.0.0.1:8888`. |
| `xcodebuild: scheme SpotifyLite not found` | Ejecuta `xcodegen generate`. |
| Xcode pide un Team | *Signing & Capabilities* → tu Personal Team, o usa el build con `CODE_SIGNING_ALLOWED=NO`. |

El empaquetado notarizado (DMG, Developer ID) no forma parte de esta beta; ver `RELEASE.md`.
