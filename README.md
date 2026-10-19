# work-buddy

App de barra de menú para macOS que junta los PRs que dependen de vos y los deja
accionar sin abrir el navegador.

La cola incluye pedidos de review personales y a tus equipos. Las categorías
separan la acción pendiente de los PRs aprobados y la automatización.

En **Configuración**, **Incluir Dependabot de mis equipos** permite seleccionar
los equipos de trabajo con checkboxes, sin mantener una lista de repositorios.
La app consulta sus repos y lee CODEOWNERS en la rama principal: incluye aquellos
cuya última regla general `*` menciona al usuario o a los equipos seleccionados.
Las menciones sólo por carpeta no amplían el alcance. Esta es una señal de
responsabilidad general, no una evaluación de las reglas para cada archivo del PR.
El descubrimiento se guarda por cuenta y equipos durante 24 horas; un fallo
conserva la última lista válida y permite reintentar desde Configuración.
Los PRs abiertos de Dependabot de esos repos se suman a las búsquedas actuales,
sin exigir un pedido de review, y se deduplican en las secciones existentes.
La opción empieza desactivada y respeta el filtro de organizaciones.

**Qué muestra el panel**, de arriba hacia abajo:

| Sección | Qué junta |
| --- | --- |
| **Para mergear** | Tuyos y de automatización que GitHub ya considera mergeables |
| **Para Fixear** | Sólo PRs de tu autoría con CI fallida o en error, incluidos drafts |
| **Para revisar** | Pedido a vos o a tus equipos, sin aprobación tuya vigente ni aprobación agregada de GitHub |
| **Ya aprobados** | `reviewDecision = APPROVED`, sin aprobación tuya vigente: tu review es opcional |
| **Automatización · No listos** _(colapsada)_ | Dependabot esperando CI exitosa, ausencia confirmada de conflictos o salida de draft; bots con CI fallida o que ya aprobaste y esperan otra aprobación, salvo los que ya están en Para mergear |
| **Ignorados** _(colapsada)_ | Los que archivaste a mano |

El badge del icono cuenta lo accionable: lo que espera tu review más lo que podés
mergear de un click y tus PRs con CI por corregir, sin contar dos veces el mismo PR.
Los pedidos a equipos cuentan igual que los personales;
la antigüedad y haber comentado antes no cambian la categoría. Tu aprobación
personal vigente excluye el PR de ambas categorías de review, aunque siga
pedido al equipo. Si se descarta o pedís cambios después, puede volver a aparecer.
La automatización que ya aprobaste y sigue en `REVIEW_REQUIRED` queda en
Automatización · No listos, sin contar en el badge. Dependabot entra en Para revisar o Ya aprobados
sólo con CI exitosa, ausencia confirmada de conflictos y sin ser draft. Mientras espera
esas condiciones permanece en Automatización · No listos y no cuenta ni notifica como review pendiente.
Los demás bots sin fallas de CI se agrupan según sus reviews;
CI pendiente o desconocida conserva su indicador. Los bots
en Para revisar cuentan en el badge y notifican; los listos para mergear aparecen
sólo en Para mergear.

“Para Fixear” respeta filtros, favoritos e ignorados. Un check opcional fallido
puede hacer que el PR aparezca también en “Para mergear”. La automatización
con CI fallida va a su sección, salvo que ya esté lista para mergear. CI pendiente, desconocida o exitosa no entra en “Para Fixear”.

**Acciones por fila** (menú `⋯`): abrir, aprobar, rebasear ramas atrasadas,
mergear, ignorar y dejar de ignorar. Aprobar, rebasear (incluido Dependabot) y
mergear piden confirmación en una barra dentro del panel. Abrir, ignorar y dejar
de ignorar se ejecutan directamente. Un click en el cuerpo de la fila la
selecciona; un doble click abre el PR sin confirmación.

Para Dependabot se muestra **Rebasear con Dependabot** y se envía su comando
específico; el método de merge lo decide el repo, no la app. Abrir el PR actualiza
todas las colas de GitHub. Las escrituras esperan la respuesta de GitHub antes
de actualizar, también cuando fallan. Si ya hay una consulta en curso, se hace
otra al terminar. Ignorar y dejar de ignorar actualizan el panel y el badge
localmente, sin volver a consultar GitHub.

