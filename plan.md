# Plan: Spotify Player ligero para macOS (SwiftUI)

Un cliente de Spotify nativo para macOS, hecho con SwiftUI, que use pocos recursos (objetivo: < 50 MB de RAM, < 1% CPU en reposo) y con login vía OAuth oficial de Spotify — el usuario inicia sesión en la página de Spotify, nunca escribe su contraseña en la app.

## Requisitos previos

- macOS 14+ (Sonoma) como target. Xcode 16+.
- Cuenta de Spotify **Premium** solo si se usa el playback local opcional (librespot); el modo control remoto funciona con los endpoints oficiales.
- App registrada en el [Spotify Developer Dashboard](https://developer.spotify.com/dashboard):
  - Redirect URI: `http://127.0.0.1:8888/callback` (loopback; desde 2025 Spotify solo documenta como seguros `https://` y loopback — los custom schemes dan `INVALID_CLIENT: Insecure redirect URI` en apps nuevas)
  - Anotar el `Client ID` (no se necesita client secret gracias a PKCE).

## Decisiones clave

| Decisión | Elección | Por qué |
|---|---|---|
| UI | SwiftUI puro | Nativo, ligero, sin Electron/Qt |
| Auth | OAuth 2.0 Authorization Code + PKCE con navegador + servidor loopback local | Login en la página oficial de Spotify; loopback (`http://127.0.0.1`) es la única forma documentada como segura para desktop desde 2025, sin client secret |
| Metadata / playlists / búsqueda | Spotify Web API con `URLSession` + `Codable` | Sin dependencias externas |
| Playback | Control remoto vía Web API por defecto; librespot **externo** (instalado por el usuario con brew), opt-in y experimental | Spotify no ofrece SDK de playback para desktop; no embeber librespot mantiene lo publicado 100% API oficial |
| Tokens | Keychain | Nunca en UserDefaults ni en disco plano |
| Dependencias | Cero paquetes de terceros en Swift | Menos superficie, menos peso |

**Nota legal:** la app publicada usa solo la API oficial (control remoto). Usar librespot va contra los términos de servicio de Spotify (como todos los clientes no oficiales: Psst, ncspot, etc.); en la práctica se tolera, pero existe riesgo teórico de baneo de cuenta. Por eso el playback local es opt-in, requiere que el usuario instale librespot por su cuenta y se marca como experimental/no oficial.

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
                  │  librespot externo (brew)  │
                  │  opcional, proceso hijo    │
                  │  + MPNowPlayingInfoCenter  │
                  └───────────────────────────┘
```

Cómo suena la música: por defecto, la app controla la reproducción en cualquier dispositivo Spotify Connect activo vía Web API. Si el usuario activa el modo experimental y tiene librespot instalado (brew), la app lo lanza como proceso hijo registrado como dispositivo Connect "SpotifyLite", lo selecciona vía `PUT /me/player` y controla todo (play, pause, seek, cola) con los endpoints `player`. El audio sale por librespot directo a CoreAudio.

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
│   ├── LibrespotLocator.swift    # detectar instalación vía brew, validar versión
│   ├── LibrespotProcess.swift    # lanzar/supervisar el binario externo
│   ├── PlayerEngine.swift        # estado de reproducción (polling Web API)
│   └── NowPlayingBridge.swift    # MPNowPlayingInfoCenter, media keys
├── Views/
│   ├── MainWindow.swift          # NavigationSplitView (sidebar + detalle)
│   ├── LoginView.swift
│   ├── SidebarView.swift         # Library, playlists
│   ├── PlaylistDetailView.swift
│   ├── SearchView.swift
│   └── PlayerBarView.swift       # barra inferior: track, controles, volumen
└── plan.md                       # este archivo
```

## Fases

### Fase 0 — Setup del proyecto (½ día)

- [x] Crear proyecto Xcode: app macOS, SwiftUI, bundle id `com.lucas.spotifylite`.
- [x] Sin App Sandbox (necesario para lanzar el librespot externo del usuario); Hardened Runtime activado. Distribución: Developer ID + notarización, fuera del App Store.
- [x] Registrar la app en el Spotify Developer Dashboard y guardar el Client ID.

### Fase 1 — Login con OAuth de Spotify (1–2 días)

El corazón de lo que pediste: al pulsar "Iniciar sesión", se abre la página oficial de Spotify; el usuario se autentica ahí y Spotify redirige de vuelta a la app.

- [x] `PKCE.swift`: generar `code_verifier` (64 chars aleatorios) y `code_challenge` (SHA256 + base64url) con CryptoKit.
- [x] `AuthManager.login()`:
  - Construir URL de `https://accounts.spotify.com/authorize` con `client_id`, `response_type=code`, `redirect_uri=http://127.0.0.1:<puerto>/callback`, `code_challenge_method=S256`, `code_challenge` y `scope`.
  - Scopes: `user-read-playback-state user-modify-playback-state user-read-currently-playing playlist-read-private playlist-read-collaborative user-library-read user-read-private streaming`.
  - Levantar un mini servidor HTTP local efímero en `127.0.0.1` (Network.framework) y abrir la URL en el navegador por defecto con `NSWorkspace.open` (si ya hay sesión de Spotify en el navegador, es un clic).
  - En el callback HTTP, extraer `code`, responder una página de "vuelve a la app" y apagar el servidor.
- [x] `AuthManager.exchangeCode()`: `POST https://accounts.spotify.com/api/token` con `grant_type=authorization_code`, `code`, `redirect_uri`, `client_id`, `code_verifier`. Respuesta: `access_token` (expira en 1 h) + `refresh_token`.
- [x] `KeychainStore`: guardar ambos tokens en el Keychain.
- [x] Refresh automático: interceptor en `SpotifyClient` que renueva el token cuando expira (o ante un 401) con `grant_type=refresh_token`, serializado con un actor para evitar refreshes concurrentes.
- [x] `LoginView`: pantalla inicial con botón "Iniciar sesión con Spotify"; al completar, pasar a `MainWindow`.
- [x] Logout: borrar Keychain y volver a `LoginView`.

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

### Fase 3 — Pulido, rendimiento y primer release (2–3 días)

El primer release es solo-control-remoto: 100% API oficial, sin librespot.

- [ ] Cola de reproducción y "reproducir siguiente".
- [ ] Vista de álbum y de artista.
- [ ] Atajos de teclado (espacio = play/pausa, ⌘F = buscar, ⌘1/2 = navegación).
- [ ] Ícono en menu bar opcional (track actual + controles) con `MenuBarExtra`.
- [ ] Perfilar con Instruments: objetivo < 50 MB RAM, 0% CPU en reposo (sin timers activos en background).
- [ ] Modo claro/oscuro, estados vacíos, manejo de errores visibles (sin conexión, token revocado, sin Premium).
- [ ] Empaquetado: firma Developer ID, hardened runtime, notarización, DMG. El brew cask viene después, apuntando al mismo artefacto notarizado.

**Criterio de salida:** DMG notarizado, descargable e instalable, con la app completa en modo control remoto.

### Fase 4 — Playback local con librespot externo (2–3 días, post-release)

Opt-in y experimental: el usuario instala librespot por su cuenta (brew); la app nunca lo embebe.

- [ ] `LibrespotLocator`: detectar la instalación sin depender del PATH de shell — buscar `brew` (fallback `/opt/homebrew/bin/brew`, `/usr/local/bin/brew`), resolver `brew --prefix librespot`, verificar que `<prefix>/bin/librespot` existe y es ejecutable.
- [ ] Validar versión con `librespot --version`: bloquear si < 0.8.0 (mensaje "actualiza con `brew upgrade librespot`"); solo advertir si es mayor o no parseable.
- [ ] Opt-in en Ajustes: toggle "Playback local (experimental)" con advertencia clara (cliente no oficial, riesgo teórico de baneo, requiere Premium).
- [ ] Descubrimiento: el selector de dispositivos muestra "Esta Mac (configurar…)" cuando el modo no está activo; abre una hoja con instrucciones (`brew install librespot` copiable + botón "Volver a comprobar"). La app no ejecuta brew.
- [ ] `LibrespotProcess`: lanzar con `Process` el binario externo:
  - `librespot --name "SpotifyLite" --backend rodio --zeroconf-backend dns-sd --system-cache <Application Support>/SpotifyLite/librespot`.
  - Auth: reusar el token PKCE de la app (scope `streaming`) vía `LIBRESPOT_ACCESS_TOKEN` en el entorno del proceso; `--enable-oauth` solo como fallback diagnóstico.
  - Supervisión: si el proceso muere, reiniciar con backoff (3 intentos: 1 s/2 s/4 s); si sigue fallando, degradar a modo control remoto con banner y botón "Reintentar". Log a archivo en Application Support (sin tokens).
- [ ] Al activarse, transferir la reproducción al dispositivo "SpotifyLite" (`PUT /me/player` con su device id).
- [ ] Estado de reproducción: reutilizar el polling de la Fase 2 (el bridge de eventos `--onevent` queda como mejora futura).
- [ ] `NowPlayingBridge`: `MPNowPlayingInfoCenter` (título, artista, carátula, posición) + `MPRemoteCommandCenter` (media keys del teclado, AirPods).

**Criterio de salida:** con librespot instalado y el modo activado, la app reproduce audio por sí misma, responde a las media keys y aparece en el widget Now Playing de macOS; sin librespot, la app sigue completa en modo control remoto.

## Mejoras futuras (sin estimación)

- Bridge de eventos de librespot (`--onevent` + helper embebido que reenvía a la app por socket Unix): reemplaza el polling por eventos instantáneos e interpolación local de posición.
- Brew cask (tras el primer DMG) y, si hace falta, Sparkle para updates automáticos fuera de brew.

## Riesgos y mitigaciones

| Riesgo | Impacto | Mitigación |
|---|---|---|
| librespot deja de funcionar por cambios de Spotify | Sin audio propio | El modo control remoto (Fase 2) sigue funcionando; librespot tiene comunidad activa que lo repara rápido |
| Baneo de cuenta por ToS | Pérdida de cuenta | Riesgo teórico y históricamente no ejercido contra usuarios; documentarlo en el README; ofrecer modo solo-control |
| Rate limits de la Web API | UI lenta | Caché agresivo de metadata, polling solo con ventana activa, respetar `Retry-After` |
| Sin cuenta Premium | Playback no funciona | Detectar `product != "premium"` en `GET /me` y limitar la app a modo control remoto con aviso claro |
| Cuota de la Web API en modo development | Solo 25 usuarios autorizados | Suficiente para uso personal; pedir quota extension solo si se distribuye |

## Estimación total

~1.5 a 2 semanas a tiempo parcial hasta el primer release (fin de Fase 3, solo control remoto). La Fase 2 sola ya da una app útil en la primera semana. El playback local con librespot (Fase 4) suma 2–3 días en una versión posterior.

## Referencias

- [Authorization Code Flow with PKCE — Spotify](https://developer.spotify.com/documentation/web-api/tutorials/code-pkce-flow)
- [Spotify Web API Reference](https://developer.spotify.com/documentation/web-api)
- [librespot](https://github.com/librespot-org/librespot)
- [Psst](https://github.com/jpochyla/psst) — referencia de cliente ligero (Rust)
- [ASWebAuthenticationSession — Apple](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession)
