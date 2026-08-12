
## Hallazgo principal

Al 12 de agosto de 2026, no encontré un SDK público de Spotify que permita a una app nativa de macOS recibir y reproducir localmente el catálogo con una autorización general y documentada.

Las rutas oficiales se separan así:

- Web Playback SDK: reproducción dentro de un navegador compatible. Spotify no documenta WKWebView, Electron ni otros webviews embebidos como entornos soportados.
- Web API: metadatos, estado y comandos sobre Spotify o un dispositivo Spotify Connect. No entrega un flujo de audio crudo a la app.
- iOS SDK: el SDK actual es App Remote y controla la app de Spotify instalada. Los SDK de streaming móvil anteriores fueron retirados.
- Partner/eSDK: existe playback integrado para hardware aprobado, con solicitud, NDA, certificación y acuerdo de distribución. No es un camino self-service para una app desktop.
- Acuerdo escrito: los términos dejan espacio para productos o dispositivos aprobados por escrito, pero no hay un permiso automático para una app nativa cualquiera.

## Web Playback SDK y WKWebView

La [documentación oficial del Web Playback SDK](https://developer.spotify.com/documentation/web-playback-sdk) lo describe como una biblioteca JavaScript del lado del cliente que crea un dispositivo Spotify Connect local en el navegador. Enumera Chrome, Firefox, Safari y Edge en desktop, y explica requisitos de EME, autoplay e iframes. No enumera WKWebView, webviews embebidos, Electron o CEF.

La [referencia del Player](https://developer.spotify.com/documentation/web-playback-sdk/reference) exige un usuario Premium y usa la protección de contenido del navegador. En la práctica, la reproducción protegida depende del CDM/EME disponible: Spotify documenta Widevine para algunos navegadores, mientras que WebKit usa los mecanismos de Apple. Que WebKit tenga soporte para EME y FairPlay no significa que el Web Playback SDK esté soportado dentro de WKWebView.

Conclusión: un prototipo en WKWebView podría funcionar en algunas versiones, pero no hay soporte oficial ni garantía de compatibilidad, autenticación, DRM o ciclo de vida. Para una app de producción no lo tomaría como una ruta soportada. Una ventana en Safari o Chrome está más cerca de la ruta documentada, aunque deja de ser playback nativo dentro de la app.

## Web API: control remoto, no audio local

Los endpoints oficiales de [Start/Resume Playback](https://developer.spotify.com/documentation/web-api/reference/start-a-users-playback), [Get Playback State](https://developer.spotify.com/documentation/web-api/reference/get-information-about-the-users-current-playback), [Get Available Devices](https://developer.spotify.com/documentation/web-api/reference/get-the-users-available-devices) y [Transfer Playback](https://developer.spotify.com/documentation/web-api/reference/transfer-a-users-playback) permiten iniciar, pausar, consultar y transferir playback a un dispositivo activo. Requieren los scopes correspondientes y, para playback bajo demanda, Premium.

Estos endpoints mandan comandos y devuelven estado, pistas, progreso y dispositivos. La API documentada no devuelve a la app un flujo de audio del catálogo. Esa es la base adecuada para un modo remoto que controle la app oficial de Spotify o un dispositivo Connect.

Sigue aplicando la [Developer Policy](https://developer.spotify.com/policy): hay que mostrar metadatos y portada, se aplican restricciones para streaming y monetización, y está prohibido replicar o reemplazar una experiencia principal de Spotify sin permiso escrito previo.

## iOS SDK

Spotify anunció que los antiguos SDK móviles de streaming dejaron de funcionar y pidió retirarlos antes del 1 de septiembre de 2022 en su [actualización oficial](https://developer.spotify.com/blog/2022-07-15-mobile-streaming-sdks-update). El SDK actual es App Remote: la [documentación de iOS](https://developer.spotify.com/documentation/ios) y su [repositorio oficial](https://github.com/spotify/ios-sdk) explican que la app controla a Spotify instalado en el mismo dispositivo y que Spotify hace el trabajo pesado de playback, red y caché.

No hay documentación oficial para usar ese SDK como motor de audio en macOS, Mac Catalyst o una app desktop nativa. Que una app iOS pueda ejecutarse en Apple silicon no convierte esa integración en un SDK de macOS soportado.

## Partner programs, eSDK y DRM

La vía oficial de playback integrado que sí aparece en la documentación es [Commercial Hardware](https://developer.spotify.com/documentation/commercial-hardware). Spotify indica que acepta solicitudes de organizaciones, no de individuos, y que el proceso incluye evaluación, NDA, acceso al eSDK, pruebas de Certomato, certificación y acuerdo de distribución; ver también el [proceso de onboarding](https://developer.spotify.com/documentation/commercial-hardware/onboarding).

En ese contexto, [Media Delivery](https://developer.spotify.com/documentation/commercial-hardware/implementation/guides/media-delivery) entrega datos al código del partner para que este implemente decoder y salida de audio. También advierte que el soporte de DRM en la aplicación cubre solo una parte de los formatos. Es un camino negociado para productos aprobados, no una librería pública que cualquier app macOS pueda descargar.

Widevine tampoco resuelve la autorización. La [documentación de Google](https://developers.google.com/widevine/drm/overview) muestra soporte de Widevine en Chrome y CEF/Electron, pero no en Safari desktop, y exige acuerdos de licencia para los productos Widevine. Un CDM o licencia DRM genérica no concede acceso al catálogo de Spotify ni reemplaza el permiso de Spotify. En Apple, [WebKit documenta EME](https://webkit.org/blog/8718/new-webkit-features-in-safari-12-1/) y Apple documenta FairPlay para sus dispositivos y Safari; eso no constituye soporte del Web Playback SDK dentro de WKWebView.

Los [Developer Terms](https://developer.spotify.com/terms) incluyen computadoras desktop dentro de los dispositivos aprobados en términos generales, pero también prohíben, entre otras cosas, ingeniería inversa, extracción del código, stream ripping y copias permanentes. La lectura correcta no es que todo playback desktop sea automáticamente ilegal, sino que una implementación local necesita una base autorizada; no basta con conseguir que técnicamente suene.

## Qué hacen otros clientes

| Cliente | Cómo obtiene playback | Qué demuestra |
| --- | --- | --- |
| [Psst](https://github.com/jpochyla/psst) | Cliente GUI nativo en Rust; su núcleo obtiene audio por HTTPS/CDN, decodifica y lo entrega a la salida. Está inspirado en librespot y todavía indica que Spotify Connect remoto no está soportado. | Playback local es técnicamente posible, pero el proyecto no documenta una autorización de Spotify. |
| [ncspot](https://github.com/hrkfdn/ncspot) | Cliente terminal en Rust basado en [librespot](https://github.com/librespot-org/librespot). macOS y Premium son compatibles. | Es un receptor/cliente no oficial basado en una implementación comunitaria. |
| [spotify_player](https://github.com/aome510/spotify-player) | Usa Web API para REST, biblioteca y control; crea una sesión separada de librespot para streaming y Connect. El streaming se puede desactivar al compilar. | La separación Web API + motor local es una arquitectura práctica, no una prueba de autorización. |

En los repositorios revisados no aparece evidencia pública de un acuerdo de partner con Spotify. Por eso no conviene concluir que todos “violan los ToS” como hecho probado; sí se puede concluir que no son una ruta pública soportada por la documentación de Spotify y que tienen riesgo legal, de bloqueo y de mantenimiento. Los ToS además prohíben conductas como ingeniería inversa, ripping y copias permanentes.

## Recomendación para spotify-lite

La arquitectura más sensata es híbrida, con una frontera legal y técnica clara:

1. Modo oficial por defecto: OAuth PKCE, Web API para búsqueda, metadatos, biblioteca y estado, y comandos de transferencia/control remoto. La salida de audio queda en Spotify o en un dispositivo Connect autorizado.
2. Backend opcional: un proceso externo de librespot, aislado detrás de una interfaz PlayerEngine, solo si el producto acepta explícitamente que es experimental, no oficial y fuera de la ruta soportada. Mantenerlo opt-in y removible evita acoplar el resto de la app a ese riesgo, pero aislarlo no cambia su estatus legal.
3. Si el requisito es playback local dentro de la app y cumplimiento estricto: solicitar a Spotify un acuerdo escrito o explorar el programa eSDK/partner. Sin esa aprobación, no prometer playback nativo autorizado.

Así que la respuesta es: sí, Web API + librespot externo opcional es el mejor compromiso técnico para un proyecto que quiere ofrecer ambos modos; no, no se debe describir el conjunto completo como “conforme a los ToS”. El modo remoto es la base de menor riesgo y documentada. El playback local con librespot es una decisión opcional con riesgo propio.

Esto es un análisis técnico de la documentación pública vigente, no asesoría legal.

