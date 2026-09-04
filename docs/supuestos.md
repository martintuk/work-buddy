# Supuestos medidos

Varias decisiones de esta app salieron de medir la API o el sistema, no de leer
documentación. Eso las hace correctas hoy y frágiles mañana: si cambia el dato
de fondo, la app no falla con un error, empieza a **omitir cosas en silencio**.

Cada entrada dice qué asumimos, qué lo respalda, qué se rompe si deja de valer, y
cómo darse cuenta. Las mediciones son del **2026-09-02** salvo aclaración.

---

## 1. Todos los repos exigen review

**Dónde:** `MergeQueue.query`, el filtro `review:approved` — **sólo** en la
búsqueda `review-requested:@me`. Las otras dos (`author:@me` y `reviewed-by:@me`)
no lo llevan, justamente para no depender de este supuesto: ahí el conjunto es
chico (1 y 12 PRs) y el filtro no compraba nada.

**Asumimos** que un PR mergeable siempre tiene `reviewDecision = APPROVED`, así
podemos recortar la búsqueda del lado del servidor.

**Medición:** sobre 56 PRs de la cola, 45 estaban `BLOCKED` esperando review. De
los que GitHub consideraba mergeables, **ninguno** carecía de `APPROVED`. El
filtro recortó 56 → 2 sin perder nada.

**Por qué importa:** pedirle a GitHub `mergeable` lo obliga a calcular la
mergeabilidad, que es la parte cara de la query. Sin este filtro hay que traer la
cola completa: 3 páginas y ~17s en vez de 1 y ~4s.

**Qué se rompe:** si un repo deja de exigir review, un PR mergeable donde todavía
figurás como reviewer tendría `reviewDecision = null` y **no aparecería** en
"Para mergear". No hay error: la sección muestra menos de lo que debería.
El impacto está acotado, porque si además lo revisaste vos lo levanta
`reviewed-by:@me`, que no filtra.

**Cómo detectarlo:** comparar contra un fetch sin el filtro.

```bash
# Con el filtro (lo que usa la app)
gh api graphql -f query='query{search(query:"is:open is:pr review-requested:@me review:approved archived:false",type:ISSUE,first:1){issueCount}}' --jq '.data.search.issueCount'

# Sin el filtro, contando los que GitHub deja mergear
gh api graphql -f query='query{search(query:"is:open is:pr review-requested:@me archived:false",type:ISSUE,first:25){nodes{... on PullRequest{mergeable mergeStateStatus reviewDecision}}}}' \
  | python3 -c 'import sys,json; n=[x for x in json.load(sys.stdin)["data"]["search"]["nodes"] if x]; print([x["reviewDecision"] for x in n if x["mergeable"]=="MERGEABLE" and x["mergeStateStatus"] in ("CLEAN","UNSTABLE","HAS_HOOKS")])'
```

Si el segundo comando imprime algún `None`, el supuesto ya no vale.

---

## 2. El alcance lo define `review-requested`, no una lista de repos

**Dónde:** `ReviewQueue.searchQuery` y `DependabotQueue.searchQuery`. Es el
supuesto que sostiene que esta app **no tenga** un `repos.txt`. Si se configura
una organización, ambas agregan `org:<organización>` al filtro.

**Asumimos** que `review-requested:@me` ya incluye los pedidos que te llegan por
pertenecer a un equipo, no sólo los directos. Si eso vale, la lista de repos
relevantes la mantienen CODEOWNERS y la pertenencia a equipos, que están siempre
al día porque los usa GitHub para rutear.

**Medición (2026-09-03):**

| | Todo | Sólo dependabot |
| --- | --- | --- |
| `review-requested:@me` | 57 | 50 |
| `user-review-requested:@me` (sólo directos) | 27 | 21 |

Los 50 de dependabot se parten en 21 directos y 29 que llegan vía cuatro equipos.
Contra la whitelist de una herramienta anterior, de 23 repos:

