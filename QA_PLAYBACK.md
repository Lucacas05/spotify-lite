# QA de reproducción y cola

Prueba manual realizada el 13 de agosto de 2026 con la app Debug autenticada y un dispositivo Spotify Connect activo.

## Funcionamiento verificado

- Doble clic en un resultado inicia la canción seleccionada.
- Play/Pause cambia y refleja correctamente el estado.
- `Reproducir siguiente` añade canciones a la cola en el orden enviado.
- El popover de cola carga y actualiza los elementos de Spotify.
- Siguiente consume los elementos añadidos manualmente.

Flujo probado:

1. Reproducir `Instant Crush (feat. Julian Casablancas)`.
2. Añadir `One More Time`, `Lose Yourself to Dance` y `Veridis Quo`.
3. Verificar ese mismo orden en la cola.
4. Avanzar entre las canciones y reanudar la reproducción.

## Pendientes encontrados

### P1 — Serializar comandos de reproducción y esperar estado confirmado

Al pulsar Siguiente y Anterior rápidamente, la barra todavía mostraba la canción previa y los comandos terminaron en un estado distinto al esperado. El código solo espera 400 ms antes de refrescar y permite varios comandos simultáneos.

Implementación propuesta:

- Añadir estado `commandInFlight` y desactivar temporalmente los controles afectados.
- Serializar comandos player en un actor o una cola dedicada.
- Después de un comando, consultar playback con backoff corto hasta observar el cambio o alcanzar un timeout.
- Mostrar progreso discreto; si Spotify no confirma el cambio, recuperar el estado real y mostrar un error.

Esto también responde a una limitación oficial: Spotify indica que el orden de ejecución no está garantizado al combinar `Add to Queue`, `Next`, `Previous` y otros endpoints Player.

### P1 — Definir explícitamente el comportamiento de Anterior

Desde `Veridis Quo`, Anterior no regresó a `Lose Yourself to Dance`; Spotify volvió a `Instant Crush` y quedó pausado. La app actualmente delega completamente en `POST /me/player/previous` y no mantiene historial propio.

Alternativas:

- Mantener la semántica nativa de Spotify. Es consistente con el dispositivo Connect, pero no garantiza volver al elemento anterior de la cola manual.
- Mantener historial local y forzar `play(trackURI:)`. Da control determinista, pero puede reemplazar el contexto/cola de Spotify y desincronizarse si otro dispositivo controla la sesión.

Recomendación: mantener la semántica oficial y mejorar el feedback/sincronización antes de inventar un historial paralelo.

### P2 — Diferenciar cola manual de contexto/autoplay

Después de los tres elementos manuales, Spotify devolvió varias repeticiones de `Instant Crush`. `GET /me/player/queue` entrega una sola lista y no identifica el origen de cada elemento, por lo que la UI actual mezcla cola manual, contexto y autoplay.

Mejora posible: marcar localmente los URI añadidos desde SpotifyLite y mostrar una sección “Añadido desde SpotifyLite”. Este marcado sería aproximado: se pierde al reiniciar y puede quedar obsoleto si otro dispositivo modifica la cola.

### P2 — Eliminar, reordenar o vaciar la cola

No está implementado y la Web API oficial expone únicamente lectura de cola y adición al final; no ofrece endpoints para eliminar, reordenar o vaciar elementos de la cola de reproducción.

Alternativa parcial: mantener una cola propia y reemplazar la reproducción con una lista de URI. El coste es alto: deja de representar fielmente la cola compartida de Spotify Connect y puede sobrescribir el contexto actual.

## Referencias oficiales

- https://developer.spotify.com/documentation/web-api/reference/get-queue
- https://developer.spotify.com/documentation/web-api/reference/add-to-queue
- https://developer.spotify.com/documentation/web-api/reference/skip-users-playback-to-next-track