El icono de checkbox en la barra de filtros activa la **selección múltiple**
en la pantalla principal. Las filas conservan su contenido y suman un checkbox.
La selección es individual y admite PRs de personas y de automatización, respetando
los filtros y los ignorados. Al pie, **Aprobar N** y **Mergear N** actúan sobre
los seleccionados de **Para revisar** y **Para mergear**, respectivamente.
Ejecutar una acción conserva la selección del otro grupo. La confirmación es el
botón con la cantidad, incluso si las acciones individuales están configuradas
sin confirmación. El progreso y **Detener** aparecen en esa misma barra; los
resultados por PR se consultan desde su icono de lista.

La selección se conserva al cerrar el panel. Las actualizaciones muestran nuevos
PRs sin seleccionarlos y retiran selecciones que ya no cumplen el criterio o cuyo
commit, base, acción o método de merge cambió. Cada ejecución fija su conjunto y
revalida cada PR contra GitHub antes de escribir. Los merges se envían con el SHA
y método seleccionados, y sólo cuentan como completados si GitHub confirma el merge.
Un merge puede bloquear el siguiente PR; en ese caso se omite hasta otra ejecución.

La cola de ejecución comparte la pausa de un segundo y el manejo de rate limits
entre aprobaciones individuales, aprobaciones en lote y merges en lote. Ante un
límite explícito (incluido `422` con “was submitted too quickly”), respeta
`Retry-After` o `X-RateLimit-Reset`; sin headers espera 60 segundos y aumenta la
espera si se repite. Hay hasta tres intentos y una nueva validación antes de cada
uno, sin repetir acciones ya registradas. Si el límite persiste, omite el resto.
Errores de permisos, validación o transporte incierto no se reintentan.
**Detener** interrumpe la espera y deja terminar una escritura ya enviada.

El **rayito** junto a selección múltiple abre **Autopilot** apagado y con la
cola expandida. Entrar en este modo no ejecuta ninguna acción. La barra inferior
permite encenderlo o apagarlo y expandir la cola hacia arriba, con altura limitada
y scroll. Muestra la operación actual y los pendientes; el historial de resultados
se consulta desde su icono. Las filas principales conservan su presentación.

Autopilot procesa **sólo Dependabot**, primero los merges y luego las aprobaciones,
con los mismos criterios, filtros, ignorados, validaciones y reintentos del batch.
La cola se actualiza con las publicaciones del refresh general, incluso estando
apagado. El PR en curso conserva su snapshot hasta terminar; los pendientes se
agregan o retiran según su estado actual. Una aprobación puede entrar después como
merge cuando GitHub confirme que está listo. Sin pendientes queda esperando.

El modo sigue activo al cerrar el panel y arranca apagado al reiniciar la app.
Mientras está activo, la selección manual queda deshabilitada. Apagarlo interrumpe
esperas y deja terminar una escritura ya enviada. Un cambio de cuenta o un error
tras agotar los reintentos lo detiene. Los éxitos y errores inciertos no se repiten
para el mismo commit, acción, base y método durante la sesión de la app, ni al
volver a encenderlo; los errores quedan para revisión manual. Un PR omitido por
no estar listo puede volver cuando la cola general lo retire y vuelva a admitirlo.

Refresca cada 5 minutos y notifica lo nuevo que te bloquea.

La sección **Jira** reutiliza la sesión del CLI oficial de Atlassian. Si no hay
una sesión activa, muestra `acli jira auth login` para copiar y ejecutar en
Terminal; work-buddy no solicita ni almacena credenciales. **Esperan mi SHR**
muestra los tickets cuyo campo `Stakeholder` contiene la cuenta activa y cuyo
estado es `Stakeholder Review`. **Creados recientemente** muestra los últimos
10 tickets creados por la cuenta activa.

