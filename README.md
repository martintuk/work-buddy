# Work Buddy

App para macOS que reúne los PRs que requieren tu atención y permite revisarlos,
aprobarlos, mergearlos o abrirlos en tu editor o agente. También integra tickets
de Jira mediante el CLI de Atlassian como función experimental, desactivada por defecto.

## Requisitos

- macOS 14+
- Command Line Tools de Xcode (`xcode-select --install`). **No** hace falta Xcode completo.
- GitHub CLI (`gh`) instalado y autenticado con `gh auth login`.
- Opcional: Atlassian CLI (`acli`) autenticado con `acli jira auth login` para habilitar Jira.

## Configuración

El engranaje abre las preferencias generales de idioma y apariencia, con dos
subsecciones navegables:

- **GitHub:** organizaciones, equipos de Dependabot, cuentas de automatización,
  confirmación de acciones, notificaciones, editor y agente CLI.
- **Jira (experimental):** habilitar la integración, copiar el comando de inicio
  de sesión y editar las listas de tickets. Cada lista tiene un **Nombre en el
  panel** y un filtro **Qué tickets mostrar (JQL)**. Por defecto son **Asignados
  a mí** y **Creados recientemente** (hasta 10 tickets).

Jira empieza apagado. Sin Jira, el panel muestra GitHub directamente, sin pestañas
superiores ni nuevas consultas a Atlassian. Las credenciales permanecen en los
CLIs `gh` y `acli`; las preferencias de la app se guardan en `UserDefaults`.

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

## Documentación

- [Guía de uso](docs/uso.md): colas, acciones, filtros, agentes y actividad.
- [Desarrollo](docs/desarrollo.md): compilación, tests, arquitectura e idiomas.
- [Diagnóstico](docs/diagnostico.md): registros y medición del rendimiento.
- [Supuestos medidos](docs/supuestos.md): evidencia y límites de las decisiones.
- [Pendientes](docs/pendientes.md): propuestas y decisiones de alcance.
