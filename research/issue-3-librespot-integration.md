# Integración de librespot con una app macOS

Hallazgos revisados el 12 de agosto de 2026, a partir del código de `librespot` v0.8.0, su wiki, Homebrew, Apple y la documentación OAuth de Spotify.

## Resumen

- Para Homebrew, la app debe encontrar `brew` sin asumir el `PATH` de una app GUI, comprobar que la fórmula está instalada y resolver `brew --prefix librespot`. Luego conviene ejecutar directamente `<opt-prefix>/bin/librespot` con `Process`.
- Si la app ya hace OAuth PKCE, conviene reutilizar su access token. Librespot acepta `--access-token` y, en v0.8.0, también `LIBRESPOT_ACCESS_TOKEN`. El token debe tener el scope `streaming`.
- `--enable-oauth` funciona, pero abre un segundo flujo OAuth propio de librespot y guarda sus credenciales en su caché. Lo dejaría como alternativa de fallback, no como flujo principal de SpotifyLite.
- `--onevent` es el mecanismo correcto para recibir cambios sin consultar la Web API. Lanza un programa auxiliar y le pasa variables de entorno. No entrega un stream JSON directo por stdout.
- La versión estable actual de la fórmula Homebrew y del release upstream es `0.8.0`. Hay que verificar la versión real con `librespot --version`, no solo con el nombre de la fórmula.

## 1. Detectar y lanzar el binario desde Swift

### Detección

Una app lanzada desde Finder/Xcode no necesariamente hereda el `PATH` del shell del usuario. No conviene depender solo de `which librespot`.

El flujo recomendado es:

1. Buscar `brew` en el `PATH` disponible y, como fallback, en `/opt/homebrew/bin/brew` (Apple Silicon) y `/usr/local/bin/brew` (Intel).
2. Ejecutar `brew list --formula --versions librespot`. Si sale vacío o termina con error, la fórmula no está disponible para la app.
3. Ejecutar `brew --prefix librespot` y derivar `prefix/bin/librespot`.
4. Comprobar que el archivo existe y es ejecutable.
5. Ejecutar ese binario con `--version` y validar la versión antes de iniciar playback.

Homebrew documenta `brew list --versions` para consultar versiones instaladas y recomienda `brew --prefix <formula>` para obtener el `opt` prefix estable, en vez de hardcodear una ruta dentro de `Cellar`. La fórmula `librespot` no es keg-only, así que normalmente también existe el enlace `<brew-prefix>/bin/librespot`, pero el `opt` prefix es una resolución más estable.

En Swift, el patrón mínimo es este (sin shell):

~~~
let process = Process()
process.executableURL = librespotURL
process.arguments = [
    "--name", "SpotifyLite",
    "--backend", "rodio",
    "--zeroconf-backend", "dns-sd",
    "--system-cache", cacheURL.path,
    "--onevent", eventHelperURL.path,
]

var environment = ProcessInfo.processInfo.environment
environment["LIBRESPOT_ACCESS_TOKEN"] = freshAccessToken
process.environment = environment

let stdout = Pipe()
let stderr = Pipe()
process.standardOutput = stdout
process.standardError = stderr
process.terminationHandler = { process in
    // registrar salida, código de terminación y decidir si se reinicia
}

try process.run()
~~~

`Process.arguments` ya pasa un arreglo `argv`; no necesita comillas de shell y tampoco expande `$HOME` o `~`. Para los logs, lee `standardError` de forma asíncrona para no llenar el pipe y bloquear al hijo. Los eventos de playback no llegan directamente por `standardOutput`; llegan al programa indicado por `--onevent`.

### Ojo con App Sandbox

El `plan.md` actual activa App Sandbox, pero una dependencia en `/opt/homebrew` o `/usr/local` entra en conflicto con ese diseño. Apple documenta que una app sandboxed puede ejecutar programas dentro de su app bundle, su sandbox container o un app group, y que el proceso hijo hereda el sandbox del padre. Las entitlements de archivos seleccionados no convierten una ruta Homebrew arbitraria en un ejecutable permitido.

Por eso hay dos alternativas reales:

- Distribución directa, fuera del Mac App Store: quitar App Sandbox, conservar Hardened Runtime, firmar/notarizar la app y tratar Homebrew como dependencia opcional. Es la opción compatible con “el usuario instala librespot con brew”.
- App Sandbox/Mac App Store: embebir una copia propia de librespot y del bridge de eventos dentro del bundle, firmarlos junto con la app y lanzarlos como helpers. Es más reproducible, pero la app debe hacerse cargo de actualizar esa copia.

No asumiría que una build sandboxed pueda lanzar libremente `/opt/homebrew/opt/librespot/bin/librespot`.

## 2. OAuth propio o token de la app

### `--enable-oauth`

El flujo integrado de librespot:

- abre el navegador para que el usuario autorice;
- usa un callback loopback `http://127.0.0.1:<puerto>/login` (por defecto, `5588`);
- solicita el conjunto de scopes que librespot tiene configurado, que incluye `streaming` y varios scopes de la app de Spotify;
- si se proporciona `--cache` o `--system-cache`, guarda credenciales reutilizables para no repetir el login.

