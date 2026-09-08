/// LazyVStack reúne las filas de distintos ForEach en una misma lista de hijos.
/// El ID del recurso solo no distingue sus apariciones en categorías diferentes:
/// al moverlo puede reutilizar una fila sin recalcular su contenido ni sus menús.
/// La identidad de presentación incluye la sección, sin cambiar el ID del recurso.
struct QueueSectionItem<Item: Identifiable>: Identifiable {
    struct ID: Hashable {
        let section: String
        let item: Item.ID
    }

    let section: String
    let item: Item

    var id: ID { ID(section: section, item: item.id) }
}
