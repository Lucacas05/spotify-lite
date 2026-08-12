# Plan: Spotify Player ligero para macOS (SwiftUI)

Un cliente de Spotify nativo para macOS, hecho con SwiftUI, que use pocos recursos (objetivo: < 50 MB de RAM, < 1% CPU en reposo) y con login vía OAuth oficial de Spotify — el usuario inicia sesión en la página de Spotify, nunca escribe su contraseña en la app.

## Requisitos previos

- macOS 14+ (Sonoma) como target. Xcode 16+.
- Cuenta de Spotify **Premium** (obligatoria para reproducir audio con librespot).
- App registrada en el [Spotify Developer Dashboard](https://developer.spotify.com/dashboard):
  - Redirect URI: `spotifylite://callback`
  - Anotar el `Client ID` (no se necesita client secret gracias a PKCE).
- Rust toolchain instalado (solo para compilar librespot en la Fase 3).

## Decisiones clave

| Decisión | Elección | Por qué |
|---|---|---|
| UI | SwiftUI puro | Nativo, ligero, sin Electron/Qt |
| Auth | OAuth 2.0 Authorization Code + PKCE con `ASWebAuthenticationSession` | Login en la página oficial de Spotify, seguro para apps de escritorio, sin client secret |
| Metadata / playlists / búsqueda | Spotify Web API con `URLSession` + `Codable` | Sin dependencias externas |
| Playback | librespot (binario embebido, proceso hijo) controlado vía Spotify Connect | Único camino viable: Spotify no ofrece SDK de playback para desktop |
| Tokens | Keychain | Nunca en UserDefaults ni en disco plano |
| Dependencias | Cero paquetes de terceros en Swift | Menos superficie, menos peso |

**Nota legal:** usar librespot va contra los términos de servicio de Spotify (como todos los clientes no oficiales: Psst, ncspot, etc.). En la práctica se tolera, pero existe riesgo teórico de baneo de cuenta. La app en modo "solo control remoto" (Fases 1–2) es 100% conforme a la API oficial.

## Arquitectura

```
┌─────────────────────────────────────────────┐
│                 SwiftUI Views                │
│  Sidebar · PlaylistView · SearchView ·       │
│  PlayerBar · NowPlaying                      │
└──────────────┬──────────────────────────────┘
               │ @Observable
┌──────────────┴──────────────────────────────┐
│                ViewModels / Store            │
└───────┬─────────────────┬───────────────────┘
        │                 │
┌───────┴───────┐ ┌───────┴───────────────────┐
│  AuthManager  │ │      SpotifyClient         │
│  (PKCE, Key-  │ │  (Web API: URLSession +    │
│   chain, re-  │ │   Codable, rate limiting)  │
│   fresh)      │ └───────┬───────────────────┘
└───────────────┘         │ player endpoints
                  ┌───────┴───────────────────┐
                  │     PlayerEngine           │
                  │  librespot como proceso    │
                  │  hijo (device "SpotifyLite")│
                  │  + MPNowPlayingInfoCenter  │
                  └───────────────────────────┘
```

Cómo suena la música: librespot corre como proceso hijo y se registra como dispositivo Spotify Connect llamado "SpotifyLite". La app lo selecciona como dispositivo activo vía Web API (`PUT /me/player`) y controla todo (play, pause, seek, cola) con los endpoints `player`. El audio sale por librespot directo a CoreAudio.

## Estructura del proyecto

```
SpotifyLite/
├── SpotifyLiteApp.swift          # @main, escena principal
├── Auth/
│   ├── AuthManager.swift         # flujo PKCE, ASWebAuthenticationSession
│   ├── PKCE.swift                # verifier/challenge (CryptoKit)
│   └── KeychainStore.swift       # guardar/leer/borrar tokens
├── API/
│   ├── SpotifyClient.swift       # capa HTTP: auth header, refresh, retry 429
│   ├── Endpoints.swift           # rutas tipadas de la Web API
│   └── Models/                   # Codable: Track, Album, Playlist, Device...
├── Player/
│   ├── LibrespotProcess.swift    # lanzar/supervisar el binario librespot
│   ├── PlayerEngine.swift        # estado de reproducción, polling/eventos
│   └── NowPlayingBridge.swift    # MPNowPlayingInfoCenter, media keys
├── Views/
│   ├── MainWindow.swift          # NavigationSplitView (sidebar + detalle)
│   ├── LoginView.swift
│   ├── SidebarView.swift         # Library, playlists
│   ├── PlaylistDetailView.swift
│   ├── SearchView.swift
│   └── PlayerBarView.swift       # barra inferior: track, controles, volumen
├── Resources/
│   └── librespot                 # binario compilado (universal arm64+x86_64)
└── plan.md                       # este archivo
```

## Fases

### Fase 0 — Setup del proyecto (½ día)

- [ ] Crear proyecto Xcode: app macOS, SwiftUI, bundle id `com.lucas.spotifylite`.
- [ ] Registrar URL scheme `spotifylite` en Info → URL Types.
- [ ] App Sandbox: habilitar `com.apple.security.network.client` (outgoing connections).
- [ ] Registrar la app en el Spotify Developer Dashboard y guardar el Client ID.

### Fase 1 — Login con OAuth de Spotify (1–2 días)

El corazón de lo que pediste: al pulsar "Iniciar sesión", se abre la página oficial de Spotify; el usuario se autentica ahí y Spotify redirige de vuelta a la app.

- [ ] `PKCE.swift`: generar `code_verifier` (64 chars aleatorios) y `code_challenge` (SHA256 + base64url) con CryptoKit.
- [ ] `AuthManager.login()`:
  - Construir URL de `https://accounts.spotify.com/authorize` con `client_id`, `response_type=code`, `redirect_uri=spotifylite://callback`, `code_challenge_method=S256`, `code_challenge` y `scope`.
  - Scopes: `user-read-playback-state user-modify-playback-state user-read-currently-playing playlist-read-private playlist-read-collaborative user-library-read streaming`.
  - Abrir con `ASWebAuthenticationSession(url:callbackURLScheme:"spotifylite")` → esto muestra la página oficial de login de Spotify (comparte cookies con Safari: si ya hay sesión, es un clic).
  - En el callback, extraer `code` de la URL.
- [ ] `AuthManager.exchangeCode()`: `POST https://accounts.spotify.com/api/token` con `grant_type=authorization_code`, `code`, `redirect_uri`, `client_id`, `code_verifier`. Respuesta: `access_token` (expira en 1 h) + `refresh_token`.
- [ ] `KeychainStore`: guardar ambos tokens en el Keychain.
- [ ] Refresh automático: interceptor en `SpotifyClient` que renueva el token cuando expira (o ante un 401) con `grant_type=refresh_token`, serializado con un actor para evitar refreshes concurrentes.
- [ ] `LoginView`: pantalla inicial con botón "Iniciar sesión con Spotify"; al completar, pasar a `MainWindow`.
- [ ] Logout: borrar Keychain y volver a `LoginView`.

**Criterio de salida:** abrir la app → login en la página de Spotify → la app muestra tu nombre de usuario (`GET /me`) y sobrevive reinicios sin pedir login de nuevo.

### Fase 2 — Biblioteca y búsqueda, modo control remoto (3–4 días)

Con solo la Web API la app ya es útil: navega tu música y controla la reproducción en cualquier dispositivo activo (el cliente oficial, un parlante). Todo esto es 100% API oficial.

- [ ] `SpotifyClient`: capa genérica `request<T: Codable>` con auth header, decodificación, manejo de 401 (refresh) y 429 (respetar `Retry-After`).
- [ ] Modelos `Codable` mínimos: `Track`, `Album`, `Artist`, `Playlist`, `PlaybackState`, `Device`.
- [ ] `SidebarView`: playlists del usuario (`GET /me/playlists`, paginado) + Liked Songs.
- [ ] `PlaylistDetailView`: tracks con `LazyVStack` (playlists de miles de canciones sin costo de memoria), carátulas con caché (`URLCache` configurado, ~50 MB en disco).
- [ ] `SearchView`: `GET /search` con debounce de 300 ms.
- [ ] `PlayerBarView`: track actual, play/pausa, siguiente/anterior, volumen, selector de dispositivo (`GET /me/player/devices`).
- [ ] Estado de reproducción: polling de `GET /me/player` cada 5 s cuando la ventana está activa (pausar el polling en background para no gastar CPU).

**Criterio de salida:** buscar una canción, sonarla en el dispositivo activo, controlar play/pausa/volumen desde la app.

### Fase 3 — Playback propio con librespot (3–5 días)

- [ ] Compilar librespot en release: binario universal (arm64 + x86_64), features mínimas (`--no-default-features --features "rodio-backend"`), strip. Debe quedar en ~10 MB.
- [ ] Embeberlo en `Resources/` y firmarlo junto con la app.
- [ ] `LibrespotProcess`: lanzar con `Process` al iniciar sesión:
  - `librespot --name "SpotifyLite" --backend rodio --cache <app support> --enable-oauth` (librespot soporta OAuth con scope `streaming`; evaluar reusar el token de la app o dejar que haga su propio flujo una sola vez).
  - Supervisión: reiniciar si el proceso muere, log a archivo en Application Support.
- [ ] Al arrancar, transferir la reproducción al dispositivo "SpotifyLite" (`PUT /me/player` con su device id).
- [ ] `NowPlayingBridge`: `MPNowPlayingInfoCenter` (título, artista, carátula, posición) + `MPRemoteCommandCenter` (media keys del teclado, AirPods).
- [ ] Latencia de estado: reducir dependencia del polling usando eventos de librespot (`--onevent` o su API de eventos) para reflejar cambios al instante.

**Criterio de salida:** la app reproduce audio por sí misma, responde a las media keys y aparece en el widget Now Playing de macOS.

### Fase 4 — Pulido y rendimiento (2–3 días)

- [ ] Cola de reproducción y "reproducir siguiente".
- [ ] Vista de álbum y de artista.
- [ ] Atajos de teclado (espacio = play/pausa, ⌘F = buscar, ⌘1/2 = navegación).
- [ ] Ícono en menu bar opcional (track actual + controles) con `MenuBarExtra`.
- [ ] Perfilar con Instruments: objetivo < 50 MB RAM con librespot incluido, 0% CPU en reposo (sin timers activos en background).
- [ ] Modo claro/oscuro, estados vacíos, manejo de errores visibles (sin conexión, token revocado, sin Premium).
- [ ] Empaquetado: firma, notarización, DMG.

## Riesgos y mitigaciones

| Riesgo | Impacto | Mitigación |
|---|---|---|
| librespot deja de funcionar por cambios de Spotify | Sin audio propio | El modo control remoto (Fase 2) sigue funcionando; librespot tiene comunidad activa que lo repara rápido |
| Baneo de cuenta por ToS | Pérdida de cuenta | Riesgo teórico y históricamente no ejercido contra usuarios; documentarlo en el README; ofrecer modo solo-control |
| Rate limits de la Web API | UI lenta | Caché agresivo de metadata, polling solo con ventana activa, respetar `Retry-After` |
| Sin cuenta Premium | Playback no funciona | Detectar `product != "premium"` en `GET /me` y limitar la app a modo control remoto con aviso claro |
| Cuota de la Web API en modo development | Solo 25 usuarios autorizados | Suficiente para uso personal; pedir quota extension solo si se distribuye |

## Estimación total

~2 a 3 semanas a tiempo parcial para llegar al final de la Fase 3 (app usable con audio propio). La Fase 2 sola ya da una app útil en la primera semana.

## Referencias

- [Authorization Code Flow with PKCE — Spotify](https://developer.spotify.com/documentation/web-api/tutorials/code-pkce-flow)
- [Spotify Web API Reference](https://developer.spotify.com/documentation/web-api)
- [librespot](https://github.com/librespot-org/librespot)
- [Psst](https://github.com/jpochyla/psst) — referencia de cliente ligero (Rust)
- [ASWebAuthenticationSession — Apple](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession)