Dentro de la categoría **GitHub**, el botón **Repositorios** abre una lista con búsqueda
y scroll que ocupa todo el panel. Se obtiene de los repositorios distintos de
los resultados de review, automatización y merge, antes de aplicar el filtro.
El **ojo** permite seleccionar varios repos y ver sólo esos; otro click quita
el repo de la selección. **Mute** muestra todos excepto los repos muteados.
Los modos son excluyentes: seleccionar con el ojo limpia los muteos, y mutear
limpia la selección de ojos. Sin selección se ven todos. **Ver todos** limpia el filtro.
El filtro se guarda automáticamente entre reinicios y alcanza las secciones,
el badge y las nuevas notificaciones. Los repos con preferencias guardadas siguen
en la lista aunque no tengan resultados actuales, para poder restaurarlos.

En **Repositorios**, el icono de carpeta permite asociar manualmente la raíz de
un clone o worktree local (con `.git`). La asociación se guarda entre reinicios
y mantiene el repo en la lista aunque no tenga PRs. Pasar el mouse muestra la
ruta; otro click permite cambiarla y el menú contextual permite quitarla. Este
paso solo guarda la carpeta elegida: no clona ni cambia de rama, y no verifica
que el remoto corresponda al repo; las acciones locales lo validan antes de operar.

Con una carpeta asociada, el menú `⋯` del PR ofrece **Abrir en editor**.
Si todavía no elegiste uno, indica que lo configures en **Configuración → Editor**.
La elección se hace únicamente ahí y se guarda como preferencia global; después
el menú muestra **Abrir en RubyMine**, por ejemplo.
Detecta los IDEs de JetBrains (incluidas instalaciones de Toolbox), VS Code,
Cursor, Xcode y otros editores instalados, con **Elegir otra app…** para ubicaciones
personalizadas. Antes de abrir el editor o un agente, verifica un remoto del
repositorio y que la rama local coincida con el commit mostrado en el PR. Si falta
la rama local, usa la rama del remoto verificado y consulta ese remoto si hace
falta. No resetea ramas ni descarta cambios locales. Si la rama está desactualizada,
el PR viene de un fork con otra revisión o la carpeta es incorrecta, explica el
problema y no abre automáticamente: actualizá o hacé checkout del PR manualmente
y reintentá. Luego del cambio de rama vuelve a verificar el commit.

## Requisitos

- macOS 14+
- Command Line Tools de Xcode (`xcode-select --install`). **No** hace falta Xcode completo.
- Atlassian CLI (`acli`) para la sección Jira.

## Configuración

El engranaje del panel abre la configuración del entorno:

- **Idioma:** español o inglés, aplicado al instante y guardado entre reinicios.
  Se conserva español por defecto.

- **Organización de GitHub:** opcional; limita todas las búsquedas a ese owner.
  Vacía conserva el alcance global de `@me`.
- **Cuentas de automatización:** logins que GitHub reporta como `User`, pero que
  deben tratarse como bots. Los GitHub Apps ya se detectan automáticamente.

Se guardan identificadores en `UserDefaults`, nunca tokens. La autenticación y
los permisos siguen a cargo de la sesión activa del CLI `gh`.

## Correr

```bash
./Scripts/run.sh          # compila (debug), instala y reinicia
./Scripts/run.sh release  # igual pero optimizado
```

La app queda instalada en `~/Applications/Work Buddy.app`, con su propio icono.
Podés abrirla desde Finder y agregarla a los ítems de inicio de macOS. Corre como
proceso `WorkBuddy`, independiente de la terminal, y aparece en el Dock y en
⌘Tab. Clickear su icono en el Dock abre el panel. El icono de órbita también
aparece en la barra de menú, a la derecha.

Cada ejecución reemplaza esa misma copia después de compilar y verificar su
firma. Si la compilación falla, la app abierta sigue funcionando. Para instalar
en otra carpeta, usá `WORK_BUDDY_APP_DIR` tanto al correr como al hacer watch.

- **Click izquierdo** → abre/cierra el panel
- **Click derecho** → menú contextual (Acerca de / Salir)
- El panel se cierra solo al perder el foco (se oculta, no sale)

Para cerrarla, usá ⌘Q, el botón "Salir" del panel, el menú de la app o el del Dock.

### Usar en otra computadora y actualizar desde Git