- **14 repos** en las dos.
- **8 sólo en la lista.** De esos, **7 no tenían ningún PR de dependabot
  abierto**, y el octavo tenía 4 asignados a un equipo del que el usuario no
  formaba parte. O sea que la lista no agregaba nada y metía trabajo ajeno.
- **7 sólo vía la query**, que la lista había olvidado.

**Qué se rompe:** si GitHub cambiara `review-requested:` para que signifique
sólo-directos (hoy eso es `user-review-requested:`), el panel perdería en
silencio los 29 PRs que llegan por equipo. También se rompe al revés: si te
agregan a un equipo con muchos repos, la cola crece sin que nadie lo pida.

**Cómo detectarlo:** que los dos contadores se igualen.

```bash
for q in review-requested user-review-requested; do
  printf "%-24s " "$q"
  gh api graphql -f query="query{search(query:\"is:open is:pr $q:@me archived:false\",type:ISSUE,first:1){issueCount}}" --jq '.data.search.issueCount'
done
```

Si dan el mismo número, o `review-requested` da menos, el supuesto ya no vale.

---

## 3. Los dos filtros de autor son complementarios exactos

**Dónde:** `ReviewQueue.searchQuery` lleva `-author:app/dependabot`;
`DependabotQueue.searchQuery` lleva `author:app/dependabot`.

**Por qué están separadas:** dependabot es 50 de los 57 PRs de la cola. En una
sola query hacen falta 3 páginas y ~17s; separadas, la de personas entra en una
página y el panel aparece en ~4s, y dependabot se carga en segunda fase.

**Asumimos** que entre las dos no se pierde ni se duplica nada, y por eso
`ReviewQueueStore.reviewQueue` las concatena **sin deduplicar**. Lo fija
`QueryShapeTests.complementarias`.

