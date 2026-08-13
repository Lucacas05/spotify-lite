# Release de SpotifyLite

## Preparación única

1. Tener un certificado **Developer ID Application** instalado en el Keychain.
2. Guardar las credenciales de notarización sin secretos en el repositorio:

```bash
xcrun notarytool store-credentials spotifylite-notary \
  --apple-id "tu-apple-id" --team-id "TEAMID" --password "app-specific-password"
```

3. Comprobar que `project.yml` contiene la versión correcta.

## Crear el DMG

```bash
DEVELOPER_ID="Developer ID Application: Tu Nombre (TEAMID)" \
DEVELOPMENT_TEAM="TEAMID" \
NOTARY_PROFILE="spotifylite-notary" \
./scripts/release.sh
```

El script genera `build/release/SpotifyLite-<versión>.dmg` y su SHA-256. Archiva en Release, firma con Hardened Runtime, notariza y grapa tanto la app como el DMG, y valida el resultado con `codesign`, `stapler` y `spctl`.

## Validación manual antes de publicar

- Instalar el DMG en una cuenta de macOS donde SpotifyLite nunca se haya ejecutado.
- Completar OAuth, reiniciar la app y verificar que la sesión persiste.
- Probar búsqueda, playlists, Liked Songs, álbum/artista, cola, selector de dispositivo y controles.
- Revocar temporalmente red/token y verificar que aparece un error recuperable.
- Confirmar en Instruments que no hay timers activos al ocultar la app y que el uso en reposo cumple el objetivo.

La notarización real requiere credenciales de Apple y por eso no puede completarse en CI o una máquina nueva sin configurar el perfil del Keychain.