En la computadora donde se usa la app, con el repositorio clonado y las
dependencias instaladas:

```bash
./Scripts/run.sh
./Scripts/watch-main.sh
```

El watch consulta `origin/main` cada 5 segundos. Cuando pusheás commits desde la
computadora de desarrollo, actualiza el checkout, compila e instala la nueva
versión en la misma ubicación. No hace falta copiar el `.app` a mano. El watch
necesita seguir corriendo para recibir actualizaciones; cerrarlo no cierra la app.
La computadora de uso también necesita las Command Line Tools y sus propias
sesiones de `gh` y `acli`. El watch no pushea commits locales y pausa si encuentra
conflictos o si el checkout está en otro branch.

También compara el commit del checkout con el de la app instalada: si hiciste
un pull manual, falta instalarla o una compilación anterior falló, la actualiza
sin necesitar otro commit. Los errores se reintentan cada 60 segundos y quedan
en `build/watch-main.log`. Espera a que el checkout esté limpio antes de compilar.

## Tests

```bash
./Scripts/test.sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/Scripts
```

Con las Command Line Tools y SDK 27, corré los tests Swift con
`SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk ./Scripts/test.sh`.
Los tests de scripts verifican la instalación y la recuperación ante errores
sin tocar la app instalada.

Usá el script y no `swift test` directo: SwiftPM no le pasa el search path de
`Testing.framework` ni el rpath de `lib_TestingInterop.dylib` cuando el
developer dir activo son las Command Line Tools, aunque los dos vienen
incluidos. Sin los flags falla con `no such module 'Testing'`.

Los tests cubren lo que es función pura y ya se equivocó contra datos reales: la
clasificación en buckets, la agrupación, los argumentos de las escrituras y la
forma de las queries de búsqueda. Cada caso que salió de un bug real tiene el PR
concreto en un comentario.

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

## Probar sin GUI

```bash
swift build && .build/debug/WorkBuddy --dump-queue      # cola completa, agrupada
```

Trae lo mismo que el panel —personas, dependabot y candidatos a merge— y agrega
el cálculo del badge, así se puede comparar contra lo que se ve en la app.

Para lo que depende del bundle (notificaciones, UserDefaults, panel) hay que
correr el binario **de adentro** del `.app`, si no `Bundle.main` no resuelve:

```bash
./Scripts/build.sh
APP="build/work-buddy.app/Contents/MacOS/WorkBuddy"
WORK_BUDDY_DEBUG=1 "$APP" --open-panel     # abre el panel al arrancar, log a stderr
"$APP" --check-notifications               # diagnostica permisos de notificación
```

## Compilar sin lanzar

```bash
./Scripts/build.sh        # imprime la ruta del .app generado en build/
swift build               # solo el ejecutable, sin bundle
```

El script usa una identidad Apple de firma de código disponible en el llavero.
Podés elegir una con `WORK_BUDDY_SIGNING_IDENTITY`. Sin identidad disponible,
usa firma ad-hoc y avisa que macOS puede rechazar las notificaciones.

En Configuración, **Habilitar** guarda la preferencia de envíos automáticos y
**Probar** manda una notificación. Ambos requieren el permiso de macOS: si ya
está denegado, se debe permitir una vez en Configuración del Sistema →
Notificaciones → work-buddy; la app no puede concederse ese permiso.

Cada PR que entra en **Para revisar** o **Para mergear** genera su propia
notificación, sin agrupar. Se usan las mismas listas del panel, incluidos los
bots por revisar sin fallas de CI y los listos para mergear. La primera carga de cada sección es silenciosa;
si un PR sale y vuelve a entrar, vuelve a avisar.

## Estructura

