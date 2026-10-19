# Desarrollo

Ejecutá los comandos desde la raíz del repositorio.

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

En Configuración → GitHub, **Habilitar** guarda la preferencia de envíos automáticos y
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
├── Jira/                   Autenticación ACLI y ejecución de consultas JQL configurables.
├── Domain/PullRequestQueuePolicy.swift Reglas de clasificación y agrupación.
├── Models/
│   ├── AppConfiguration.swift Configuración persistente de GitHub.
│   ├── JiraConfiguration.swift Opt-in experimental y consultas de Jira.
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
