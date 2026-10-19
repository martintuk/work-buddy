# Pendientes y decisiones abiertas

Lo que quedó propuesto sin decidir, lo que se descartó a propósito, y lo que está
implementado pero sin verificar. Lo que ya está medido vive en
[supuestos.md](supuestos.md).

Existe porque el riesgo de este proyecto no es olvidarse *el código*, es
olvidarse **por qué algo no se hizo** y volver a proponerlo.

Última limpieza documental: **2026-10-19**. Las comprobaciones manuales pendientes
siguen sin darse por verificadas.

---

## Propuesto, sin decidir

### Chips de bloqueo en vez de badges sueltos

Hoy `CI✗`, `draft`, `N✓` y `↓N` son badges independientes que hay que leer y
combinar mentalmente. No son excluyentes entre sí, así que la pregunta real —*qué
falta para que esto se pueda mergear*— no la responde ninguno solo.

### Mantener la fila visible después de aprobar

Aprobar te saca de los review requests: la fila desaparece en el refresh
siguiente y el único rastro es el banner, que se
puede cerrar. Un estado "recién hecho" de ~15 min haría que la confirmación no se
esfume.

Para merge, decidimos quitar el PR del snapshot local apenas GitHub confirma
el éxito. No se guarda una exclusión: el próximo update puede volver a traerlo.

---

## Descartado a propósito

No volver a proponer esto sin medir de nuevo primero.

| Idea | Por qué no | Dónde está medido |
| --- | --- | --- |
| Lista de repos a mano (`repos.txt`) | Los 8 repos que agregaba: 7 sin dependabot abierto, 1 asignado a otro equipo. Y olvidaba 7 que la query sí encuentra | supuesto #2 |
| Selector de método de merge | GitHub ya lo decide (`viewerDefaultMergeMethod`); en la web tampoco se elige | — |
| Filtrar por estado de CI | Escondía 40 de 63 PRs, muchos que sí necesitaban review. Quedó como badge | "Errores que ya cometimos" |
| Contar approvals a mano | Un PR con 3 approvals seguía en `REVIEW_REQUIRED` por CODEOWNERS | idem |
| Buscar sólo por `review-requested:@me` | Aprobar te saca de esa búsqueda, así que los mergeables desaparecían | idem |
| Set liviano de campos para dependabot | El set completo entra igual en `first: 50`; el liviano perdía `reviewedByMe` y `approvals` a cambio de nada | supuesto #7 |
| `.confirmationDialog` para el merge | Un diálogo del sistema dentro de un `NSPopover` pelea con el cierre por pérdida de foco. Quedó una barra inline | — |
| Mergear PRs de compañeros | Decisión de alcance: no es tuyo mergearlos | — |

El patrón detrás de la mitad de estas: **cuando GitHub ya calculó un veredicto,
usar el suyo en vez de reconstruirlo.** Vale para `reviewDecision`,
`mergeStateStatus`, `viewerDefaultMergeMethod` y `__typename` del autor.

---

## Implementado, sin verificar

Cosas donde la lógica está y está razonada, pero nadie confirmó el
comportamiento observable.

- **El menú `⋯` no cierra el panel.** El discriminante (`NSApp.isActive`) está
  medido, pero el gesto no se probó. Ver supuesto #5, que trae el comando con log.
- **Aporte del merge al badge.** El badge suma las colas que requieren acción deduplicando por id,
  y hay test de que ignorados no cuentan. Pero cuando se revisó a mano,
  `readyToMerge` era 0, así que la suma con ambos términos distintos de cero no se
  vio nunca.
- **La sección de automatización con 50 filas.** Arranca colapsada. Nadie la
  expandió para ver si scrollea bien.