```
Sources/WorkBuddy/
├── main.swift               Punto de entrada. NSApplication en modo .regular.
├── AppDelegate.swift        Ciclo de vida. Instancia el MenuBarController.
├── MenuBarController.swift  NSStatusItem + NSPopover, clicks, badge, foco.
├── GitHub/
│   ├── GH.swift             Invoca el CLI `gh`. Retry ante 502.
│   ├── PullRequestNode.swift DTO y campos GraphQL compartidos.
│   ├── PullRequestSearch.swift Búsqueda paginada que comparten las colas.
│   ├── ReviewQueue.swift    Cola de review de personas.
│   ├── DependabotQueue.swift Cola de dependabot (query aparte, ver supuesto 3).
│   ├── FixQueue.swift       PRs propios, paginados; el dominio filtra la CI fallida.
│   ├── MergeQueue.swift     Candidatos a merge (tres búsquedas, una request).
│   ├── BehindCount.swift    Cuántos commits atrás está cada PR (batches de 20).
│   └── GitHubWrite.swift    Escrituras: rebase, aprobar y mergear.
├── Jira/ACLI.swift          Estado de autenticación del CLI de Atlassian.
├── Domain/PullRequestQueuePolicy.swift Reglas de clasificación y agrupación.
├── Models/
│   ├── AppConfiguration.swift Configuración persistente del entorno.
│   ├── PullRequest.swift    Datos y estado del PR.
│   ├── ReviewQueueStore.swift Estado del panel, refresh, acciones.
│   ├── IgnoreList.swift     PRs ignorados, persistidos.
│   └── PullRequestAction.swift Acciones sobre un PR.
├── Localization/            Claves semánticas y catálogos Spanish.swift / English.swift.
├── Notifications/Notifier.swift
├── Views/                   PanelView y PullRequestRow.
└── Debug/                   Volcados y diagnósticos por CLI.

Resources/Info.plist         LSUIElement, bundle id, versión.
Resources/AppIcon.icns       Icono de la app (generador en Scripts/).
Scripts/                     build.sh, run.sh, test.sh.
Tests/WorkBuddyTests/        Clasificación, agrupación, merge, ignorados.
```

## Supuestos medidos

Varias decisiones salieron de medir la API, no de leer documentación: son
correctas hoy y pueden podrirse en silencio. Están documentadas en
[docs/supuestos.md](docs/supuestos.md), con qué las respalda y cómo detectar que
dejaron de valer. **Leelo antes de tocar las queries.**

## Pendientes

[docs/pendientes.md](docs/pendientes.md) tiene lo que quedó propuesto sin decidir,
lo que se descartó **a propósito** (con el motivo, para no volver a proponerlo), y
lo que está implementado pero sin verificar.

## Decisiones de diseño

**AppKit para el ciclo de vida, SwiftUI para el contenido.** Se podría usar
`MenuBarExtra` de SwiftUI y ahorrar código, pero deja poco control sobre cuándo se
abre y cierra el panel, y sobre su tamaño. Con `NSStatusItem` + `NSPopover` y
`NSHostingController` adentro tenemos el control de AppKit y la ergonomía de SwiftUI.

**SwiftPM y bundle armado a mano** en vez de un `.xcodeproj`. Se compila desde la
terminal sin Xcode instalado, y el `Package.swift` es más fácil de revisar en un diff
que un project file.

## Para agregar funciones

El hueco es `PanelView.content`. El `popover` se configura en
`MenuBarController.configurePopover()` si hay que cambiar el tamaño.

## Textos e idiomas

Los textos de la interfaz, tooltips, accesibilidad, errores y notificaciones
están en `Sources/WorkBuddy/Localization/`, agrupados por funcionalidad.
`LocalizationKey.swift` define las claves y cada idioma implementa un `switch`
exhaustivo: agregar una clave obliga a traducirla en ambos catálogos al compilar.
Para usarla, llamá a `L10n.text(.settingsTitle)`. Los textos con variables usan
`%@` y argumentos separados; los plurales tienen frases completas por idioma.

Los catálogos se compilan dentro del ejecutable. La selección se lee de
`UserDefaults` una vez y se mantiene en memoria con acceso sincronizado.
SwiftUI observa esa selección sin reconstruir el panel ni perder sus borradores;
la locale del panel también cambia para el formato nativo de fechas. No se leen
archivos ni se parsean recursos durante el renderizado. Los mensajes visibles
conservan su expresión de origen para poder traducirse de nuevo.

Los nombres de repositorios, títulos de PRs/tickets, respuestas externas de los
CLIs, comandos y diagnósticos de desarrollo se conservan tal como vienen.
