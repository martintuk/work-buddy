# Instrucciones de trabajo

- Después de cada cambio, reiniciá la app ejecutando `./Scripts/run.sh`.
- Después de cada cambio lógico, creá automáticamente un commit individual con un mensaje descriptivo, sin pedir confirmación.
- Priorizá interfaces compactas. No agregues labels informativos ni subtextos explicativos salvo que el usuario los solicite. Conservá tooltips y etiquetas de accesibilidad para que los controles con iconos se entiendan sin recargar la UI.
- Corré los tests con `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk ./Scripts/test.sh`. Con las Command Line Tools, el SDK 27 no trae el plugin `SwiftUIMacros` y `@State` no compila. `build.sh` ya cae al SDK 26 solo; `test.sh` no.