**Qué se rompe:** si la org migra a Renovate, sus PRs caen en la cola de
personas —el filtro no los excluye— y aparecen entre los que esperan tu review,
inflando el badge. `Author.isBot` los saca de las secciones de personas sólo si
GitHub los tipa como `Bot` (ver #4).

**Cómo detectarlo:** `--dump-queue` imprime `personas: N | dependabot: M`. Si
`personas` sube mucho o aparecen logins de bot ahí, el supuesto cayó.

---

## 4. Las cuentas de máquina configuradas están completas

**Dónde:** la sección Configuración del panel y `AppConfiguration`.

**Asumimos** que `__typename == "Bot"` más los logins configurados cubren toda la
automatización.

**Medición:** en el entorno original, `__typename` clasificó casi todas las
cuentas automáticas. Una cuenta de servicio venía tipada como `User` y requirió
configuración explícita.

**Qué se rompe:** una cuenta de máquina nueva tipada como `User` se cuenta como
persona. Eso **infla el badge** y **dispara notificaciones** por PRs de bots, que
es justo lo que el diseño evita.

**Cómo detectarlo:** logins que no reconocés en "Para revisar". Para revisar la
clasificación actual:

```bash
gh api graphql -f query='query{search(query:"is:open is:pr review-requested:@me archived:false",type:ISSUE,first:100){nodes{... on PullRequest{author{login __typename}}}}}' \
  | python3 -c 'import sys,json,collections; n=json.load(sys.stdin)["data"]["search"]["nodes"]; print(collections.Counter(((x.get("author") or {}).get("__typename"),(x.get("author") or {}).get("login")) for x in n if x))'
```

---

## 5. `NSApp.isActive` distingue menú interno de pérdida de foco

**Dónde:** `MenuBarController.autoClose()`.

**Asumimos** que abrir un menú *dentro* del panel deja la app activa, y que
perder el foco de verdad la desactiva. Es lo que evita que abrir el menú `⋯`
cierre el panel.

**Medición:** con el panel enfocado, `NSApp.isActive = true` y la ventana es key.
Al activar otra app, el handler de `didResignKey` recibe `isActive = false`.
macOS 26.6.2.

**Qué se rompe:** si macOS cambia cuándo una app `.accessory` se considera
activa, el panel se cierra al abrir el menú de acciones (o deja de cerrarse al
perder el foco).

**Cómo detectarlo:** abrir el menú `⋯` y ver si el panel se cierra. Con log:

```bash
./Scripts/build.sh
WORK_BUDDY_DEBUG=1 "build/work-buddy.app/Contents/MacOS/WorkBuddy" --open-panel
```

---

## 6. Batches de 20 comparaciones de rama por request

**Dónde:** `BehindCount.batchSize`.

**Qué medimos:** `Ref.compare(headRef:)` de GraphQL devuelve el mismo `behindBy`
que la compare API de REST (verificado contra un PR real: 1 y 1), y
se puede batchear con un alias `repository` por PR. Comparado:

| | REST | GraphQL batcheado |
| --- | --- | --- |
| Requests para 20 PRs | 20 | **1** |
| Bytes | ~540 KB (27 KB × 20) | **820** |
| Tiempo | serial | 3.8s |

`per_page=1` **no** reduce el payload de REST: el bulto son los `files` del diff.

**Qué se rompe:** si GitHub endurece el límite de costo, un batch de 20 podría
empezar a fallar. Cuando un batch falla, esos PRs quedan **sin medir** —
`behindCount` devuelve `nil` y la UI muestra `↓?`. No reporta 0.

**Cómo detectarlo:** badges `↓?` donde antes había números. Bajar `batchSize`.

**Cuidado con esto:** interpolamos owner, nombre y refs en la query. Es seguro
porque git no permite comillas, barras invertidas ni espacios en un ref, y
`BehindCount.isSafeRef` lo verifica. Si alguna vez hace falta soportar un
carácter raro, hay que pasar a variables de GraphQL, no a escapar a mano.

---

## 7. Tamaño de página: lo que decide el límite es `mergeable`

**Dónde:** `ReviewQueue.pageSize` (25) y `DependabotQueue.pageSize` (50).

**Medición**, con `reviewRequests` + `latestReviews` + `commits` anidados:

| Campos | `first:` | Resultado |
| --- | --- | --- |
| `PullRequestFields.base` | 100 | **502** consistente |
| `PullRequestFields.base` | 50 | OK, **5/5**, ~9s (2026-09-03) |
| `PullRequestFields.base` | 25 | OK |
| `base` + `mergeable` | 50 | **502**, 3/3 (2026-09-03) |
| `base` + `mergeable` | 25 | OK |

Dos conclusiones que cuestan plata equivocarse:

1. **El costo lo domina `mergeable`, no la cantidad de campos.** Al principio
   supuse lo contrario y empecé a armar un set liviano sin `latestReviews` para
   que dependabot entrara en una página. Medirlo mostró que el set completo entra
   igual; el set liviano sólo habría perdido `reviewedByMe` y `approvals` a
   cambio de nada.
2. **`ReviewQueue` pagina de 25 por conservador, no por necesidad.** 50 anda.
   Quedan 7 PRs ahí, así que no cambia nada.

Aparte, la misma query devuelve 502 **intermitente** (~1 de cada 4 intentos), y
por eso existe `GH.runRetrying`.

**Qué se rompe:** si GitHub endurece los límites, hay que bajar el tamaño. Si los
afloja, seguimos paginando de más — cuesta latencia, nada más. Lo que **no** hay
que hacer es agregarle `mergeable` a `DependabotQueue`: eso rompe seguro. Lo fija
`QueryShapeTests.dependabotSinMergeable`.

**Cómo detectarlo:** errores `HTTP 502` que sobreviven a los 4 reintentos.

---

## 8. Rutas donde vive `gh`

**Dónde:** `GH.candidatePaths`.

**Por qué está hardcodeado:** una app lanzada desde Finder **no hereda el PATH
del shell**, así que invocar `gh` a secas no resuelve. Buscamos en rutas
absolutas y, como último recurso, en el PATH que sí tengamos.

**Qué se rompe:** un `gh` instalado en un prefijo que no está en la lista hace
que la app diga "no encontré el CLI `gh`" aunque esté instalado.

**Cómo detectarlo:** `which gh` funciona en la terminal pero la app dice que no
está. Agregar el prefijo a `candidatePaths`.

---

## 9. La firma ad-hoc alcanza para notificaciones

**Dónde:** `Scripts/build.sh` (`codesign --sign -`) y `Notifier`.

**Medición:** con el bundle firmado ad-hoc, `requestAuthorization` devolvió
concedido y `authorizationStatus` quedó en `authorized`. La notificación de
prueba se entregó. macOS 26.6.2.

**Qué se rompe:** si Apple endurece los requisitos, las notificaciones se caen en
silencio — la app no avisa que no puede avisar.

**Cómo detectarlo:**

```bash
"build/work-buddy.app/Contents/MacOS/WorkBuddy" --check-notifications
```

---

## 10. La CI roja **no** predice atraso (medido, y por eso no hay "rebasear los rojos")

**Dónde:** en ningún lado, a propósito. Está acá para que nadie lo implemente sin
volver a medir.

Una herramienta anterior trataba la CI roja de un dependabot como señal de que el PR está
obsoleto y un rebase lo arregla. Sobre los 50 PRs de dependabot de la cola real
(2026-09-03), cruzando `statusCheckRollup` con el `behindBy` de
`BehindCount`:

| | Atrasado | Al día |
| --- | --- | --- |
| **CI roja** | 24 (48%) | 22 (44%) |
| **CI ok** | 1 (2%) | 3 (6%) |

O sea que entre los 46 con CI roja, estar atrasado es prácticamente un volado
(52%). Y mirando **cuánto**, es peor todavía: de esos 24, **13 están atrasados por
1 solo commit**, que no explica una CI roja.

```
atraso de los rojos: 1×13, 5×6, 7, 8, 9, 12, 13
```

Quedan 11 de 46 (24%) atrasados por 5 commits o más, que es el único subconjunto
donde el rebase es una hipótesis razonable.

**Conclusión:** una acción de rebase no debería gatearse en "CI roja". El dato
objetivo es el atraso, que ya se muestra como badge `↓N` (ver #6); la decisión
queda del lado de quien mira. Antes agregué que la flag `mergeStateStatus: BEHIND`
de GitHub tampoco sirve para esto: veía 1 de 4 atrasados reales.

**Cómo volver a medirlo:**

```bash
swift build && .build/debug/WorkBuddy --dump-queue \
  | awk '/AUTOMATIZACIÓN/,/IGNORADOS/' | grep '@dependabot' \
  | awk '{r=/CI✗/; b=/↓[0-9]/; print (r?"roja":"ok"), (b?"atrasado":"al-día")}' \
  | sort | uniq -c
```

---

## Errores que ya cometimos

Quedan acá porque el patrón se repitió, y los tests que los fijan viven en
`Tests/WorkBuddyTests/`.

**Buscar sólo por `review-requested:@me`.** Aprobar un PR te saca de sus review
requests, así que el acto que lo vuelve mergeable es el mismo que lo saca de esa
búsqueda. Los PRs de automatización que aprobabas desaparecían de "Para mergear": el caso que lo destapó fue un PR de una cuenta de servicio, `CLEAN` y
aprobado por nosotros. Agregar `reviewed-by:@me` llevó la sección de 1 PR a 5.

Lección general: **`review-requested:@me` es "lo que falta que hagas", no "lo que
te concierne".** Para lo segundo hace falta también `reviewed-by:@me`.

**Usar el estado de CI como filtro.** `statusCheckRollup` incluye checks
**opcionales**. Filtrar por "CI en rojo → es del autor" escondía **40 de 63**
PRs, muchos de los cuales sí necesitaban review. Ahora CI es sólo un badge.

**Contar approvals a mano.** La regla `approvals > 0` marcaba un PR como cubierto
sin mirar branch protection ni CODEOWNERS. En la cola real había un PR con **3
approvals** que GitHub seguía marcando `REVIEW_REQUIRED`. Ahora usamos
`reviewDecision`.

La lección de las dos: **cuando GitHub ya calculó un veredicto, usar el suyo en
vez de reconstruirlo.** Vale para `reviewDecision`, `mergeStateStatus` y
`__typename` del autor.
