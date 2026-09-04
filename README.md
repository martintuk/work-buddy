# work-buddy

App de barra de menú para macOS que junta los PRs que dependen de vos y los deja
accionar sin abrir el navegador.

La cola incluye pedidos de review personales y a tus equipos. Las categorías
separan la acción pendiente de los PRs aprobados y la automatización.

**Qué muestra el panel**, de arriba hacia abajo:

| Sección | Qué junta |
| --- | --- |
| **Para mergear** | Tuyos y de automatización que GitHub ya considera mergeables |
| **Para Fixear** | Sólo PRs de tu autoría con CI fallida o en error, incluidos drafts |
| **Para revisar** | Pedido a vos o a tus equipos, sin aprobación tuya vigente ni aprobación agregada de GitHub |
| **Ya aprobados** | `reviewDecision = APPROVED`, sin aprobación tuya vigente: tu review es opcional |
| **Automatización** _(colapsada)_ | Bots y cuentas de máquina con CI fallida o en error, salvo los que ya están en Para mergear; favoritos y actividad reciente |
| **Ignorados** _(colapsada)_ | Los que archivaste a mano |

El badge del icono cuenta lo accionable: lo que espera tu review más lo que podés
mergear de un click y tus PRs con CI por corregir, sin contar dos veces el mismo PR.
Los pedidos a equipos cuentan igual que los personales;
la antigüedad y haber comentado antes no cambian la categoría. Tu aprobación
personal vigente excluye el PR de ambas categorías de review, aunque siga
pedido al equipo. Si se descarta o pedís cambios después, puede volver a aparecer.
La automatización sin fallas de CI se agrupa en Para revisar o Ya aprobados,
según sus reviews. CI pendiente o desconocida conserva su indicador. Los bots
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
que el remoto corresponda al repo; las acciones locales deberán validarlo antes
de operar.

Con una carpeta asociada, el menú `⋯` del PR ofrece **Abrir en editor**.
Si todavía no elegiste uno, indica que lo configures en **Configuración → Editor**.
La elección se hace únicamente ahí y se guarda como preferencia global; después
el menú muestra **Abrir en RubyMine**, por ejemplo.
Detecta los IDEs de JetBrains (incluidas instalaciones de Toolbox), VS Code,
Cursor, Xcode y otros editores instalados, con **Elegir otra app…** para ubicaciones
personalizadas. Abre la carpeta en su rama actual, sin cambiar el checkout.

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
./Scripts/run.sh          # compila (debug), mata la instancia previa y lanza
./Scripts/run.sh release  # igual pero optimizado
```

El icono de órbita aparece en la barra de menú, a la derecha.

- **Click izquierdo** → abre/cierra el panel
- **Click derecho** → menú contextual (Acerca de / Salir)
- El panel se cierra solo al perder el foco (se oculta, no sale)

Como la app no tiene icono en el Dock, para cerrarla usá el botón "Salir" del panel,
el menú contextual, o `pkill -x WorkBuddy`.

## Tests

```bash
./Scripts/test.sh
```

Usá el script y no `swift test` directo: SwiftPM no le pasa el search path de
`Testing.framework` ni el rpath de `lib_TestingInterop.dylib` cuando el
developer dir activo son las Command Line Tools, aunque los dos vienen
incluidos. Sin los flags falla con `no such module 'Testing'`.

Los tests cubren lo que es función pura y ya se equivocó contra datos reales: la
clasificación en buckets, la agrupación, los argumentos de las escrituras y la
forma de las queries de búsqueda. Cada caso que salió de un bug real tiene el PR
concreto en un comentario.

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
├── main.swift               Punto de entrada. NSApplication en modo .accessory.
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
