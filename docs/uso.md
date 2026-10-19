# Guía de uso

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
estado es `Stakeholder Review`. Si Jira rechaza la consulta porque el campo o el
estado no están disponibles, el error indica qué revisar y conserva el detalle
del CLI. **Creados recientemente** muestra los últimos
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
