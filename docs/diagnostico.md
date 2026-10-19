# Diagnóstico de rendimiento

Ejecutá los comandos desde la raíz del repositorio.

## Diagnosticar una carga lenta en otra máquina

La app registra automáticamente las últimas **10 actualizaciones aceptadas en
total**, identificando GitHub y Jira por separado y priorizando las que siguen
en curso para no perder una consulta trabada mientras el otro servicio actualiza.
No hace falta abrir Terminal
ni activar debug. Click derecho en el icono → **Exportar diagnóstico…** guarda
un `.txt` que se puede adjuntar para analizarlo. Exportalo mientras ocurre la
demora o apenas termina; si la app se congeló, reiniciala y exportá enseguida.

El archivo incluye versión y revisión del build, tiempos de cada fase y de
publicación, cantidades de PRs/páginas/lotes, concurrencia de búsquedas de equipos,
reintentos y aciertos/edad del caché
de ownership. Las fases pendientes quedan registradas desde su inicio. Distingue
las actualizaciones en curso de las interrumpidas por un cierre anterior.
`firstContent` mide la primera publicación con contenido disponible para el panel,
no el tiempo de renderizado de SwiftUI; `queuesLoaded` y `refreshEnded` distinguen
las colas listas del trabajo posterior de comparación de ramas. Un ciclo terminado
puede contener fallos parciales: hay que revisar sus eventos y categorías de error.

No registra tokens, argumentos, queries, respuestas, mensajes de error crudos,
nombres de repositorios/equipos/usuarios, IDs de PRs, títulos ni comentarios.
No envía datos automáticamente. Los archivos locales están en
`~/Library/Application Support/work-buddy/Diagnostics/`, limitados a 128 KiB
por actualización y aproximadamente 1,25 MiB en total. Si una captura llega al
límite incluye un evento `truncated`; no debe interpretarse como un registro completo.
Las escrituras se hacen en una cola fuera del hilo de la interfaz.

El mismo archivo incluye las últimas **10 aperturas del panel**, en un historial
separado (`Diagnostics/Panels/`, hasta 16 KiB por apertura). Abrir y cerrar el panel
no expulsa las cargas de GitHub/Jira. Cada apertura registra:

- `panelOpen`: desde que se atiende la apertura hasta `popoverDidShow` de AppKit.
  Es una señal de ventana mostrada, no una medición del primer frame del compositor.
- `panelRefresh`, `panelLayout` y `panelShow`: trabajo síncrono antes de mostrarla.
- `opening` y `hasSnapshot`: número de apertura en esta sesión y si GitHub ya tenía
  una carga completa en memoria. Permiten comparar primera apertura y reaperturas.
- `mainThreadDelayed`: retrasos del run loop principal de al menos 100 ms respecto
  de una sonda cada 250 ms, sólo mientras el panel está abierto. Al cerrar se guardan
  cantidad y máximo. El reloj excluye el tiempo con la máquina dormida. Es una muestra
  de capacidad de respuesta, no un medidor de FPS ni una prueba de ausencia de tirones.

Para diagnosticar falta de fluidez, abrí/cerrá el panel varias veces y usá la lista
mientras se actualiza. Después cerralo y exportá el diagnóstico como siempre.
Las colas publican cada resultado al terminar su consulta; el estado de carga y las
notificaciones esperan las fuentes necesarias. Una consulta secundaria fallida
conserva sus últimos datos y una carga cancelada no publica respuestas tardías.

### Ajustar búsquedas simultáneas de equipos

Las búsquedas de PRs de Dependabot en repos de equipos usan **2 grupos simultáneos**
por defecto. Para comparar en otra máquina, cerrá la app, ejecutá allí:

```bash
defaults write dev.martintuk.work-buddy performance.teamSearchConcurrency -int 4
```

Volvé a abrirla. La preferencia persiste y admite valores de **1 a 8**; los valores
fuera del rango se limitan a sus extremos. `1` recupera la ejecución secuencial.
Para volver al valor predeterminado:

```bash
defaults delete dev.martintuk.work-buddy performance.teamSearchConcurrency
```

El límite aplica sólo a estos grupos: las otras colas también consultan en paralelo.
Cada grupo pagina en serie y un lugar libre se reutiliza al terminar. Se conservan
el orden de resultados, la deduplicación y el rechazo de respuestas parciales.
El diagnóstico incluye `concurrency` y `searches` en `teamDependabot` y distingue
`rate_limited` cuando el error de GitHub lo indica, sin guardar el mensaje crudo.

Probá 2, 4 y 6 con dos cargas completas por valor, sin forzar el redescubrimiento
de ownership. Compará tiempos de `teamDependabot`, `queuesLoaded` y `refreshEnded`,
además de reintentos y errores. Exportá antes de cambiar de valor para conservar
ambas cargas. Si el tiempo deja de mejorar, conservá el menor valor; ante un límite
de GitHub, respetá el tiempo de espera indicado antes de volver a probar.
