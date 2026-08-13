# Onboarding del Client ID por usuario — diseño acordado

Resultado del grilling del ticket #5, 13 de agosto de 2026. Hechos verificados contra la documentación de Spotify vigente a esa fecha.

## Primer arranque

- App **explorable sin configurar**: sidebar visible, área de contenido con una tarjeta central "Get started" que lanza el wizard. Sin estados vacíos por sección ni datos mock.
- El wizard se **auto-abre al primer arranque** como **sheet**, cerrable; si se cierra, queda el CTA "Get started".
- Sin persistencia de progreso: el wizard siempre arranca en el paso 1, con el campo de Client ID pre-llenado si ya había uno.

## Wizard (multi-paso, solo inglés en v1)

1. **Crear la app** en el [Developer Dashboard](https://developer.spotify.com/dashboard): botón que abre el dashboard; instrucciones: nombre, descripción, marcar **Web API**, aceptar los Developer Terms. Aviso: el dashboard puede exigir verificar el email antes de crear apps.
2. **Registrar el redirect URI loopback** `http://127.0.0.1:<puerto>/callback`, pre-escrito con botón de copiar. Advertir que la coincidencia debe ser exacta (mayúsculas, path, slash final). Contexto: desde 2025 Spotify solo documenta como seguras las formas `https://` y loopback; `localhost` ya no vale; los custom schemes (lo que asumía el plan original con `spotifylite://callback`) siguen "oficialmente soportados" pero hay reportes de `INVALID_CLIENT: Insecure redirect URI` en clientes nuevos. **Decisión: loopback**, con mini servidor HTTP local efímero durante el login (el puerto dinámico tiene exención para literales loopback).
3. **Pegar el Client ID**: trim de espacios, no vacío. Si no matchea `^[0-9a-f]{32}$` (formato observado, sin regex oficial), **advertencia amarilla sin bloquear** — el login de prueba es la autoridad final. Se guarda en **UserDefaults** (no es secreto; los tokens sí van a Keychain).
4. **Probar login** (OAuth PKCE real). El onboarding solo se marca completo cuando el flujo devuelve tokens.

## Errores del paso de login → mensajes accionables

| Error | Mensaje del wizard |
|---|---|
| `INVALID_CLIENT: Invalid client` | El Client ID no existe: revísalo y pégalo de nuevo. |
| `Invalid redirect URI` / `Insecure redirect URI` | Vuelve a los settings de tu app y añade exactamente este URI (botón de copiar). |
| HTTP `403` "User not registered" | Tu cuenta no está registrada en la app del dashboard (Development Mode: 5 usuarios autenticados por app; irrelevante si cada usuario crea la suya). |
| HTTP `429` `QUOTA_EXCEEDED` / fallos ligados a Premium | El dueño de la app necesita Premium activo; la cuota se comparte entre los Client IDs de la cuenta (máx. 25 por cuenta desde julio 2026). |

Fallback genérico con enlace a troubleshooting para cualquier otro error.

## Cierre

- Pantalla "You're all set" con botón que cierra la sheet y carga la biblioteca.
- En el paso final, `GET /me` → si `product ≠ premium`: advertencia "Free account: browsing works, playback control won't", sin bloquear, más un badge discreto persistente en la UI.
- Reconfiguración posterior vía **panel de Ajustes** (campo editable + "probar login" + diagnóstico), sin reabrir el wizard.
