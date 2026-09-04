import Foundation
import Testing

@testable import WorkBuddy

@Suite("Tiempo transcurrido del footer")
struct LastUpdatedTextTests {
    @Test("Siempre muestra tiempo pasado con la unidad y el plural correctos", arguments: [
        (-5.0, "Actualizado hace 0 segundos"),
        (0.0, "Actualizado hace 0 segundos"),
        (1.0, "Actualizado hace 1 segundo"),
        (59.9, "Actualizado hace 59 segundos"),
        (60.0, "Actualizado hace 1 minuto"),
        (120.0, "Actualizado hace 2 minutos"),
        (3_600.0, "Actualizado hace 1 hora"),
        (7_200.0, "Actualizado hace 2 horas"),
        (86_400.0, "Actualizado hace 1 día"),
        (172_800.0, "Actualizado hace 2 días")
    ])
    func elapsedTime(seconds: Double, expected: String) {
        let lastUpdated = Date(timeIntervalSince1970: 1_000)
        #expect(LastUpdatedText.format(
            lastUpdated, relativeTo: lastUpdated.addingTimeInterval(seconds), language: .spanish
        ) == expected)
    }
}