Es cómodo para ejecutar librespot solo desde la terminal, pero en SpotifyLite duplica el login que ya hace la app y pone el almacenamiento de credenciales fuera del Keychain. Tampoco usa el callback personalizado de la app (`spotifylite://callback`); es un flujo separado de librespot.

### Reutilizar el token de la app

La wiki de librespot documenta explícitamente `--access-token` y dice que el token debe incluir el scope `streaming`. La fuente v0.8.0 crea `Credentials::with_access_token(...)` con ese valor. El binario también acepta opciones largas desde variables `LIBRESPOT_*`, así que se puede usar `LIBRESPOT_ACCESS_TOKEN` en el entorno del `Process` en vez de poner el token en `arguments`.

La recomendación para este proyecto es:

1. Mantener el OAuth PKCE de SpotifyLite y pedir `streaming` junto con los scopes de Web API que la app necesite.
2. Comprobar que el `scope` devuelto por Spotify contiene `streaming` antes de arrancar librespot.
3. Pasar el access token fresco mediante `LIBRESPOT_ACCESS_TOKEN`; si no se quiere usar el entorno, pasar `--access-token <token>`.
4. Usar `--system-cache <directorio>` para que librespot guarde su credencial reutilizable y el volumen. El directorio contiene material sensible: debe tener permisos restrictivos.
5. Renovar el token en la app. Spotify documenta que el access token dura una hora; librespot no recibe el refresh token por CLI. Si el proceso necesita autenticarse de nuevo, hay que lanzarlo con el token fresco o dejar que use la credencial reutilizable de su caché.

Si se pasan un token y `--enable-oauth` al mismo tiempo, en v0.8.0 el token gana: el código procesa primero `access-token` y solo entra al OAuth interactivo cuando no hay credenciales. No conviene mezclar ambos modos; elige uno.

El entorno evita que el secreto quede en la lista de argumentos y el código de librespot lo enmascara en sus logs, pero no es un almacén seguro por sí mismo. El token y `credentials.json` deben tratarse como secretos y nunca deben aparecer en logs de SpotifyLite.

### Comparación rápida

| Opción | Ventaja | Costo/riesgo |
| --- | --- | --- |
| OAuth de librespot | Menos código propio para el primer login; caché integrada | Segundo login, callback loopback propio, scopes más amplios y caché fuera del Keychain |
| Token OAuth de SpotifyLite | Un solo login, un solo refresh y una sola sesión de usuario | La app debe refrescar el token y pasárselo de forma segura |

Para SpotifyLite elegiría el segundo camino. Dejaría `--enable-oauth` solo como fallback diagnóstico o para una build de prueba.

Nota: librespot requiere una cuenta Spotify Premium y su propio README advierte que el uso de este cliente puede estar restringido por Spotify. Esto es aparte de que el flujo técnico funcione.

## 3. Eventos sin polling

### `--onevent`

La wiki de eventos describe `--onevent=/ruta/al/programa`. Cada vez que se genera un evento, librespot lanza ese programa y le pasa variables de entorno. Las más útiles para la UI son:

- `PLAYER_EVENT=track_changed`, con `TRACK_ID`, `URI`, `NAME`, `COVERS` y metadatos adicionales.
- `PLAYER_EVENT=playing` o `paused`, con `TRACK_ID` y `POSITION_MS`.
- `PLAYER_EVENT=seeked` o `position_correction`, con `TRACK_ID` y `POSITION_MS`.
- `PLAYER_EVENT=end_of_track`, `stopped`, `loading`, `preloading` y `unavailable`, normalmente con `TRACK_ID`.
- `PLAYER_EVENT=volume_changed`, con `VOLUME`.
- `session_connected` y `session_disconnected`, con `USER_NAME` y `CONNECTION_ID`.

El bridge puede ser un ejecutable pequeño dentro de la app que convierta esas variables a una línea JSON y la envíe a SpotifyLite mediante un Unix domain socket, pipe o el IPC que elijamos. El bridge debe terminar rápido después de entregar el evento.

Hay una sutileza importante: la documentación llama “non-blocking” a estos eventos porque no bloquean los hilos de playback, pero el código sí espera a que termine el programa auxiliar y serializa los eventos para mantener el orden. Un bridge lento puede retrasar los siguientes eventos. No uses aquí un proceso que se quede abierto esperando.

`--emit-sink-events` es opcional y agrega eventos bloqueantes del sink: `PLAYER_EVENT=sink` con `SINK_STATUS=running`, `temporarily_closed` o `closed`. No hace falta para reflejar track/play/pause y puede bloquear el hilo del reproductor; lo dejaría fuera del mínimo.

### Qué no cubre

El binario standalone ignora `PlayerEvent::PositionChanged`; la propia fuente lo comenta. Por eso `--onevent` no manda un tick continuo para cada cambio de milisegundo.

La UI puede funcionar sin polling así:

1. En `track_changed`, actualiza pista, duración y portada.
2. En `playing`, `paused`, `seeked` y `position_correction`, guarda `POSITION_MS` y un `ContinuousClock` local.
3. Mientras el estado sea `playing`, interpola la posición localmente con el tiempo transcurrido.
4. Congela la posición en `paused` y resetea en `stopped`/`end_of_track`.
5. Usa `position_correction` como resync. Un chequeo de recuperación ocasional puede ser útil si el bridge se cae, pero no hace falta consultar la Web API cada cinco segundos para el caso normal.

En otras palabras: sí se pueden reflejar cambios de reproducción sin polling; no existe un evento standalone que por sí solo entregue una posición continua.

### Detalle práctico de la ruta del bridge

La implementación v0.8.0 parte la cadena de `--onevent` por espacios antes de ejecutar el comando. Pasa una ruta absoluta sin espacios o usa un wrapper con una ruta segura; no confíes en comillas de shell dentro del valor de `--onevent`.

## 4. Versión y flags mínimos

La última release upstream consultada es [v0.8.0, publicada el 10 de noviembre de 2025](https://github.com/librespot-org/librespot/releases/tag/v0.8.0). La [fórmula Homebrew](https://formulae.brew.sh/formula/librespot) también marca `0.8.0` como estable. En Homebrew para macOS se compila con `rodio-backend`, `with-dns-sd` y raíces TLS del sistema; `rodio` usa CoreAudio en macOS.

Con el token de SpotifyLite, el mínimo razonable es:

~~~
librespot
  --name SpotifyLite
  --backend rodio
  --zeroconf-backend dns-sd
  --system-cache <Application Support>/SpotifyLite/librespot
  --onevent <ruta-absoluta-al-bridge-sin-espacios>
~~~

Y en `Process.environment`:

~~~
LIBRESPOT_ACCESS_TOKEN=<access token fresco con scope streaming>
~~~

No agregaría `--disable-discovery`, porque el objetivo es que el dispositivo aparezca en Spotify Connect. `--cache <ruta>` es opcional: además de credenciales guarda archivos de audio; para empezar basta `--system-cache`. `--bitrate 320`, `--device-type computer`, normalización y volumen inicial son decisiones de producto, no requisitos de lanzamiento.

Si se usa el OAuth propio, cambia la autenticación por `--enable-oauth` y conserva `--system-cache`; no pases `LIBRESPOT_ACCESS_TOKEN` a la vez. Solo usa `--oauth-port` si el puerto 5588 está ocupado o necesitas el modo headless.

Finalmente, ejecuta `librespot --version` desde la app y registra el resultado (sin tokens). Si el usuario tiene `--HEAD` o una versión distinta, muestra un diagnóstico claro: las opciones y el protocolo interno pueden cambiar.

## Fuentes primarias

- [Homebrew: fórmula librespot](https://formulae.brew.sh/formula/librespot)
- [Homebrew: brew(1), `list --versions`](https://docs.brew.sh/Manpage)
- [Homebrew: `brew --prefix <formula>`](https://docs.brew.sh/How-to-Build-Software-Outside-Homebrew-with-Homebrew-keg-only-Dependencies)
- [Apple: `Process.arguments`, `executableURL` y pipes](https://developer.apple.com/documentation/foundation/process/arguments)
- [Apple: App Sandbox](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox)
- [Apple: acceso a archivos desde App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)
- [librespot Wiki: Options](https://github.com/librespot-org/librespot/wiki/Options)
- [librespot Wiki: Authentication / OAuth](https://github.com/librespot-org/librespot/wiki/Options#oauth)
- [librespot Wiki: Access token](https://github.com/librespot-org/librespot/wiki/Options#access-token)
- [librespot Wiki: Events](https://github.com/librespot-org/librespot/wiki/Events)
- [librespot v0.8.0: `src/main.rs`](https://github.com/librespot-org/librespot/blob/v0.8.0/src/main.rs#L700-L737)
- [librespot v0.8.0: caché y precedencia de credenciales](https://github.com/librespot-org/librespot/blob/v0.8.0/src/main.rs#L1136-L1232)
- [librespot v0.8.0: guardado de credenciales reutilizables](https://github.com/librespot-org/librespot/blob/v0.8.0/core/src/session.rs#L206-L257)
- [librespot v0.8.0: OAuth interactivo](https://github.com/librespot-org/librespot/blob/v0.8.0/src/main.rs#L1945-L1969)
- [librespot v0.8.0: eventos del binario](https://github.com/librespot-org/librespot/blob/v0.8.0/src/player_event_handler.rs#L297-L361)
- [librespot README: caché y credenciales](https://github.com/librespot-org/librespot/blob/v0.8.0/README.md#usage)
- [Spotify: Authorization Code with PKCE](https://developer.spotify.com/documentation/web-api/tutorials/code-pkce-flow)
- [Spotify: Access token](https://developer.spotify.com/documentation/web-api/concepts/access-token)
- [Spotify: scopes](https://developer.spotify.com/documentation/web-api/concepts/scopes)
- [Issue upstream sobre `--onevent` y permisos del programa](https://github.com/librespot-org/librespot/issues/367)
